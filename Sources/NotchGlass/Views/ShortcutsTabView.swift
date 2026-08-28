import SwiftUI
import AppKit

/// The Shortcuts tab — a grid of one-tap launchers the user defines: run a macOS
/// Shortcut, fire a shell command, open a URL, or launch an app. Each tile runs its
/// action on tap; the set persists as JSON in `@AppStorage`. Panel-native so it
/// reads on every theme. Actions run against the user's own machine on explicit
/// tap — it's a personal launcher (Raycast/Alfred-style), not remote input.
struct ShortcutsTabView: View {
    @EnvironmentObject private var settings: SettingsStore

    @AppStorage("shortcuts.items") private var itemsJSON = "[]"
    @State private var isAdding = false
    @State private var runningID: UUID?

    // New-shortcut form fields.
    @State private var draftKind = ShortcutItem.Kind.command
    @State private var draftTitle = ""
    @State private var draftPayload = ""

    private let columns = [GridItem(.flexible(), spacing: Spacing.sm),
                           GridItem(.flexible(), spacing: Spacing.sm)]

    private var items: [ShortcutItem] {
        (try? JSONDecoder().decode([ShortcutItem].self, from: Data(itemsJSON.utf8))) ?? []
    }

    var body: some View {
        VStack(spacing: Spacing.base) {
            header
            if isAdding { addForm }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("SHORTCUTS")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.secondaryText)
                .kerning(0.6)
            Spacer(minLength: 0)
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { isAdding.toggle() }
            } label: {
                Image(systemName: isAdding ? "xmark" : "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                    .frame(width: 24, height: 24)
                    .background { Circle().fill(Theme.line(0.10)) }
            }
            .buttonStyle(.plain)
            .notchHover(scale: 1.08)
            .help("Add a shortcut")
        }
    }

    // MARK: Grid

    @ViewBuilder
    private var content: some View {
        let all = items
        if all.isEmpty && !isAdding {
            emptyState
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: columns, spacing: Spacing.sm) {
                    ForEach(all) { item in
                        tile(item)
                    }
                }
                .padding(.vertical, Spacing.hair)
                .padding(.horizontal, Spacing.hair)
            }
        }
    }

    private func tile(_ item: ShortcutItem) -> some View {
        Button { run(item) } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: runningID == item.id ? "circle.dotted" : item.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(settings.accent)
                    .frame(width: 32, height: 32)
                    .background { RoundedRectangle(cornerRadius: 9, style: .continuous).fill(settings.accent.opacity(0.14)) }
                    .symbolEffect(.pulse, isActive: runningID == item.id)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    Text(item.kind.label)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.sm)
            .frame(height: 52)
            .frame(maxWidth: .infinity, alignment: .leading)
            .innerCard(cornerRadius: 13)
        }
        .buttonStyle(.plain)
        .notchHover(scale: 1.03)
        .contextMenu {
            Button(role: .destructive) { remove(item) } label: {
                Label("Remove \(item.title)", systemImage: "minus.circle")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.s) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.tertiaryText)
            Text("No shortcuts yet")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
            Text("Tap + to add a launcher.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.tertiaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Add form

    private var addForm: some View {
        VStack(spacing: Spacing.sm) {
            HStack(spacing: Spacing.s) {
                ForEach(ShortcutItem.Kind.allCases) { kind in
                    kindChip(kind)
                }
            }
            HStack(spacing: Spacing.sm) {
                Image(systemName: draftKind.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 16)
                TextField("Name", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
                    .tint(settings.accent)
                    .frame(width: 120)
                Divider().frame(height: 16).overlay(Theme.line(0.15))
                TextField(draftKind.placeholder, text: $draftPayload)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .regular).monospaced())
                    .foregroundStyle(Theme.primaryText)
                    .tint(settings.accent)
                    .onSubmit(commit)
                Button("Add", action: commit)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(settings.accent.readableForeground)
                    .padding(.horizontal, Spacing.base)
                    .frame(height: 28)
                    .background { Capsule().fill(settings.accent) }
                    .notchHover(scale: 1.05)
                    .disabled(!canCommit)
                    .opacity(canCommit ? 1 : 0.5)
            }
        }
        .padding(Spacing.base)
        .innerCard(cornerRadius: 14)
    }

    private func kindChip(_ kind: ShortcutItem.Kind) -> some View {
        let on = draftKind == kind
        return Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { draftKind = kind }
        } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: kind.symbol).font(.system(size: 9, weight: .semibold))
                Text(kind.label).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(on ? settings.accent.readableForeground : Theme.secondaryText)
            .padding(.horizontal, Spacing.md)
            .frame(height: 24)
            .background { Capsule().fill(on ? settings.accent : Theme.line(0.08)) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .notchHover(scale: 1.04)
    }

    private var canCommit: Bool {
        !draftTitle.trimmingCharacters(in: .whitespaces).isEmpty
            && !draftPayload.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: Storage & actions

    private func setItems(_ list: [ShortcutItem]) {
        if let data = try? JSONEncoder().encode(list) {
            itemsJSON = String(decoding: data, as: UTF8.self)
        }
    }

    private func commit() {
        guard canCommit else { return }
        let item = ShortcutItem(kind: draftKind,
                                title: draftTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                                payload: draftPayload.trimmingCharacters(in: .whitespacesAndNewlines))
        setItems(items + [item])
        draftTitle = ""; draftPayload = ""
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { isAdding = false }
    }

    private func remove(_ item: ShortcutItem) {
        setItems(items.filter { $0.id != item.id })
    }

    /// Fire the launcher. URL/app go through `NSWorkspace`; Shortcut/command spawn a
    /// process. A brief pulse on the tile marks the in-flight run.
    private func run(_ item: ShortcutItem) {
        withAnimation(.easeOut(duration: 0.15)) { runningID = item.id }
        item.launch()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            if runningID == item.id { withAnimation { runningID = nil } }
        }
    }
}

