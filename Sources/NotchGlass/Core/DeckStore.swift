import AppKit
import Combine

/// One programmable key on the Deck: an icon + label that fires an action when
/// tapped. Persisted (via `DeckStore`) as JSON in UserDefaults.
struct DeckButton: Identifiable, Codable, Equatable {
    /// The kind of thing a key does. The `payload` string is interpreted per-kind.
    enum Action: String, Codable, CaseIterable, Identifiable {
        case app        // payload: path to a .app (or bundle identifier)
        case url        // payload: a web URL
        case file       // payload: a file/folder path — opened with its default app
        case shortcut   // payload: a macOS Shortcuts.app shortcut name
        case shell      // payload: a shell command line

        var id: String { rawValue }

        var title: String {
            switch self {
            case .app:      return "Open App"
            case .url:      return "Open URL"
            case .file:     return "Open File"
            case .shortcut: return "Run Shortcut"
            case .shell:    return "Run Command"
            }
        }

        /// A sensible default glyph for a freshly created key of this kind.
        var defaultSymbol: String {
            switch self {
            case .app:      return "app.fill"
            case .url:      return "globe"
            case .file:     return "doc.fill"
            case .shortcut: return "bolt.fill"
            case .shell:    return "terminal.fill"
            }
        }

        /// Placeholder shown in the payload field while editing.
        var payloadPrompt: String {
            switch self {
            case .app:      return "/Applications/Safari.app"
            case .url:      return "https://example.com"
            case .file:     return "~/Documents/notes.txt"
            case .shortcut: return "Shortcut name"
            case .shell:    return "say hello"
            }
        }
    }

    var id = UUID()
    var label: String = ""
    var symbol: String = "square.grid.2x2.fill"
    var action: Action = .app
    var payload: String = ""

    /// Run this key's action. All UI-side effects hop to the main actor.
    @MainActor
    func run() {
        switch action {
        case .app:
            let expanded = (payload as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") {
                NSWorkspace.shared.open(URL(fileURLWithPath: expanded))
            } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: payload) {
                NSWorkspace.shared.open(url)
            }
        case .url:
            var s = payload.trimmingCharacters(in: .whitespaces)
            if !s.hasPrefix("http://") && !s.hasPrefix("https://") { s = "https://" + s }
            if let url = URL(string: s) { NSWorkspace.shared.open(url) }
        case .file:
            let expanded = (payload as NSString).expandingTildeInPath
            NSWorkspace.shared.open(URL(fileURLWithPath: expanded))
        case .shortcut:
            Self.launch("/usr/bin/shortcuts", ["run", payload])
        case .shell:
            Self.launch("/bin/zsh", ["-lc", payload])
        }
    }

    private static func launch(_ tool: String, _ args: [String]) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tool)
        proc.arguments = args
        do {
            try proc.run()
        } catch {
            NSLog("NotchGlass: deck action failed (\(tool)): \(error.localizedDescription)")
        }
    }
}

/// Persists the Deck's keys and exposes them to the tab. A standalone singleton
/// (like `CountdownTimer.shared`) so the feature stays self-contained rather than
/// threading through `SettingsStore`/`NotchViewModel`.
@MainActor
final class DeckStore: ObservableObject {
    static let shared = DeckStore()

    @Published var buttons: [DeckButton] {
        didSet { persist() }
    }

    private let key = "set.deckButtons"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([DeckButton].self, from: data) {
            buttons = decoded
        } else {
            buttons = []
        }
    }

    func add(_ button: DeckButton) { buttons.append(button) }

    func update(_ button: DeckButton) {
        guard let i = buttons.firstIndex(where: { $0.id == button.id }) else { return }
        buttons[i] = button
    }

    func remove(_ id: UUID) { buttons.removeAll { $0.id == id } }

    private func persist() {
        guard let data = try? JSONEncoder().encode(buttons) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
