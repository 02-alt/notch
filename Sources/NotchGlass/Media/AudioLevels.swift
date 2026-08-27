import Foundation
import CoreAudio
import AudioToolbox
import Accelerate
import Combine
import os

/// A tiny lock-guarded ring of mono samples: written by the realtime Core Audio IO
/// block, read by the analysis timer. Kept off the main actor (its own class) so the
/// realtime callback never touches actor-isolated state.
final class SampleRing: @unchecked Sendable {
    let size: Int
    private var buffer: [Float]
    private var writeIndex = 0
    private var lock = os_unfair_lock_s()

    init(size: Int) {
        self.size = size
        self.buffer = Array(repeating: 0, count: size)
    }

    func write(_ samples: UnsafePointer<Float>, count: Int) {
        os_unfair_lock_lock(&lock)
        for i in 0..<count {
            buffer[writeIndex] = samples[i]
            writeIndex = (writeIndex + 1) % size
        }
        os_unfair_lock_unlock(&lock)
    }

    /// Copies the most recent `size` samples in chronological order.
    func snapshot(into out: inout [Float]) {
        os_unfair_lock_lock(&lock)
        let start = writeIndex
        for i in 0..<size {
            out[i] = buffer[(start + i) % size]
        }
        os_unfair_lock_unlock(&lock)
    }
}

/// Captures system audio with a Core Audio process tap (macOS 14.4+) and turns it
/// into a handful of frequency-band levels that drive the collapsed-notch EQ.
///
/// The tap grabs a global stereo mixdown of everything the machine plays — and,
/// unlike ScreenCaptureKit, needs **no Screen Recording permission**. A realtime IO
/// block downmixes to mono and copies into a `SampleRing`; a 60 Hz main-thread timer
/// runs an FFT over the latest window, buckets it into `bandCount` log-spaced bands,
/// smooths with a fast-attack / slow-decay envelope, and publishes `bands`.
///
/// If the tap can't be created (older OS, missing entitlement, sandbox), `active`
/// stays false and the EQ falls back to its simulated motion.
@MainActor
final class AudioLevels: ObservableObject {
    /// Per-band levels, 0…1, index 0 = lowest frequency.
    @Published private(set) var bands: [CGFloat]
    /// True once the tap + aggregate device are live and delivering audio.
    @Published private(set) var active = false
    /// True while the live tap is actually delivering a non-silent signal. The tap
    /// can be `active` yet hear nothing — audio routed to a device the tap doesn't
    /// cover (output changed after setup, AirPlay/BT), or a denied capture on newer
    /// macOS — which would otherwise show as dead, floored bars. When this is false
    /// the EQ falls back to its simulated motion so it never looks frozen mid-track.
    @Published private(set) var receivingAudio = false

    /// Consecutive 60 Hz frames with no audible energy on the tap. Drives the
    /// `receivingAudio` fallback after a short grace window (so a quiet passage or a
    /// brief gap doesn't flip to the simulation).
    private var silentFrames = 0

    let bandCount: Int

    // FFT
    private let fftSize = 1024
    private let half: Int
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup?
    private var window: [Float]
    private var scratch: [Float]

    // Realtime sample transport + smoothing state.
    private let ring: SampleRing
    private var envelope: [Float]
    private var bandBins: [(lo: Int, hi: Int)] = []

    // Core Audio objects
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var sampleRate: Double = 48_000

    private var timer: DispatchSourceTimer?
    /// Whether the analysis timer is currently suspended (EQ off-screen). Tracked so
    /// suspend/resume stay balanced and `stop()` can resume before cancelling — a
    /// dispatch source released while suspended crashes.
    private var timerSuspended = false

    init(bandCount: Int = 7) {
        self.bandCount = bandCount
        self.bands = Array(repeating: 0, count: bandCount)
        self.envelope = Array(repeating: 0, count: bandCount)
        self.half = fftSize / 2
        self.log2n = vDSP_Length(log2(Float(fftSize)))
        self.fftSetup = vDSP_create_fftsetup(vDSP_Length(log2(Float(fftSize))), FFTRadix(kFFTRadix2))
        self.window = [Float](repeating: 0, count: fftSize)
        self.scratch = [Float](repeating: 0, count: fftSize)
        self.ring = SampleRing(size: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }

    // MARK: - Lifecycle

    func start() {
        guard !active, aggregateID == kAudioObjectUnknown else { return }
        guard setUpTap() else {
            teardownCoreAudio()
            return
        }
        bandBins = bandRanges()
        startTimer()
        active = true
    }

    func stop() {
        if let timer {
            // A suspended dispatch source must be resumed before it can be cancelled
            // and released, or libdispatch traps.
            if timerSuspended { timer.resume(); timerSuspended = false }
            timer.cancel()
        }
        timer = nil
        teardownCoreAudio()
        active = false
        receivingAudio = false
        silentFrames = 0
        bands = Array(repeating: 0, count: bandCount)
        envelope = Array(repeating: 0, count: bandCount)
    }

    /// Pause or resume the 60 Hz FFT + `bands` publishing without touching the Core
    /// Audio device. Used to stop the analysis while the EQ is off-screen (the panel
    /// is expanded) — the realtime tap stays alive so reopening the pill is instant and
    /// we don't churn `coreaudiod` rebuilding the aggregate device on every notch peek.
    func setAnalysisActive(_ on: Bool) {
        guard active, let timer else { return }
        if on, timerSuspended {
            timer.resume()
            timerSuspended = false
        } else if !on, !timerSuspended {
            timer.suspend()
            timerSuspended = true
        }
    }

    private func teardownCoreAudio() {
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    // MARK: - Core Audio setup

    private func setUpTap() -> Bool {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.name = "NotchGlass EQ Tap"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted

        var newTap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(desc, &newTap) == noErr, newTap != kAudioObjectUnknown else {
            return false
        }
        tapID = newTap

        if let asbd = tapFormat(newTap), asbd.mSampleRate > 0 {
            sampleRate = asbd.mSampleRate
        }

        guard let outputUID = defaultOutputUID() else { return false }

        let aggUID = "com.notchglass.eq.\(UUID().uuidString)"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "NotchGlass EQ",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: desc.uuid.uuidString
                ]
            ]
        ]

