import Foundation

/// One entry in a release's changelog — an icon, a headline and a short detail line,
/// rendered as a row in the What's New card.
struct ReleaseChange: Identifiable {
    let symbol: String
    let title: String
    let detail: String
    var id: String { title }
}

/// A single version's release notes, shown in the in-notch "What's New" card the
/// first time the panel is opened after updating to it.
struct ReleaseNote: Identifiable {
    let version: String
    /// Optional one-line headline for the whole release (under the version badge).
    let summary: String
    let changes: [ReleaseChange]
    var id: String { version }
}

/// The app's changelog plus the bookkeeping that decides when to surface it.
///
/// On the first panel-open after an update, `WhatsNew` compares the running version
/// against the last one the user acknowledged (persisted in `UserDefaults`) and, if
/// there's something new, the panel presents ``WhatsNewView``. Acknowledging it (or
/// opening it manually from Settings) stamps the current version so it won't nag.
enum WhatsNew {
    private static let seenKey = "notch.whatsNewSeenVersion"

    /// The running app's short version (from the bundle's Info.plist).
    static var currentVersion: String { Updater.currentVersion }

    /// The changelog, **newest first**. Prepend a new entry each release.
    static let releases: [ReleaseNote] = [
        ReleaseNote(
            version: "1.26.08.1",
            summary: "Three new tabs and a smarter closed notch.",
            changes: [
                ReleaseChange(
                    symbol: "gauge.high",
                    title: "System tab",
                    detail: "A live pulse of your Mac — CPU load, memory pressure and network throughput, each a hero readout over a sparkline of the last minute. Every sample is read locally; nothing leaves the machine."
                ),
                ReleaseChange(
                    symbol: "hourglass",
                    title: "Countdown tab",
                    detail: "Pin the dates you're counting toward — a launch, a trip, a birthday — and watch the time left tick down live. The nearest one leads; the rest stack below."
                ),
                ReleaseChange(
                    symbol: "bolt.fill",
                    title: "Shortcuts tab",
                    detail: "A grid of one-tap launchers you define: run a macOS Shortcut, fire a shell command, open a URL or launch an app — a personal Raycast-style pad, right in the notch."
                ),
                ReleaseChange(
                    symbol: "moon.stars.fill",
                    title: "Real moon photos",
                    detail: "The Moon now shows NASA's actual hourly photograph for this very instant — true phase, libration and size — instead of a drawing."
                ),
                ReleaseChange(
                    symbol: "rectangle.on.rectangle",
                    title: "Smarter closed notch",
                    detail: "The resting pill can now glance a live System (CPU) gauge, the current Weather or your next Countdown — kept fresh in the background even before you open the tab."
                ),
            ]
        ),
        ReleaseNote(
            version: "1.26.08",
            summary: "A Liquid Glass notch you can shape into anything.",
            changes: [
                ReleaseChange(
                    symbol: "drop.fill",
                    title: "Liquid Glass, everywhere",
                    detail: "The whole notch is now real Liquid Glass — a Siri-style hood that frosts and lenses the desktop right through it. It's the new default look."
                ),
                ReleaseChange(
                    symbol: "plus.app.fill",
                    title: "A tab for everything",
                    detail: "Tap “+” to browse a searchable gallery and add or remove tabs — Calendar, Maps, Weather, Websites, screen Record, a shortcut Deck and a Mood board — so the notch fits how you work."
                ),
                ReleaseChange(
                    symbol: "bubbles.and.sparkles.fill",
                    title: "Dynamic Island mode",
                    detail: "Flip it on and the closed notch becomes an always-on island — the time on one side, battery and date on the other. It also expands on its own for live moments — a new track, a finished timer, an incoming AirDrop — then settles back. Off by default; turn it on in Settings."
                ),
                ReleaseChange(
                    symbol: "ellipsis.message.fill",
                    title: "Chat with Claude",
                    detail: "Ask Claude right inside the notch with the new Chat tab, signed in with your own account — no extra setup."
                ),
                ReleaseChange(
                    symbol: "cloud.rain.fill",
                    title: "Ambient soundscapes",
                    detail: "Rain, shore, storm, park or a crackling cabin — play a background soundscape to focus or wind down without leaving your work."
                ),
                ReleaseChange(
                    symbol: "clock.fill",
                    title: "Clocks, timers & Pomodoro",
                    detail: "World clocks, quick countdown timers and a Pomodoro focus cycle, all living in one Clock tab."
                ),
                ReleaseChange(
                    symbol: "paintpalette.fill",
                    title: "Pick your look",
                    detail: "Switch between Liquid Glass, deep-black Noir and a bright Light theme in Settings to match your desktop and mood."
                ),
            ]
        ),
        ReleaseNote(
            version: "1.1",
            summary: "Clearer numbers, nicer photos, and a livelier notch.",
            changes: [
                ReleaseChange(
                    symbol: "fuelpump.fill",
                    title: "Bigger Fuel numbers",
                    detail: "Timers and key stats now fill their card with large hero digits, readable at a glance."
                ),
                ReleaseChange(
                    symbol: "photo.on.rectangle.angled",
                    title: "Cover-flow photo stacks",
                    detail: "Tap a photo pile in a note to flip through it in a fanned cover-flow — click, swipe, or use the arrows."
                ),
                ReleaseChange(
                    symbol: "bolt.fill",
                    title: "Faster Fuel refresh",
                    detail: "Pick a refresh rate in Settings, and rate-limits now clear in seconds instead of minutes."
                ),
                ReleaseChange(
                    symbol: "bell.badge.fill",
                    title: "Notch alerts",
                    detail: "The closed notch briefly opens to tell you when tokens refill or run low, you hit the weekly limit, or you start using credits."
                ),
                ReleaseChange(
                    symbol: "gauge.with.dots.needle.bottom.50percent",
                    title: "Fuel while you listen",
                    detail: "Your fuel or battery now rides alongside the now-playing peek in the closed notch, instead of hiding while music plays."
                ),
            ]
        ),
    ]

    /// The version the user last acknowledged, if any.
    private static var lastSeenVersion: String? {
        UserDefaults.standard.string(forKey: seenKey)
    }

    /// Release notes the user hasn't acknowledged yet, newest first.
    ///
    /// With a recorded version, that's everything newer than it. With no record
    /// (a fresh install, or the first run after this feature shipped), we surface
    /// just the current version's note once — a light "here's what's new" — rather
    /// than replaying the entire history.
    static var unseenNotes: [ReleaseNote] {
        guard let last = lastSeenVersion else {
            return releases.filter { $0.version == currentVersion }
        }
        return releases.filter { isNewer($0.version, than: last) }
    }

    static var hasUnseenNotes: Bool { !unseenNotes.isEmpty }

    /// What the card shows: the unseen notes, or — when opened manually from
    /// Settings with nothing new — the latest release so there's always something.
    static var notesToShow: [ReleaseNote] {
        let unseen = unseenNotes
        return unseen.isEmpty ? Array(releases.prefix(1)) : unseen
    }

    /// Total number of change rows the card will render — drives the panel height so
    /// it's tall enough to show them all.
    static var visibleChangeCount: Int {
        notesToShow.reduce(0) { $0 + $1.changes.count }
    }

    /// Record that the user has caught up to the current version.
    static func markSeen() {
        UserDefaults.standard.set(currentVersion, forKey: seenKey)
    }

    /// Numeric, component-wise semver comparison (e.g. "1.10" > "1.9").
    private static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        let a = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let b = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
