import SwiftUI
import UniformTypeIdentifiers

/// The tabs of the notch panel.
enum NotchTab: String, CaseIterable, Identifiable {
    case media
    case mood
    case drop
    case website
    case note
    case ambient
    case map
    case weather
    case clock
    case calendar
    case scratch
    case fuel
    case record
    case deck
    case now
    case countdown
    case shortcuts

    var id: String { rawValue }

    /// The tabs a fresh install starts with, in order. This is only the initial
    /// seed for `SettingsStore.enabledTabs` — every tab is freely removable and
    /// re-addable from the "+" menu afterwards (Fuel just isn't shown by default).
    static let defaultTabs: [NotchTab] = [.media, .note, .drop, .map]

    var symbol: String {
        switch self {
        case .media:   return "house.fill"
        case .mood:    return "square.grid.2x2.fill"
        case .drop:    return "tray.and.arrow.down.fill"
        case .website: return "globe"
        case .note:    return "note.text"
        case .ambient: return "cloud.rain.fill"
        case .map:     return "map.fill"
        case .weather: return "cloud.sun.fill"
        case .clock:   return "clock.fill"
        case .calendar: return "calendar"
        case .scratch: return "ellipsis.message.fill"
        case .fuel:    return "fuelpump.fill"
        case .record:  return "record.circle"
        case .deck:    return "square.grid.3x3.fill"
        case .now:     return "gauge.high"
        case .countdown: return "hourglass"
        case .shortcuts: return "bolt.fill"
        }
    }

    var title: String {
        switch self {
        case .media:   return "Media"
        case .mood:    return "Mood"
        case .drop:    return "Drop"
        case .website: return "Websites"
        case .note:    return "Note"
        case .ambient: return "Ambient"
        case .map:     return "Map"
        case .weather: return "Weather"
        case .clock:   return "Clock"
        case .calendar: return "Calendar"
        case .scratch: return "Chat"
        case .fuel:    return "Fuel"
        case .record:  return "Record"
        case .deck:    return "Deck"
        case .now:     return "System"
        case .countdown: return "Countdown"
        case .shortcuts: return "Shortcuts"
        }
    }

    /// A one-line description shown under the title in the add-tab gallery, so a
    /// tab reads as more than a bare name when the list gets long.
    var subtitle: String {
        switch self {
        case .media:    return "Now-playing controls"
        case .mood:     return "Freeform sticky board"
        case .drop:     return "Parked-file shelf"
        case .website:  return "Saved site shortcuts"
        case .note:     return "Quick notes & lists"
        case .ambient:  return "Background soundscapes"
        case .map:      return "Your place at a glance"
        case .weather:  return "Forecast & conditions"
        case .clock:    return "World clocks & timers"
        case .calendar: return "Upcoming agenda"
        case .scratch:  return "Chat with Claude"
        case .fuel:     return "AI usage & limits"
        case .record:   return "Screen recording"
        case .deck:     return "Shortcut key deck"
        case .now:      return "Live machine vitals"
        case .countdown: return "Days until a date"
        case .shortcuts: return "One-tap launchers"
        }
    }

    /// Extra search terms for the gallery's search field, beyond `title` /
    /// `subtitle` — so "focus" finds Clock + Ambient, "pomodoro" finds the timer,
    /// "ai" finds Chat + Fuel, and so on.
    var keywords: [String] {
        switch self {
        case .media:    return ["music", "spotify", "player", "song", "play", "podcast"]
        case .mood:     return ["board", "stickers", "pin", "links", "corkboard"]
        case .drop:     return ["files", "airdrop", "shelf", "transfer", "share"]
        case .website:  return ["bookmarks", "web", "sites", "url", "links"]
        case .note:     return ["text", "checklist", "write", "memo", "todo"]
        case .ambient:  return ["rain", "noise", "focus", "sound", "relax", "sleep"]
        case .map:      return ["location", "maps", "directions", "place"]
        case .weather:  return ["forecast", "temperature", "rain", "sun", "climate"]
        case .clock:    return ["time", "timer", "pomodoro", "alarm", "stopwatch", "focus"]
        case .calendar: return ["events", "schedule", "agenda", "meetings", "dates"]
        case .scratch:  return ["ai", "claude", "chat", "assistant", "gpt", "llm"]
        case .fuel:     return ["tokens", "usage", "claude", "api", "limits", "quota"]
        case .record:   return ["screen", "capture", "video", "record", "clip"]
        case .deck:     return ["shortcuts", "keys", "macros", "actions", "grid"]
        case .now:      return ["cpu", "ram", "memory", "network", "monitor", "activity", "stats", "pulse", "system"]
        case .countdown: return ["countdown", "date", "event", "until", "days", "deadline", "trip"]
        case .shortcuts: return ["launch", "run", "script", "command", "automation", "shortcut", "app"]
        }
    }

