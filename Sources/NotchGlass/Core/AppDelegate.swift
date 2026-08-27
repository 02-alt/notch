import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NotchPanel?
    private let settings = SettingsStore.shared
    private let viewModel = NotchViewModel()
    private let nowPlaying = NowPlayingManager()
    private let glassMenu = GlassMenuController.shared
    private let gallery = AddTabGalleryController.shared
    private let fuelManager = FuelManager()
    private let audioLevels = AudioLevels(bandCount: 7)
    private let fuelEvents = FuelEventMonitor()
    private let batteryMonitor = BatteryMonitor()
    private var airDropWatcher: AirDropWatcher?
    private var cancellables = Set<AnyCancellable>()

    /// Tear the Core Audio process tap down cleanly on quit. Without this a hard exit
    /// can leave the private tap/aggregate stranded in `coreaudiod`, so a relaunched
    /// tap may come up hearing silence (dead EQ bars).
    func applicationWillTerminate(_ notification: Notification) {
        audioLevels.stop()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installCrashLogger()

        // Agent app: no Dock icon, no menu bar app name.
        NSApp.setActivationPolicy(.accessory)

        // Open on the saved default tab — unless it was removed from the bar, in
        // which case fall back to the first shown tab.
        viewModel.selectedTab = settings.enabledTabs.contains(settings.defaultTab)
            ? settings.defaultTab
            : (settings.enabledTabs.first ?? .media)
        settings.onPanelWidthChange = { [weak self] _ in
            self?.positionPanel()
        }

        buildPanel()

        // Light the collapsed-notch transfer spinner when an AirDrop file lands.
        let watcher = AirDropWatcher { [weak self] in
            self?.viewModel.flashTransfer()
        }
        watcher.start()
        airDropWatcher = watcher

        // Screen captures land on the Drop shelf when they finish, so a recording
        // or screenshot is immediately draggable out of the notch.
        ScreenRecorder.shared.onFinish = { [weak self] url in
            self?.viewModel.addDropped(urls: [url])
        }

        // Run the system-audio tap only while the reactive EQ can actually be seen:
        // something is playing AND the collapsed media peek is enabled. Outside that we
        // don't tap system audio (or light a capture indicator) or run the 60 Hz FFT for
        // a visualizer nobody is looking at. While the panel is expanded the EQ is
        // off-screen, so we pause the FFT but keep the tap alive — reopening the pill is
        // then instant and we don't rebuild the Core Audio device on every notch peek.
        Publishers.CombineLatest3(
            nowPlaying.$isPlaying,
            settings.$collapsedShowsMedia,
            viewModel.$isOpen
        )
        .map { playing, showMedia, isOpen in (tap: playing && showMedia, visible: playing && showMedia && !isOpen) }
        .removeDuplicates { $0 == $1 }
        .sink { [weak self] state in
            guard let self else { return }
            if state.tap { self.audioLevels.start() } else { self.audioLevels.stop() }
            self.audioLevels.setAnalysisActive(state.visible)
        }
        .store(in: &cancellables)

        // Fuel usage in the collapsed notch: the same slow background poll feeds both
        // the transient "Fuel refilled / running low" events (opt-in) and the resting
        // fuel gauge (`collapsedResting == .fuel`). Run it whenever either wants it,
        // so it never touches the network/keychain unless the user asked for it.
        fuelEvents.onEvent = { [weak self] event in self?.viewModel.flash(event) }
        settings.$collapsedShowsFuelEvents
            .combineLatest(settings.$collapsedResting)
            .map { showsEvents, resting in showsEvents || resting == .fuel }
            .removeDuplicates()
            .sink { [weak self] wantsFuel in
                if wantsFuel { self?.fuelEvents.start() } else { self?.fuelEvents.stop() }
            }
            .store(in: &cancellables)

        // The resting battery gauge polls only while it's the chosen resting stat.
        settings.$collapsedResting
            .map { $0 == .battery }
            .removeDuplicates()
            .sink { [weak self] wantsBattery in
                if wantsBattery { self?.batteryMonitor.start() } else { self?.batteryMonitor.stop() }
            }
            .store(in: &cancellables)

        // The window never resizes — the SwiftUI content morphs inside a fixed
        // frame. We only reposition when the display configuration changes.
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                self?.positionPanel()
            }
            .store(in: &cancellables)

        // When the panel collapses, hand keyboard focus back to whatever window was
        // active before. Editing a note makes the panel the key window (so it can
        // take keystrokes); without this the previously-focused app window stays
        // un-keyed, so the first click back into it is eaten just re-focusing it.
        viewModel.$isOpen
            .removeDuplicates()
            .filter { !$0 }
            .sink { [weak self] _ in self?.relinquishKey() }
            .store(in: &cancellables)
    }

    /// Gives up key-window status if the panel currently holds it, so the app the
    /// user was in reclaims keyboard focus. Gated on `isKeyWindow` so it only runs
    /// after the note editor (the only thing that takes key) was used — an ordinary
    /// open never touches focus.
    ///
    /// We reactivate the previously-frontmost app rather than ordering our own pill
    /// out and back: the panel is a non-activating panel, so clicking into it never
    /// changed `frontmostApplication` — reasserting it makes that app reclaim the
    /// keyboard and resigns our key status, all *without* removing the pill from the
    /// screen. (The old order-out/order-front dance blanked the notch for a frame or
    /// two right as the collapse finished — a visible "disappear" at the animation's
    /// end.)
    private func relinquishKey() {
        guard let panel, panel.isKeyWindow else { return }
        // Let the collapse animation settle first, then hand focus back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak panel] in
            guard let panel, panel.isKeyWindow else { return }
            // Commit any in-progress text editing before dropping focus.
            panel.makeFirstResponder(nil)
            let front = NSWorkspace.shared.frontmostApplication
            if let front, front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                front.activate()
            } else {
                // Fallback for the unlikely case we're somehow frontmost: the old
                // route still releases key (with a brief blink, but focus is correct).
                panel.orderOut(nil)
                panel.orderFrontRegardless()
            }
        }
    }

    // MARK: - Crash logging

    /// Writes uncaught Objective-C exceptions to ~/Library/Logs/NotchGlass/crash.log
    /// so failures leave a readable report even for this borderless agent app.
    private func installCrashLogger() {
        // The handler must be a non-capturing C function pointer, so it derives
        // the log path itself rather than closing over anything.
        NSSetUncaughtExceptionHandler { exception in
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/NotchGlass", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let logURL = dir.appendingPathComponent("crash.log")

            let report = """
            [\(Date())] \(exception.name.rawValue)
            \(exception.reason ?? "no reason")

            \(exception.callStackSymbols.joined(separator: "\n"))

            """
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(Data(report.utf8))
                try? handle.close()
            } else {
                try? report.write(to: logURL, atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: - Panel

    private func buildPanel() {
        if let screen = targetScreen {
            viewModel.collapsedSize = notchSize(on: screen)
            viewModel.hasNotch = screen.safeAreaInsets.top > 0
        }

        let root = AnyView(
            RootView()
                .environmentObject(viewModel)
                .environmentObject(nowPlaying)
                .environmentObject(settings)
                .environmentObject(glassMenu)
                .environmentObject(gallery)
                .environmentObject(fuelManager)
                .environmentObject(audioLevels)
                .environmentObject(fuelEvents)
                .environmentObject(batteryMonitor)
                .ignoresSafeArea()
        )

        let hosting = NotchHostingView(rootView: root)
        hosting.autoresizingMask = [.width, .height]
        hosting.sizingOptions = []

        let panel = NotchPanel(contentRect: panelFrame())
        panel.contentView = hosting
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// The display that owns the notch, or the main screen as a fallback.
    private var targetScreen: NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main
    }

    private func notchSize(on screen: NSScreen) -> CGSize {
        let height = screen.safeAreaInsets.top
        if height > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            // Exactly the physical notch bounds: full width between the two
            // auxiliary menu-bar areas, and the notch's own height. No extra
            // padding, so the collapsed pill welds to the notch without spilling
            // sideways over the menu bar.
            let width = screen.frame.width - left.width - right.width
            return CGSize(width: max(width, 120), height: height)
        }
        // No physical notch: the pill floats just below the top edge, so a touch
        // of extra width reads better and can't overlap any real notch.
        return CGSize(width: Metrics.fallbackNotchWidth + Metrics.collapsedWidthPadding * 2, height: Metrics.fallbackNotchHeight)
    }

    /// The fixed window frame — always the full expanded region, top-centered on
    /// the notch display. Content morphs inside it; the window itself never resizes.
    private func panelFrame() -> NSRect {
        let width = Metrics.windowContentWidth(panelWidth: CGFloat(settings.panelWidth))
        let height = Metrics.windowContentHeight + Metrics.openTopGap
        guard let screen = targetScreen else {
            return NSRect(x: 0, y: 0, width: width, height: height)
        }
        let x = screen.frame.midX - width / 2
        let y = screen.frame.maxY - height
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func positionPanel() {
        if let screen = targetScreen {
            viewModel.collapsedSize = notchSize(on: screen)
            viewModel.hasNotch = screen.safeAreaInsets.top > 0
        }
        // `display: false` — the hosted SwiftUI content redraws reactively from the
        // `panelWidth` change, so we don't force a second synchronous window redraw on
        // every frame of a width-slider drag.
        panel?.setFrame(panelFrame(), display: false, animate: false)
    }
}