/// One launcher: a titled action of a given `Kind` with a payload (a Shortcut name,
/// a shell command, a URL, or an app name).
struct ShortcutItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case shortcut, command, url, app
        var id: String { rawValue }

        var label: String {
            switch self {
            case .shortcut: return "Shortcut"
            case .command:  return "Command"
            case .url:      return "URL"
            case .app:      return "App"
            }
        }

        var symbol: String {
            switch self {
            case .shortcut: return "square.stack.3d.up.fill"
            case .command:  return "terminal.fill"
            case .url:      return "link"
            case .app:      return "app.fill"
            }
        }

        var placeholder: String {
            switch self {
            case .shortcut: return "Shortcut name (as in Shortcuts.app)"
            case .command:  return "Shell command, e.g. say hello"
            case .url:      return "https://…"
            case .app:      return "App name, e.g. Safari"
            }
        }

        /// A sensible default tile glyph for a new item of this kind.
        var defaultTileSymbol: String {
            switch self {
            case .shortcut: return "bolt.fill"
            case .command:  return "terminal.fill"
            case .url:      return "globe"
            case .app:      return "app.dashed"
            }
        }
    }

    var id = UUID()
    var kind: Kind
    var title: String
    var payload: String
    /// Optional custom tile glyph; falls back to the kind's default.
    var customSymbol: String?

    var symbol: String { customSymbol ?? kind.defaultTileSymbol }

    /// Execute the action. Runs on the user's machine on explicit tap.
    func launch() {
        switch kind {
        case .url:
            let raw = payload.hasPrefix("http") ? payload : "https://\(payload)"
            if let url = URL(string: raw) { NSWorkspace.shared.open(url) }
        case .app:
            Self.spawn("/usr/bin/open", ["-a", payload])
        case .shortcut:
            Self.spawn("/usr/bin/shortcuts", ["run", payload])
        case .command:
            Self.spawn("/bin/zsh", ["-lc", payload])
        }
    }

    /// Launch a detached process off the main thread; failures are swallowed (a bad
    /// command shouldn't take the panel down).
    private static func spawn(_ launchPath: String, _ arguments: [String]) {
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: launchPath)
            task.arguments = arguments
            try? task.run()
        }
    }
}