    /// Whether this tab matches a search query, tested against title, subtitle and
    /// keywords. An empty/whitespace query matches everything.
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        if title.lowercased().contains(q) || subtitle.lowercased().contains(q) { return true }
        return keywords.contains { $0.contains(q) }
    }

    /// The bucket a tab belongs to. Only surfaced once the strip grows past
    /// `Metrics.tabCategoryThreshold` tabs — below that the strip stays flat and
    /// categories are invisible. See `TopBar` in PanelView.
    var category: Category {
        switch self {
        case .media, .ambient:            return .media
        case .drop, .website, .note, .scratch, .fuel, .record, .deck, .shortcuts: return .tools
        case .mood, .map, .weather, .clock, .calendar, .now, .countdown: return .glance
        }
    }

    /// Coarse groupings for the segmented category row that replaces the flat
    /// strip once a lot of tabs are enabled.
    enum Category: String, CaseIterable, Identifiable {
        case media, tools, glance

        var id: String { rawValue }

        var title: String {
            switch self {
            case .media:  return "Media"
            case .tools:  return "Tools"
            case .glance: return "Glance"
            }
        }

        var symbol: String {
            switch self {
            case .media:  return "play.circle.fill"
            case .tools:  return "wrench.and.screwdriver.fill"
            case .glance: return "sparkles"
            }
        }
    }
}

/// What the *collapsed* pill shows on its right edge when nothing transient is
/// happening (no media peek, no AirDrop, no fuel event) — the "resting" glance.
/// `.none` keeps the classic plain-black pill; the rest surface one quiet stat.
/// `.fuel` / `.battery` need a live source, so choosing them starts the relevant
/// background reader (see `FuelEventMonitor` / `BatteryMonitor`).
enum CollapsedResting: String, CaseIterable, Identifiable {
    case none, fuel, clock, battery, date, countdown, storage, weather, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none:      return "Nothing"
        case .fuel:      return "Fuel"
        case .clock:     return "Clock"
        case .battery:   return "Battery"
        case .date:      return "Date"
        case .countdown: return "Countdown"
        case .storage:   return "Storage"
        case .weather:   return "Weather"
        case .system:    return "System"
        }
    }

    var symbol: String {
        switch self {
        case .none:      return "circle.dashed"
        case .fuel:      return "fuelpump.fill"
        case .clock:     return "clock.fill"
        case .battery:   return "battery.100"
        case .date:      return "calendar"
        case .countdown: return "hourglass"
        case .storage:   return "internaldrive.fill"
        case .weather:   return "cloud.sun.fill"
        case .system:    return "gauge.high"
        }
    }

    /// Whether this option depends on a background reader that has to be spun up.
    /// Date/Countdown/Storage are cheap local reads (a `TimelineView` tick or a one-off
    /// disk query); Fuel/Battery/Weather/System each drive a gentle background poll.
    var needsPolling: Bool {
        switch self {
        case .fuel, .battery, .weather, .system: return true
        default: return false
        }
    }
}

/// How often the Fuel tab re-reads live usage while it's on screen. Faster cadences
/// feel more live but poll the provider's usage endpoint harder, so they're likelier
/// to trip its rate limit — hence the opt-in picker in Settings. `.normal` is the
/// safe default that stays well clear of the throttle.
enum FuelRefreshRate: String, CaseIterable, Identifiable {
    case live, normal, relaxed

