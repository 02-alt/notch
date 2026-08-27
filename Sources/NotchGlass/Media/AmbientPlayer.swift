import AVFoundation
import QuartzCore

/// Background ambience — loops a bundled field recording (rain, storm, …) through a
/// dedicated ``AVAudioEngine``, entirely separate from any other audio, so the chosen
/// scene keeps playing whether the panel is open or collapsed.
///
/// Each scene's recording is decoded once on first selection, capped to a workable
/// length, and its end is equal-power crossfaded back over its start so the loop point
/// is inaudible even though the source isn't a designed loop. Scene changes and volume
/// drags are smoothed by fading the mixer's output level.
///
/// Ported from the Encore emulator's `AmbientPlayer`, which shares these soundscapes.
@MainActor
final class AmbientPlayer {
    static let shared = AmbientPlayer()

    /// Longest slice of a recording we hold in memory / loop over. Long enough to not
    /// feel repetitive, short enough to keep decode time and RAM modest.
    private static let maxLoopSeconds = 90.0
    /// Crossfade applied at the loop seam.
    private static let crossfadeSeconds = 1.0

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat

    private var buffers: [AmbientScene: AVAudioPCMBuffer] = [:]
    private var current: AmbientScene = .off
    private var started = false

    // Mixer-volume fade state, stepped by `fadeTimer` on the main run loop.
    private var fadeTimer: Timer?
    private var fadeStart: Float = 0
    private var fadeTarget: Float = 0
    private var fadeT0: CFTimeInterval = 0
    private var fadeDuration: Double = 0
    private var fadeCompletion: (() -> Void)?

    private init() {
        format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0   // start silent; scenes fade in
    }

    /// Bring the player in line with the requested scene / volume. Called whenever the
    /// Ambient tab's selection or volume changes.
    func apply(scene: AmbientScene, volume: Double) {
        let target = Float(max(0, min(1, volume)))
        if scene != current {
            current = scene
            switchTo(scene, volume: target)
        } else if scene != .off {
            fade(to: target, over: 0.08)   // live volume drag, smoothed so it isn't zippery
        }
    }

    // MARK: - Transport

    /// Fade out whatever is playing, swap in the new scene's loop, and fade back up to `volume`.
    private func switchTo(_ scene: AmbientScene, volume: Float) {
        fade(to: 0, over: player.isPlaying ? 0.4 : 0) { [weak self] in
            guard let self else { return }
            self.player.stop()
            guard scene != .off, let buffer = self.buffer(for: scene) else { return }
            do {
                if !self.started { try self.engine.start(); self.started = true }
                self.player.scheduleBuffer(buffer, at: nil, options: [.loops, .interrupts])
                self.player.play()
                self.fade(to: volume, over: 0.6)
            } catch {
                NSLog("AmbientPlayer: engine start failed: \(error)")
            }
        }
    }

