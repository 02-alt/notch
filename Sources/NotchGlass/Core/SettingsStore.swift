import SwiftUI
import ServiceManagement

/// User preferences, persisted to UserDefaults and observed live by the UI.
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard

    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: "set.launchAtLogin")
            applyLaunchAtLogin()
        }
    }

    @Published var accentHex: String {
        didSet { defaults.set(accentHex, forKey: "set.accentHex") }
    }

    /// Surface treatment for the whole notch panel (opaque card vs. Liquid Glass).
    @Published var panelTheme: PanelTheme {
        didSet {
            defaults.set(panelTheme.rawValue, forKey: "set.panelTheme")
            // Repaint the whole app's neutral palette for the new theme.
            Theme.isLight = panelTheme.isLight
            Theme.isNoir = panelTheme.isNoir
        }
    }

    @Published var mediaPriority: MediaSource {
        didSet { defaults.set(mediaPriority.rawValue, forKey: "set.mediaPriority") }
    }

    /// Which media apps NotchGlass is allowed to read/control. Each enabled app
    /// triggers exactly one macOS Automation prompt (per app, by OS design);
    /// disabled apps are never contacted, so they never prompt. Kept small by
    /// default so a fresh install only asks about the mainstream players.
    @Published var enabledSources: Set<MediaSource> {
        didSet { defaults.set(enabledSources.map(\.rawValue), forKey: "set.enabledSources") }
    }

    func isSourceEnabled(_ source: MediaSource) -> Bool { enabledSources.contains(source) }

    func setSource(_ source: MediaSource, enabled: Bool) {
        if enabled { enabledSources.insert(source) } else { enabledSources.remove(source) }
    }

    @Published var showArtwork: Bool {
        didSet { defaults.set(showArtwork, forKey: "set.showArtwork") }
    }

    /// Whether the Media tab is showing lyrics (vs. the artwork + metadata). Persisted
    /// so the mode sticks across opens, and so the panel height can grow to give the
    /// lyrics + scrubber room to breathe (see `Metrics.bodyHeight`).
    @Published var mediaLyrics: Bool {
        didSet { defaults.set(mediaLyrics, forKey: "set.mediaLyrics") }
    }

    /// Keep the current synced lyric line showing on the *collapsed* notch, so you can
    /// follow along while working with the panel closed. Toggled from the Media tab's
    /// lyrics view; drives the collapsed line in `CollapsedMediaView` and keeps
    /// `LyricsService` fetching on every track change (see `AppDelegate`).
    @Published var pinLyrics: Bool {
        didSet { defaults.set(pinLyrics, forKey: "set.pinLyrics") }
    }

    /// What the *collapsed* notch shows. Media is the now-playing peek (art + EQ);
    /// fuel events are transient notices like "Fuel refilled" that need a slow
    /// background poll of your Claude usage, so they're opt-in.
    @Published var collapsedShowsMedia: Bool {
        didSet { defaults.set(collapsedShowsMedia, forKey: "set.collapsedShowsMedia") }
    }
    @Published var collapsedShowsFuelEvents: Bool {
        didSet { defaults.set(collapsedShowsFuelEvents, forKey: "set.collapsedShowsFuelEvents") }
    }

    /// Dynamic Island mode: the closed notch auto-expands *on its own* when a live
    /// activity starts (a new track, a timer, an AirDrop) — briefly morphing into a
    /// two-slot presentation that hugs the camera, then settling back. Off by
    /// default; it's a distinct, more attention-grabbing behaviour than the quiet
    /// resting peeks, so it's opt-in. See ``NotchViewModel/presentIsland(_:for:)``.
    @Published var dynamicIsland: Bool {
        didSet { defaults.set(dynamicIsland, forKey: "set.dynamicIsland") }
    }

    /// The quiet stat shown on the collapsed pill's right edge when nothing else is
    /// happening (see ``CollapsedResting``). `.fuel` / `.battery` spin up a slow
    /// background reader; `.none` keeps the plain-black resting pill.
    @Published var collapsedResting: CollapsedResting {
        didSet { defaults.set(collapsedResting.rawValue, forKey: "set.collapsedResting") }
    }

    /// Fuel resting glance: show the refill countdown **and** the % left together as
    /// one "↻ 3:45 · 88%" readout, instead of rotating between them. Off by default
    /// (the rotation keeps the pill text short); opt-in for people who'd rather see
    /// both at once.
    @Published var collapsedFuelCombined: Bool {
        didSet { defaults.set(collapsedFuelCombined, forKey: "set.collapsedFuelCombined") }
    }

    @Published var defaultTab: NotchTab {
        didSet { defaults.set(defaultTab.rawValue, forKey: "set.defaultTab") }
    }

    /// The tabs currently shown in the panel's tab bar, in order. Seeded with
    /// `NotchTab.defaultTabs`; optional tabs (Fuel) are added via the "+" button.
    @Published var enabledTabs: [NotchTab] {
        didSet { defaults.set(enabledTabs.map(\.rawValue), forKey: "set.enabledTabs") }
    }

    /// Tabs not yet in the bar — what the "+" menu offers.
    var addableTabs: [NotchTab] { NotchTab.allCases.filter { !enabledTabs.contains($0) } }

    /// Whether a tab can be removed from the bar. Every tab is removable; the
    /// only floor is that at least one tab must remain (enforced in `removeTab`).
    func isRemovable(_ tab: NotchTab) -> Bool { enabledTabs.count > 1 }

    func addTab(_ tab: NotchTab) {
        guard !enabledTabs.contains(tab) else { return }
        enabledTabs.append(tab)
    }

    func removeTab(_ tab: NotchTab) {
        guard enabledTabs.count > 1 else { return }
        enabledTabs.removeAll { $0 == tab }
    }

    /// Which AI the Fuel tab shows usage for. Switched from the tab's header picker.
    @Published var fuelProvider: AIProvider {
        didSet { defaults.set(fuelProvider.rawValue, forKey: "set.fuelProvider") }
    }

    /// How often the Fuel tab re-reads live usage while it's open. `FuelManager`
    /// observes this and reschedules its poll (and bases its rate-limit backoff on it).
    @Published var fuelRefreshRate: FuelRefreshRate {
        didSet { defaults.set(fuelRefreshRate.rawValue, forKey: "set.fuelRefreshRate") }
    }

    /// The Fuel stat blocks, in display order. The first block is drawn large as the
    /// headline gauge; the rest fill the grid of small cards. Reordered by dragging and
    /// added/removed from the tab. Defaults to the session gauge + weekly + resets.
    @Published var enabledFuelBlocks: [FuelBlock] {
        didSet { defaults.set(enabledFuelBlocks.map(\.rawValue), forKey: "set.fuelLayout") }
    }

    /// Blocks not yet on the tab — what the Fuel "+" menu offers.
    var addableFuelBlocks: [FuelBlock] { FuelBlock.allCases.filter { !enabledFuelBlocks.contains($0) } }

    func addFuelBlock(_ block: FuelBlock) {
        guard !enabledFuelBlocks.contains(block) else { return }
        enabledFuelBlocks.append(block)
    }

    func removeFuelBlock(_ block: FuelBlock) {
        // Keep at least one block so the tab is never blank.
        guard enabledFuelBlocks.count > 1 else { return }
        enabledFuelBlocks.removeAll { $0 == block }
    }

    /// Replace the whole ordering (used by the drag-to-reorder grid).
    func reorderFuelBlocks(_ blocks: [FuelBlock]) {
        guard blocks != enabledFuelBlocks else { return }
        enabledFuelBlocks = blocks
    }

    /// Promote a block to the big headline slot (index 0), keeping the rest in order.
    func featureFuelBlock(_ block: FuelBlock) {
        guard let idx = enabledFuelBlocks.firstIndex(of: block), idx != 0 else { return }
        var next = enabledFuelBlocks
        next.remove(at: idx)
        next.insert(block, at: 0)
        enabledFuelBlocks = next
    }

    /// Delay before the panel collapses after the pointer leaves (seconds).
    @Published var closeDelay: Double {
        didSet { defaults.set(closeDelay, forKey: "set.closeDelay") }
    }

    @Published var panelWidth: Double {
        didSet {
            // Reframe live so the panel tracks the slider, but debounce the disk write
            // so dragging the width slider isn't hammering UserDefaults every frame.
            onPanelWidthChange?(panelWidth)
            panelWidthPersistWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.defaults.set(self.panelWidth, forKey: "set.panelWidth")
            }
            panelWidthPersistWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }
    private var panelWidthPersistWork: DispatchWorkItem?

    /// Set by AppDelegate to reposition the window when the width changes.
    var onPanelWidthChange: ((Double) -> Void)?

    var accent: Color {
        // The Analogue themes are monochrome: the "accent" that most chrome reads
        // (selected fills, tints, icons) is a neutral — near-white on Noir's black,
        // near-black on the Light surface — so the whole app stays black-and-white,
        // with no coloured accent at all.
        switch panelTheme {
        case .noir:  return Color(white: 0.93)
        case .light: return Color(white: 0.16)
        default:     return Color(hex: accentHex) ?? Color(red: 0.30, green: 0.52, blue: 0.98)
        }
    }

    private init() {
        launchAtLogin = defaults.bool(forKey: "set.launchAtLogin")
        accentHex = defaults.string(forKey: "set.accentHex") ?? "4C84FA"
        // Noir (deep-black monochrome) is the app's default look; the others are opt-in in Settings.
        panelTheme = PanelTheme(rawValue: defaults.string(forKey: "set.panelTheme") ?? "") ?? .noir
        mediaPriority = MediaSource(rawValue: defaults.string(forKey: "set.mediaPriority") ?? "") ?? .spotify
        // Only auto-enable Yoin once it's actually installed — never pre-enable a player
        // the user doesn't have, or a later install would be silently contacted (and
        // prompt for Automation) without the user ever choosing it.
        let yoinInstalled = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: MediaSource.yoin.bundleID) != nil
        if let raw = defaults.array(forKey: "set.enabledSources") as? [String] {
            var sources = Set(raw.compactMap { MediaSource(rawValue: $0) })
            // One-time: fold Yoin into an existing install's enabled set (it didn't
            // exist when they first configured sources). Deferred until Yoin is present,
            // then respected if later disabled. Persist immediately — assigning in init
            // doesn't fire the didSet, so otherwise the added source is dropped next launch.
            if yoinInstalled && !defaults.bool(forKey: "set.yoinAdded") {
                sources.insert(.yoin)
                defaults.set(sources.map(\.rawValue), forKey: "set.enabledSources")
                defaults.set(true, forKey: "set.yoinAdded")
            }
            enabledSources = sources
        } else {
            // Default: the mainstream players (plus Yoin when installed) only, so a fresh
            // install doesn't prompt for every browser — or a player — you don't have.
            var defaults0: Set<MediaSource> = [.music, .spotify, .safari, .chrome]
            if yoinInstalled { defaults0.insert(.yoin); defaults.set(true, forKey: "set.yoinAdded") }
            enabledSources = defaults0
        }
        showArtwork = defaults.object(forKey: "set.showArtwork") as? Bool ?? true
        mediaLyrics = defaults.object(forKey: "set.mediaLyrics") as? Bool ?? false
        pinLyrics = defaults.object(forKey: "set.pinLyrics") as? Bool ?? false
        collapsedShowsMedia = defaults.object(forKey: "set.collapsedShowsMedia") as? Bool ?? true
        collapsedShowsFuelEvents = defaults.object(forKey: "set.collapsedShowsFuelEvents") as? Bool ?? false
        dynamicIsland = defaults.object(forKey: "set.dynamicIsland") as? Bool ?? false
        collapsedResting = CollapsedResting(rawValue: defaults.string(forKey: "set.collapsedResting") ?? "") ?? .none
        collapsedFuelCombined = defaults.object(forKey: "set.collapsedFuelCombined") as? Bool ?? false
        defaultTab = NotchTab(rawValue: defaults.string(forKey: "set.defaultTab") ?? "") ?? .media
        if let raw = defaults.array(forKey: "set.enabledTabs") as? [String] {
            let tabs = raw.compactMap { NotchTab(rawValue: $0) }
            enabledTabs = tabs.isEmpty ? NotchTab.defaultTabs : tabs
        } else {
            enabledTabs = NotchTab.defaultTabs
        }
        fuelProvider = AIProvider(rawValue: defaults.string(forKey: "set.fuelProvider") ?? "") ?? .claude
        fuelRefreshRate = FuelRefreshRate(rawValue: defaults.string(forKey: "set.fuelRefreshRate") ?? "") ?? .normal
        if let raw = defaults.array(forKey: "set.fuelLayout") as? [String] {
            let blocks = raw.compactMap { FuelBlock(rawValue: $0) }
            enabledFuelBlocks = blocks.isEmpty ? FuelBlock.defaultLayout : blocks
        } else if let old = defaults.array(forKey: "set.fuelBlocks") as? [String] {
            // Migrate the old format: the session/weekly/resets gauges used to be an
            // implicit top row, so prepend them to whatever optional blocks were saved.
            let migrated = old.compactMap { FuelBlock(rawValue: $0) }
            enabledFuelBlocks = FuelBlock.liveDefaults + migrated.filter { !FuelBlock.liveDefaults.contains($0) }
        } else {
            enabledFuelBlocks = FuelBlock.defaultLayout
        }
        closeDelay = defaults.object(forKey: "set.closeDelay") as? Double ?? 0.28
        panelWidth = defaults.object(forKey: "set.panelWidth") as? Double ?? Double(Metrics.openWidth)
        // `didSet` doesn't run for the initial assignment above, so seed the
        // palette's structural flags from the loaded theme here.
        Theme.isLight = panelTheme.isLight
        Theme.isNoir = panelTheme.isNoir
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            NSLog("NotchGlass: launch-at-login change failed: \(error.localizedDescription)")
        }
    }
}