    var id: String { rawValue }

    /// Poll cadence in seconds. Also the base unit the rate-limit backoff grows from,
    /// so a faster setting recovers from a throttle sooner too.
    var interval: TimeInterval {
        switch self {
        case .live:    return 5
        case .normal:  return 30
        case .relaxed: return 60
        }
    }

    var title: String {
        switch self {
        case .live:    return "Live · 5s"
        case .normal:  return "Normal · 30s"
        case .relaxed: return "Relaxed · 60s"
        }
    }

    var symbol: String {
        switch self {
        case .live:    return "bolt.fill"
        case .normal:  return "clock"
        case .relaxed: return "tortoise.fill"
        }
    }
}

/// The surface treatment for the whole notch panel, switchable in Settings.
/// `.glass` (the default) frosts the entire expanded panel as translucent Liquid
/// Glass so the desktop shows through it; `.noir` is the deep black-glass card.
enum PanelTheme: String, CaseIterable, Identifiable {
    // Glass leads: it's the default look, so it's the first tile in the picker.
    case glass, noir, light

    var id: String { rawValue }

    var title: String {
        switch self {
        case .glass: return "Liquid Glass"
        case .light: return "Light"
        case .noir:  return "Noir"
        }
    }

    var symbol: String {
        switch self {
        case .glass: return "sparkles"
        case .light: return "sun.max.fill"
        case .noir:  return "flame.fill"
        }
    }

    /// Whether the panel paints on a light surface, so content is rendered
    /// dark-on-light instead of the default white-on-dark. Drives the whole
    /// `Theme` palette (see ``Theme/isLight``).
    var isLight: Bool { self == .light }

    /// The Noir surface: a deep near-black panel with a single baked-in ember
    /// accent. Still a dark (white-on-black) scheme, so it doesn't set
    /// ``isLight``; it drives ``Theme/isNoir`` for the surface + accent choice.
    var isNoir: Bool { self == .noir }
}

/// The top-level sections of the in-notch Settings pane. Rather than stacking
/// every group on one tall screen, the settings are split into a few broad
/// categories switched by a pill selector at the top — so each screen stays
/// short and the panel resizes to fit only the visible category.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, appearance, media, notch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:    return "General"
        case .appearance: return "Appearance"
        case .media:      return "Media"
        case .notch:      return "Notch"
        }
    }

    var symbol: String {
        switch self {
        case .general:    return "gearshape"
        case .appearance: return "paintpalette"
        case .media:      return "music.note"
        case .notch:      return "rectangle.topthird.inset.filled"
        }
    }
}

/// A background ambience scene. Each non-`off` case loops a bundled field
/// recording (see `Resources/ambience/*`), matching the set used in the Encore
/// emulator so the two apps share the same soundscapes.
enum AmbientScene: String, CaseIterable, Identifiable {
    case off, rain, storm, cabin, park, shore

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:   return "Off"
        case .rain:  return "Rain"
        case .storm: return "Storm"
        case .cabin: return "Cabin"
        case .park:  return "Park"
        case .shore: return "Shore"
        }
    }

    var symbol: String {
        switch self {
        case .off:   return "speaker.slash.fill"
        case .rain:  return "cloud.rain.fill"
        case .storm: return "cloud.bolt.rain.fill"
        case .cabin: return "airplane"
        case .park:  return "bird.fill"
        case .shore: return "water.waves"
        }
    }

    /// Bundled resource base-name (`Resources/ambience/<name>.<ext>`), or nil for `.off`.
    var resource: String? {
        self == .off ? nil : rawValue
    }
}

