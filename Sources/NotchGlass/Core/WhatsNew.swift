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
            version: "1.1",
            summary: "Clearer numbers, nicer photos, faster fuel.",
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
                    detail: "Choose a refresh rate in Settings, and rate-limits now clear in seconds instead of minutes."
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