        var aggID = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggID) == noErr,
              aggID != kAudioObjectUnknown else {
            return false
        }
        aggregateID = aggID

        // The IO block runs on a realtime thread; capture only the ring (Sendable),
        // never self, so it touches no actor-isolated state.
        let ring = self.ring
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &procID, aggID, DispatchQueue.global(qos: .userInteractive)
        ) { _, inInputData, _, _, _ in
            AudioLevels.downmix(inInputData, into: ring)
        }
        guard status == noErr, let procID else { return false }
        ioProcID = procID

        return AudioDeviceStart(aggID, procID) == noErr
    }

    /// Downmix an incoming buffer list to mono and push it into the ring. Handles
    /// both interleaved (one buffer, N channels) and non-interleaved (N buffers)
    /// layouts.
    private static func downmix(_ input: UnsafePointer<AudioBufferList>, into ring: SampleRing) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard abl.count > 0 else { return }

        if abl.count == 1 {
            let b = abl[0]
            guard let data = b.mData?.assumingMemoryBound(to: Float.self) else { return }
            let ch = max(Int(b.mNumberChannels), 1)
            let frames = Int(b.mDataByteSize) / MemoryLayout<Float>.size / ch
            guard frames > 0 else { return }
            if ch == 1 {
                ring.write(data, count: frames)
            } else {
                var mono = [Float](repeating: 0, count: frames)
                for f in 0..<frames {
                    var s: Float = 0
                    for c in 0..<ch { s += data[f * ch + c] }
                    mono[f] = s / Float(ch)
                }
                mono.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: frames) }
            }
        } else {
            let frames = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size
            guard frames > 0 else { return }
            var mono = [Float](repeating: 0, count: frames)
            var channels: Float = 0
            for i in 0..<abl.count {
                guard let d = abl[i].mData?.assumingMemoryBound(to: Float.self) else { continue }
                let n = min(frames, Int(abl[i].mDataByteSize) / MemoryLayout<Float>.size)
                for f in 0..<n { mono[f] += d[f] }
                channels += 1
            }
            if channels > 0 { for f in 0..<frames { mono[f] /= channels } }
            mono.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: frames) }
        }
    }

    // MARK: - Analysis (60 Hz, main)

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 1.0 / 60.0)
        t.setEventHandler { [weak self] in self?.analyze() }
        t.resume()
        timer = t
        timerSuspended = false
    }

    private func analyze() {
        guard let fftSetup else { return }
        ring.snapshot(into: &scratch)

        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(scratch, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)

        windowed.withUnsafeBufferPointer { p in
            p.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cplx in
                real.withUnsafeMutableBufferPointer { rp in
                    imag.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        vDSP_ctoz(cplx, 2, &split, 1, vDSP_Length(half))
                        vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
                    }
                }
            }
        }

        var scale = 1.0 / Float(fftSize)
        vDSP_vsmul(mags, 1, &scale, &mags, 1, vDSP_Length(half))

        // Bucket into bands (dB-mapped), then apply the attack/decay envelope.
        let minDb: Float = -55, maxDb: Float = -5
        for i in 0..<bandCount {
            let (lo, hi) = bandBins[i]
            var sum: Float = 0
            var n = 0
            var k = lo
            while k < hi { sum += mags[k]; n += 1; k += 1 }
            let avg = n > 0 ? sum / Float(n) : 0
            let db = 20 * log10(avg + 1e-7)
            let level = min(1, max(0, (db - minDb) / (maxDb - minDb)))
            // Snap up instantly, ease down — the classic spectrum-meter feel.
            envelope[i] = level > envelope[i] ? level : envelope[i] * 0.80 + level * 0.20
        }
        bands = envelope.map { CGFloat($0) }

        // Is the tap actually hearing anything? Flip `receivingAudio` on immediately
        // when signal appears, off only after ~1s of continuous silence so quiet
        // passages don't bounce us to the simulation.
        let peak = envelope.max() ?? 0
        if peak > 0.04 {
            silentFrames = 0
            if !receivingAudio { receivingAudio = true }
        } else {
            silentFrames += 1
            if silentFrames > 60, receivingAudio { receivingAudio = false }
        }
    }

    private func bandRanges() -> [(Int, Int)] {
        let minF = 60.0
        let maxF = min(16_000.0, sampleRate / 2)
        var ranges: [(Int, Int)] = []
        for b in 0..<bandCount {
            let f0 = minF * pow(maxF / minF, Double(b) / Double(bandCount))
            let f1 = minF * pow(maxF / minF, Double(b + 1) / Double(bandCount))
            let lo = max(1, Int(f0 * Double(fftSize) / sampleRate))
            let hi = min(half, max(lo + 1, Int(f1 * Double(fftSize) / sampleRate)))
            ranges.append((lo, hi))
        }
        return ranges
    }

    // MARK: - Property helpers

    private func tapFormat(_ tap: AudioObjectID) -> AudioStreamBasicDescription? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let st = AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &asbd)
        return st == noErr ? asbd : nil
    }

    private func defaultOutputUID() -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr,
              dev != kAudioObjectUnknown else { return nil }

        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString?
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(dev, &uidAddr, 0, nil, &uidSize, &uid) == noErr,
              let uid else { return nil }
        return uid as String
    }
}