/// A single item pinned to the freeform Mood board: a note, a link or a file.
/// Positions are stored normalized (0...1) to the canvas so they survive resizes
/// and the switch between the compact and expanded board.
struct MoodItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case note, link, file }

    var id = UUID()
    var kind: Kind
    /// Note text, link URL string, or file path — depending on `kind`.
    var content: String = ""
    /// Display title (note's first line, link host, or file name).
    var title: String = ""
    /// Normalized center within the canvas.
    var x: Double = 0.5
    var y: Double = 0.5
    /// A small tilt for the freeform "sticker" feel (degrees). Ignored when the
    /// board is magnetized.
    var rotation: Double = 0
    /// User-set size multiplier for the tile (drag the corner handle to resize).
    /// Optional so items saved before resizing existed still decode.
    var scale: Double?

    // Per-note appearance (notes only). Optional so notes saved before these
    // existed still decode; views fall back to sensible defaults.
    var noteColor: NoteColor?
    var noteStyle: NoteStyle?
    var noteTextSize: NoteTextSize?

    var url: URL? {
        switch kind {
        case .link:
            if content.hasPrefix("http://") || content.hasPrefix("https://") {
                return URL(string: content)
            }
            return URL(string: "https://" + content)
        case .file:
            return URL(fileURLWithPath: content)
        case .note:
            return nil
        }
    }

    var host: String {
        url?.host()?.replacingOccurrences(of: "www.", with: "") ?? content
    }

    /// Favicon fetched straight from the site's own `/favicon.ico`, so the list of
    /// links the user cares about is never handed to a third party (Google's favicon
    /// service would otherwise receive the hostname + the user's IP on every render).
    var faviconURL: URL? {
        guard kind == .link, let host = url?.host() else { return nil }
        return URL(string: "https://\(host)/favicon.ico")
    }

    /// The video id when this link points at a YouTube watch/short/embed URL, so
    /// callers can render it as a wide 16:9 video card rather than a square tile.
    var youTubeVideoID: String? {
        guard kind == .link, let url, let host = url.host()?.lowercased() else { return nil }
        if host.contains("youtu.be") {
            let id = url.lastPathComponent
            return id.isEmpty || id == "/" ? nil : id
        }
        guard host.contains("youtube.com") else { return nil }
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let v = comps.queryItems?.first(where: { $0.name == "v" })?.value {
            return v
        }
        let parts = url.pathComponents
        if let i = parts.firstIndex(where: { $0 == "shorts" || $0 == "embed" }), i + 1 < parts.count {
            return parts[i + 1]
        }
        return nil
    }

    var fileIcon: NSImage? {
        guard kind == .file else { return nil }
        return NSWorkspace.shared.icon(forFile: content)
    }
}

/// A mood note's paper color. `.accent` follows the app accent; the rest are fixed.
enum NoteColor: String, Codable, CaseIterable, Identifiable {
    case accent, yellow, pink, green, blue, purple, grey
    var id: String { rawValue }

    var label: String { rawValue.capitalized }

    func color(accent: Color) -> Color {
        switch self {
        case .accent: return accent
        case .yellow: return Color(red: 0.98, green: 0.82, blue: 0.30)
        case .pink:   return Color(red: 0.96, green: 0.45, blue: 0.63)
        case .green:  return Color(red: 0.40, green: 0.80, blue: 0.52)
        case .blue:   return Color(red: 0.36, green: 0.62, blue: 0.98)
        case .purple: return Color(red: 0.66, green: 0.52, blue: 0.98)
        case .grey:   return Color(white: 0.6)
        }
    }
}

/// A mood note's visual treatment.
enum NoteStyle: String, Codable, CaseIterable, Identifiable {
    case minimal, sticky, glass, index
    var id: String { rawValue }
    var label: String {
        switch self {
        case .minimal: return "Minimal"
        case .sticky:  return "Sticky"
        case .glass:   return "Glass"
        case .index:   return "Index Card"
        }
    }
}

enum NoteTextSize: String, Codable, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var points: CGFloat {
        switch self {
        case .small: return 11
        case .medium: return 13
        case .large: return 16
        }
    }
}

/// A file parked in the drop shelf.
struct DroppedItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL

    var name: String { url.lastPathComponent }

    var icon: NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// A photo attached to a note. The bytes live on disk in `NoteImageStore`; the
/// note only carries the relative `filename` so it stays cheap to encode.
struct NoteImage: Identifiable, Codable, Equatable {
    var id = UUID()
    /// File name within `NoteImageStore.directory`.
    var filename: String
}

