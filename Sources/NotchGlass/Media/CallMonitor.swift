import AVFoundation
import CoreAudio
import CoreMediaIO
import AppKit

/// Watches the system for an active call and gives the Call tab its live state: is the
/// **mic** hot, is the **camera** hot, which conferencing app is running, how long the
/// call has been going, and your input **mute** state — plus an on-demand level meter.
///
/// This is the universal layer: it reads macOS's own "device is running somewhere"
/// signals (CoreAudio for the mic, CoreMediaIO for the camera), so it works with every
/// call app without any per-app hooks. Per-app extras (Discord events, web-call state)
/// layer on top later.
@MainActor
final class CallMonitor: ObservableObject {
    static let shared = CallMonitor()

    /// The mic is being captured by some app (the same signal behind the orange dot).
    @Published private(set) var micLive = false
    /// The camera is being captured by some app (the green dot).
    @Published private(set) var cameraLive = false
    /// The default input device is muted (hardware/driver mute).
    @Published private(set) var inputMuted = false
    /// The conferencing app that looks responsible for the call, if we can name one.
    @Published private(set) var callApp: String?
    /// When the current call (mic-live stretch) began — drives the duration timer.
    @Published private(set) var callStartedAt: Date?
    /// Live input level 0…1 while metering is running (Call tab visible). 0 otherwise.
    @Published private(set) var level: Float = 0

    /// True while anything call-like is happening — the tab and (later) the pill glance.
    var onCall: Bool { micLive || cameraLive }

    /// Bundle ids of the apps we recognise as conferencing clients, newest-first-ish.
    private static let callApps: [(id: String, name: String)] = [
        ("us.zoom.xos", "Zoom"),
        ("com.microsoft.teams2", "Teams"),
        ("com.microsoft.teams", "Teams"),
        ("com.hnc.Discord", "Discord"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.google.Chrome", "Google Meet / web call"),
        ("com.apple.Safari", "web call"),
        ("com.cisco.webexmeetingsapp", "Webex"),
        ("com.apple.FaceTime", "FaceTime"),
    ]

    private var poll: Timer?
    private var engine: AVAudioEngine?

    private init() {}

    // MARK: - Lifecycle

    /// Begin polling the system devices (cheap property reads, ~1.5 s cadence).
    func start() {
        guard poll == nil else { return }
        refresh()
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        poll = t
    }

    func stop() {
        poll?.invalidate(); poll = nil
        stopMetering()
    }

    private func refresh() {
        let mic = Self.deviceInUse(scope: .audio)
        let cam = Self.deviceInUse(scope: .video)
        micLive = mic
        cameraLive = cam
        inputMuted = Self.inputMuteState() ?? inputMuted

        if (mic || cam) {
            if callStartedAt == nil { callStartedAt = Date() }
            callApp = Self.detectCallApp()
        } else {
            callStartedAt = nil
            callApp = nil
        }
    }

    // MARK: - Mute

    /// Toggle the default input device's mute (a true hardware/driver mute, so it works
    /// no matter which app owns the call). Returns the new state, or nil if the device
    /// doesn't support muting.
    @discardableResult
    func toggleMute() -> Bool? {
        let target = !(Self.inputMuteState() ?? false)
        guard Self.setInputMute(target) else { return nil }
        inputMuted = target
        return target
    }

    // MARK: - Metering

    /// Start the live level meter (call while the tab is visible). Taps the input node
    /// and publishes an RMS level; harmless to call repeatedly.
    func startMetering() {
        guard engine == nil else { return }
        let e = AVAudioEngine()
        let input = e.inputNode
        let format = input.inputFormat(forBus: 0)
        // A zero-channel format means no usable input (no permission yet / no device).
        guard format.channelCount > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let ch = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = n > 0 ? sqrt(sum / Float(n)) : 0
            // Map RMS to a lively 0…1 with a gentle curve so quiet speech still shows.
            let scaled = min(1, max(0, rms * 12))
            Task { @MainActor in self?.level = scaled }
        }
        do { try e.start(); engine = e } catch { engine = nil }
    }

    func stopMetering() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        level = 0
    }

    // MARK: - Which app

    private static func detectCallApp() -> String? {
        let running = NSWorkspace.shared.runningApplications
        let ids = Set(running.compactMap { $0.bundleIdentifier })
        // Prefer the frontmost match, else any running match.
        if let front = running.first(where: { $0.isActive })?.bundleIdentifier,
           let hit = callApps.first(where: { $0.id == front }) {
            return hit.name
        }
        for app in callApps where ids.contains(app.id) { return app.name }
        return "Microphone in use"
    }

    // MARK: - CoreAudio / CoreMediaIO device state

    private enum Scope { case audio, video }

    /// Whether the *default* input/camera device is currently running (being captured).
    private static func deviceInUse(scope: Scope) -> Bool {
        switch scope {
        case .audio:
            guard let dev = defaultInputDevice() else { return false }
            return audioBool(dev, kAudioDevicePropertyDeviceIsRunningSomewhere,
                             scope: kAudioObjectPropertyScopeGlobal)
        case .video:
            return anyCameraRunning()
        }
    }

    // --- Audio ---

    private static func defaultInputDevice() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &addr, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    private static func audioBool(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector,
                                  scope: AudioObjectPropertyScope) -> Bool {
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &addr) else { return false }
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    private static func inputMuteState() -> Bool? {
        guard let dev = defaultInputDevice() else { return nil }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                              mScope: kAudioObjectPropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(dev, &addr) else { return nil }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &value) == noErr ? value != 0 : nil
    }

    private static func setInputMute(_ muted: Bool) -> Bool {
        guard let dev = defaultInputDevice() else { return false }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                              mScope: kAudioObjectPropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(dev, &addr),
              AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr, settable.boolValue else { return false }
        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(dev, &addr, 0, nil, size, &value) == noErr
    }

    // --- Camera (CoreMediaIO) ---

    private static func anyCameraRunning() -> Bool {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject),
                                            &addr, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return false
        }
        let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        var devices = [CMIOObjectID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject),
                                        &addr, 0, nil, dataSize, &used, &devices) == noErr else {
            return false
        }
        var runAddr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
        for dev in devices where dev != 0 {
            var running: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if CMIOObjectGetPropertyData(dev, &runAddr, 0, nil, size, &size, &running) == noErr,
               running != 0 {
                return true
            }
        }
        return false
    }
}