    /// Animate the mixer's output level toward `target` on the main run loop, then run `then`.
    private func fade(to target: Float, over seconds: Double, then: (() -> Void)? = nil) {
        fadeTimer?.invalidate(); fadeTimer = nil
        fadeCompletion = nil
        guard seconds > 0 else { engine.mainMixerNode.outputVolume = target; then?(); return }
        fadeStart = engine.mainMixerNode.outputVolume
        fadeTarget = target
        fadeT0 = CACurrentMediaTime()
        fadeDuration = seconds
        fadeCompletion = then
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepFade() }
        }
    }

    private func stepFade() {
        let p = Float(min(1, (CACurrentMediaTime() - fadeT0) / fadeDuration))
        engine.mainMixerNode.outputVolume = fadeStart + (fadeTarget - fadeStart) * p
        guard p >= 1 else { return }
        fadeTimer?.invalidate(); fadeTimer = nil
        let done = fadeCompletion; fadeCompletion = nil
        done?()
    }

    // MARK: - Buffer cache

    private func buffer(for scene: AmbientScene) -> AVAudioPCMBuffer? {
        if let cached = buffers[scene] { return cached }
        guard let name = scene.resource,
              let built = Self.loadSeamlessLoop(resource: name, target: format) else { return nil }
        buffers[scene] = built
        return built
    }

    // MARK: - Loading

    /// Decode `resource` (capped to `maxLoopSeconds`), match it to `target`, and crossfade
    /// it into a seamless loop.
    private static func loadSeamlessLoop(resource: String, target: AVAudioFormat) -> AVAudioPCMBuffer? {
        // Accept any bundled audio container (some loops are pre-trimmed AAC `.m4a`).
        let exts = ["m4a", "mp3", "caf"]
        guard let url = exts.lazy.compactMap({ ext in
            Bundle.module.url(forResource: resource, withExtension: ext, subdirectory: "ambience")
        }).first else {
            NSLog("AmbientPlayer: missing resource \(resource).(m4a|mp3|caf)"); return nil
        }
        guard let file = try? AVAudioFile(forReading: url) else {
            NSLog("AmbientPlayer: could not open \(url.lastPathComponent)"); return nil
        }
        let srcFormat = file.processingFormat
        let cap = AVAudioFrameCount(min(Double(file.length), maxLoopSeconds * srcFormat.sampleRate))
        guard cap > 0, let raw = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: cap) else { return nil }
        do { try file.read(into: raw, frameCount: cap) }
        catch { NSLog("AmbientPlayer: read failed for \(resource): \(error)"); return nil }

        let matched: AVAudioPCMBuffer
        if srcFormat.sampleRate == target.sampleRate && srcFormat.channelCount == target.channelCount {
            matched = raw
        } else if let converted = convert(raw, to: target) {
            matched = converted
        } else {
            NSLog("AmbientPlayer: could not match format for \(resource)"); return nil
        }
        return makeSeamless(matched)
    }

    /// One-shot feed state for a synchronous converter pass. `@unchecked Sendable` is sound
    /// here because `AVAudioConverter`'s input block runs **synchronously on the calling
    /// thread** during `convert(to:error:)` — never concurrently — so there's no data race.
    private final class ConvertFeed: @unchecked Sendable {
        var fed = false
        let buffer: AVAudioPCMBuffer
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    }

    /// Resample / rechannel `input` into `target` in one pass.
    private static func convert(_ input: AVAudioPCMBuffer, to target: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(from: input.format, to: target) else { return nil }
        let ratio = target.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        let feed = ConvertFeed(input)
        var err: NSError?
        converter.convert(to: output, error: &err) { _, status in
            if feed.fed { status.pointee = .noDataNow; return nil }
            feed.fed = true; status.pointee = .haveData; return feed.buffer
        }
        if let err { NSLog("AmbientPlayer: convert error \(err)"); return nil }
        return output
    }

    /// Trim the last `crossfadeSeconds` and equal-power blend that tail back over the head,
    /// so the looped buffer flows end→start without a seam.
    private static func makeSeamless(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let sr = input.format.sampleRate
        let n = Int(input.frameLength)
        let xf = min(Int(crossfadeSeconds * sr), n / 3)
        guard xf > 0, n > xf, let inData = input.floatChannelData else { return input }
        let channels = Int(input.format.channelCount)
        let loopLen = n - xf
        guard let out = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: AVAudioFrameCount(loopLen)),
              let outData = out.floatChannelData else { return input }
        out.frameLength = AVAudioFrameCount(loopLen)
        for c in 0..<channels {
            let src = inData[c], dst = outData[c]
            for i in 0..<loopLen { dst[i] = src[i] }
            // Blend the trimmed tail (src[loopLen ..< n]) into the head (dst[0 ..< xf]).
            for j in 0..<xf {
                let x = Float(j) / Float(xf)
                dst[j] = src[j] * sinf(0.5 * .pi * x) + src[loopLen + j] * cosf(0.5 * .pi * x)
            }
        }
        return out
    }
}