/// One run of a note's inline body: either a span of text or an image card that
/// sits *inside* the writing. Ordering these lets photos flow between the words
/// (drop an image and it lands where the caret is) instead of piling up in a
/// separate strip.
enum NoteRun: Equatable {
    case text(String)
    case image(NoteImage)
}

extension NoteRun: Codable {
    private enum CodingKeys: String, CodingKey { case kind, text, image }
    private enum Kind: String, Codable { case text, image }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .text:  self = .text(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        case .image: self = .image(try c.decode(NoteImage.self, forKey: .image))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let s):
            try c.encode(Kind.text, forKey: .kind)
            try c.encode(s, forKey: .text)
        case .image(let image):
            try c.encode(Kind.image, forKey: .kind)
            try c.encode(image, forKey: .image)
        }
    }
}

/// A single tick-box in a note's checklist. `done` drives the radio button; the
/// row is struck through and dimmed once completed.
struct ChecklistItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String = ""
    var done: Bool = false
}

/// A single note in the Note tab.
struct NoteItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String = ""
    var modified: Date = Date()
    /// The leather "book" this note is filed in, or nil for a loose note.
    /// Optional so notes saved before books existed still decode.
    var folderID: UUID?
    /// Photos pinned to the note. Defaults empty for notes saved before images.
    var images: [NoteImage] = []
    /// A user-chosen name for the note. When nil/blank the title falls back to the
    /// note's first line. Optional so notes saved before renaming existed decode.
    var customTitle: String?
    /// The note's tick-list. Optional so notes saved before checklists existed
    /// still decode; views read it through `checklist ?? []`.
    var checklist: [ChecklistItem]?
    /// The inline body: ordered text/image runs so photos flow between the words.
    /// `nil` for notes written before inline images — those migrate from `text`
    /// + `images` the first time they're opened. `text` and `images` are kept in
    /// sync as the plain-text/photo projections used by the title, preview, card
    /// header, and disk cleanup.
    var richBody: [NoteRun]?

    /// The card/editor title: the custom name if set, otherwise the first line.
    var title: String {
        if let custom = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        let line = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        return line.isEmpty ? "New Note" : line
    }

    var preview: String {
        text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .dropFirst()
            .first
            .map(String.init) ?? ""
    }
}

extension NoteItem {
    /// Tolerant decoder so notes saved before `folderID`/`images` existed still
    /// load. Placed in an extension so the memberwise + no-arg initializers the
    /// rest of the app relies on (`NoteItem()`, `NoteItem(text:)`) are preserved.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        modified = try c.decodeIfPresent(Date.self, forKey: .modified) ?? Date()
        folderID = try c.decodeIfPresent(UUID.self, forKey: .folderID)
        images = try c.decodeIfPresent([NoteImage].self, forKey: .images) ?? []
        customTitle = try c.decodeIfPresent(String.self, forKey: .customTitle)
        checklist = try c.decodeIfPresent([ChecklistItem].self, forKey: .checklist)
        richBody = try c.decodeIfPresent([NoteRun].self, forKey: .richBody)
    }
}

/// A leather-bound "book" that groups notes together in the Note tab.
struct NoteFolder: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String = "New Folder"
}

/// A saved website in the website shelf.
struct WebsiteItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var urlString: String

    var url: URL? {
        if urlString.hasPrefix("http://") || urlString.hasPrefix("https://") {
            return URL(string: urlString)
        }
        return URL(string: "https://" + urlString)
    }

    var host: String {
        url?.host()?.replacingOccurrences(of: "www.", with: "") ?? urlString
    }

    /// Favicon fetched straight from the site's own `/favicon.ico`, so the user's saved
    /// hostnames are never leaked to a third-party favicon service (e.g. Google).
    var faviconURL: URL? {
        guard let host = url?.host() else { return nil }
        return URL(string: "https://\(host)/favicon.ico")
    }
}

/// A named group of websites in the website shelf.
struct WebsiteFolder: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String = "New Folder"
    var sites: [WebsiteItem] = []
}
