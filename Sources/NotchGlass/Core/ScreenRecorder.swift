import AppKit
import Combine

/// Screen capture driven by the system `/usr/sbin/screencapture` tool — no extra
/// frameworks, no entitlements beyond the Screen Recording permission macOS asks
/// for the first time a capture runs.
///
/// Video recording (`-v`) runs `screencapture` as a long-lived process; stopping
/// it sends SIGINT, which is how the tool is designed to finalize the `.mov`.
/// Screenshots (`-i` region, `-iw` window, full) are one-shot and return their
/// file the moment the tool exits. Every finished capture is handed to `onFinish`
/// so callers can park it on the Drop shelf.
@MainActor
final class ScreenRecorder: ObservableObject {
    static let shared = ScreenRecorder()

    /// True while a video recording is in progress.
    @Published private(set) var isRecording = false
    /// When the current recording started, for the live elapsed readout / REC peek.
    @Published private(set) var startDate: Date?
    /// The most recent capture (video or still) that landed, for the tab's preview.
    @Published private(set) var lastCapture: URL?

    /// Called on the main actor with every finished capture's file URL. Wired by
    /// `AppDelegate` to drop the file onto the shelf.
    var onFinish: ((URL) -> Void)?

    private var recordingProcess: Process?

    private init() {}

    /// `~/Library/Application Support/NotchGlass/Recordings`. A stable home (not
    /// the temp dir) so captures survive relaunches and stay draggable from Drop.
    static let directory: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("NotchGlass/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: - Video

    /// Start a full-screen video recording. No-op if one is already running.
    func startRecording() {
        guard !isRecording else { return }
        let url = Self.directory.appendingPathComponent("\(Self.stamp()).mov")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -v: video. -C: capture the cursor too. The trailing path is the target.
        proc.arguments = ["-v", "-C", url.path]
        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.finishRecording(url) }
        }
        do {
            try proc.run()
        } catch {
            NSLog("NotchGlass: screencapture failed to launch: \(error.localizedDescription)")
            return
        }
        recordingProcess = proc
        isRecording = true
        startDate = Date()
    }

    /// Stop the in-progress recording. SIGINT is what `screencapture -v` expects to
    /// flush and close the movie file cleanly.
    func stopRecording() {
        guard isRecording, let proc = recordingProcess else { return }
        proc.interrupt()
    }

    /// Full-screen video with the in-notch Stop screen — the long-lived `-v`
    /// process this tab drives directly (see `startRecording`/`stopRecording`).
    func recordFullScreen() { startRecording() }

    /// Interactive region video: drag an area, then macOS records it. Unlike the
    /// full-screen path this uses the system capture toolbar, which owns selection
    /// *and* the stop control (menu-bar button), so `isRecording` stays false and
    /// the tab keeps showing its normal face. The finished movie lands on Drop.
    func recordRegion() { runInteractiveVideo(windowMode: false) }

    /// Interactive window video: pick a window, then macOS records it. Same system
    /// toolbar / stop model as `recordRegion`.
    func recordWindow() { runInteractiveVideo(windowMode: true) }

    /// Fires the system interactive video capture. `-J video` starts the toolbar in
    /// video (selection) mode; `-W` starts it in window-selection mode instead.
    private func runInteractiveVideo(windowMode: Bool) {
        let url = Self.directory.appendingPathComponent("\(Self.stamp()).mov")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -v video, -i interactive, -J video starts in video mode; -W flips the
        // starting selection to window mode. -C captures the cursor. The system
        // toolbar's own Stop control finalizes the file, then the process exits.
        var args = ["-v", "-i", "-J", "video", "-C"]
        if windowMode { args.append("-W") }
        args.append(url.path)
        proc.arguments = args
        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard FileManager.default.fileExists(atPath: url.path) else { return }
                self?.lastCapture = url
                self?.onFinish?(url)
            }
        }
        do {
            try proc.run()
        } catch {
            NSLog("NotchGlass: screencapture failed to launch: \(error.localizedDescription)")
        }
    }

    private func finishRecording(_ url: URL) {
        recordingProcess = nil
        isRecording = false
        startDate = nil
        // The tool writes the file just before it exits; give the handler the URL
        // only if the movie actually materialized (a cancelled/failed run leaves none).
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        lastCapture = url
        onFinish?(url)
    }

    // MARK: - Stills

    /// Interactive region screenshot (drag a rectangle). Falls through silently if
    /// the user hits Esc, since `screencapture -i` then writes no file.
    func captureRegion() { runStill(["-i"]) }

    /// Interactive window screenshot (click a window; includes its shadow).
    func captureWindow() { runStill(["-iw"]) }

    /// Whole-screen screenshot, no picker.
    func captureFullScreen() { runStill([]) }

    private func runStill(_ flags: [String]) {
        let url = Self.directory.appendingPathComponent("\(Self.stamp()).png")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = flags + [url.path]
        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard FileManager.default.fileExists(atPath: url.path) else { return }
                self?.lastCapture = url
                self?.onFinish?(url)
            }
        }
        do {
            try proc.run()
        } catch {
            NSLog("NotchGlass: screencapture failed to launch: \(error.localizedDescription)")
        }
    }

    // MARK: - Naming

    /// A filesystem-safe timestamp like `Recording 2026-08-26 at 14.03.11`.
    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Notch \(f.string(from: Date()))"
    }
}
