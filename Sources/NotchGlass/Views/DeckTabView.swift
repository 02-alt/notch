import SwiftUI
import AppKit

/// A software Stream Deck inside the notch: a grid of programmable keys that
/// launch apps, open links/files, run Shortcuts, or fire shell commands. Keys are
/// stored in `DeckStore`; tapping the pencil flips the grid into edit mode where
/// keys can be reconfigured, deleted, or added.
struct DeckTabView: View {
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject private var store = DeckStore.shared

    @State private var editing = false
    /// The key currently open in the editor sheet, or nil when the editor is closed.
    @State private var editorTarget: DeckButton?

    private let columns = [GridItem(.adaptive(minimum: 84, maximum: 120), spacing: Spacing.md)]

    var body: some View {
        // Header lives *above* the editor overlay so opening "New Key" never
        // covers the Deck title / pencil — the editor only fills the content area.
        VStack(spacing: Spacing.md) {
            header
            ZStack {
                if store.buttons.isEmpty && !editing {
                    emptyState
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVGrid(columns: columns, spacing: Spacing.md) {
                            ForEach(store.buttons) { key in
                                DeckKey(key: key, editing: editing,
                                        accent: settings.accent,
                                        onTap: { editing ? edit(key) : key.run() },
                                        onDelete: { store.remove(key.id) })
                            }
                            if editing { addTile }
                        }
                        .padding(.bottom, Spacing.xs)
                    }
                }

                if let target = editorTarget {
                    DeckKeyEditor(
                        draft: target,
                        isNew: !store.buttons.contains(where: { $0.id == target.id }),
                        accent: settings.accent,
                        onSave: { saved in
                            if store.buttons.contains(where: { $0.id == saved.id }) {
                                store.update(saved)
                            } else {
                                store.add(saved)
                            }
                            editorTarget = nil
                        },
                        onCancel: { editorTarget = nil }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: editorTarget?.id)
        .animation(.easeInOut(duration: 0.18), value: editing)
    }

    private var header: some View {
        HStack {
            Text("Deck")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.primaryText)
            Spacer()
            if !store.buttons.isEmpty {
                Button {
                    editing.toggle()
                } label: {
                    Image(systemName: editing ? "checkmark" : "pencil")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.primaryText)
                        .frame(width: 30, height: 30)
                        .blackGlass(in: Circle(), interactive: true)
                }
                .buttonStyle(.plain)
                .notchHover()
            }
        }
    }

    private var addTile: some View {
        Button {
            editorTarget = DeckButton()
        } label: {
            VStack(spacing: Spacing.s) {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .medium))
                Text("Add")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Theme.primaryText.opacity(0.7))
            .frame(maxWidth: .infinity)
            .frame(height: 76)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.primaryText.opacity(0.25),
                                  style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .notchHover(scale: 1.03)
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "square.grid.3x3.fill")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.primaryText.opacity(0.35))
            Text("No keys yet")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.primaryText.opacity(0.8))
            Button {
                editorTarget = DeckButton()
            } label: {
                Text("Add a key")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                    .padding(.horizontal, Spacing.lg)
                    .frame(height: 32)
                    .blackGlass(in: Capsule(), interactive: true)
            }
            .buttonStyle(.plain)
            .notchHover()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func edit(_ key: DeckButton) { editorTarget = key }
}

/// A single key tile in the grid.
private struct DeckKey: View {
    let key: DeckButton
    let editing: Bool
    let accent: Color
    let onTap: () -> Void
    let onDelete: () -> Void

    @State private var jiggle = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: Spacing.s) {
                DeckIcon(key: key, size: 30)
                Text(key.label.isEmpty ? key.action.title : key.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.primaryText.opacity(0.85))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 76)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .innerCard(cornerRadius: 14)
        .notchHover(scale: 1.04)
        .overlay(alignment: .topTrailing) {
            if editing {
                Button(action: onDelete) {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white, Color(hex: "FF453A") ?? .red)
                        .background(Circle().fill(.black.opacity(0.5)))
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
            }
        }
        .rotationEffect(.degrees(editing && jiggle && !reduceMotion ? 1.2 : 0))
        .animation(editing && !reduceMotion ? .easeInOut(duration: 0.14).repeatForever(autoreverses: true) : .default,
                   value: jiggle)
        .onChange(of: editing) { _, on in jiggle = on }
        .onAppear { if editing { jiggle = true } }
    }
}

/// A key's icon as it appears everywhere (grid tile + editor preview): the real
/// app icon for an app key, the site favicon for a URL key, the Finder icon for a
/// file key — or an SF Symbol when the user has picked a custom glyph or there's no
/// natural icon (Shortcut / Command). One source of truth so the preview always
/// matches the tile.
struct DeckIcon: View {
    let key: DeckButton
    var size: CGFloat = 30

    var body: some View {
        if !key.hasCustomSymbol, let fileURL = key.resolvedFileURL {
            Image(nsImage: NSWorkspace.shared.icon(forFile: fileURL.path))
                .resizable().interpolation(.high)
                .frame(width: size, height: size)
        } else if !key.hasCustomSymbol, let favicon = key.faviconURL {
            AsyncImage(url: favicon) { phase in
                if let image = phase.image {
                    image.resizable().interpolation(.high)
                        .frame(width: size, height: size)
                } else {
                    symbol("globe")
                }
            }
        } else {
            symbol(key.symbol.isEmpty ? key.action.defaultSymbol : key.symbol)
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: size * 0.66, weight: .medium))
            .foregroundStyle(Theme.primaryText)
            .frame(width: size, height: size)
    }
}

/// The inline editor overlay for creating/reconfiguring a key. Reworked to be
/// visual-first: you pick an action from icon chips, choose the target (an app,
/// file, URL, shortcut or command) through the control that fits it, and the icon
/// is derived automatically — no raw SF Symbol names or file paths to type. A live
/// preview shows exactly how the key will look before you save.
private struct DeckKeyEditor: View {
    @State var draft: DeckButton
    let isNew: Bool
    let accent: Color
    let onSave: (DeckButton) -> Void
    let onCancel: () -> Void

    /// Installed macOS Shortcuts, loaded lazily when the Shortcut action is picked,
    /// so the user can choose from a menu instead of remembering an exact name.
    @State private var installedShortcuts: [String] = []
    @State private var pickingSymbol = false
    @FocusState private var labelFocused: Bool

    private var canSave: Bool { !draft.payload.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            header
            actionChips
            destinationSection
            appearanceRow
            Spacer(minLength: 0)
            saveButton
        }
        .foregroundStyle(Theme.primaryText)
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(0.55))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text(isNew ? "New Key" : "Edit Key")
                .font(.system(size: 13, weight: .bold))
            Spacer()
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 26, height: 26)
                    .blackGlass(in: Circle(), interactive: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close editor")
        }
    }

    // MARK: Action chips

    private var actionChips: some View {
        HStack(spacing: Spacing.sm) {
            ForEach(DeckButton.Action.allCases) { action in
                actionChip(action)
            }
        }
    }

    private func actionChip(_ action: DeckButton.Action) -> some View {
        let on = draft.action == action
        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                draft.action = action
                // Prefer a natural icon for the new action: clear an auto glyph so
                // the app icon / favicon shows; keep a genuinely custom one.
                if !draft.hasCustomSymbol { draft.symbol = "" }
            }
            if action == .shortcut { loadShortcuts() }
        } label: {
            VStack(spacing: Spacing.xs) {
                Image(systemName: action.defaultSymbol)
                    .font(.system(size: 16, weight: .semibold))
                Text(Self.shortLabel(action))
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(on ? accent.readableForeground : Theme.secondaryText)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(on ? accent : Theme.line(0.08))
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .notchHover(scale: 1.04)
        .accessibilityLabel(action.title)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    // MARK: Destination (adapts per action)

    @ViewBuilder
    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(Self.destinationCaption(draft.action))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.tertiaryText)
                .kerning(0.6)
                .accessibilityHidden(true)

            switch draft.action {
            case .app, .file:
                chooseRow
            case .url:
                textRow(prompt: draft.action.payloadPrompt, mono: false,
                        label: "Website address", icon: "globe")
            case .shortcut:
                shortcutRow
            case .shell:
                textRow(prompt: draft.action.payloadPrompt, mono: true,
                        label: "Command to run", icon: "terminal.fill")
            }
        }
    }

    /// App / File: a big "Choose…" control that shows the picked item's real icon
    /// and name instead of a raw path.
    private var chooseRow: some View {
        Button { choose() } label: {
            HStack(spacing: Spacing.sm) {
                if draft.resolvedFileURL != nil {
                    DeckIcon(key: draft, size: 26)
                    Text(draft.payloadDisplayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                } else {
                    Image(systemName: draft.action == .app ? "app.dashed" : "doc.badge.plus")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                    Text(draft.action == .app ? "Choose an app…" : "Choose a file…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer(minLength: 0)
                Text(draft.resolvedFileURL == nil ? "Browse" : "Change")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(accent)
            }
            .padding(.horizontal, Spacing.md)
            .frame(height: 40)
            .frame(maxWidth: .infinity)
            .innerCard(cornerRadius: 10)
        }
        .buttonStyle(.plain)
        .notchHover(scale: 1.01)
        .accessibilityLabel(draft.action == .app ? "Choose an app" : "Choose a file")
    }

    /// Shortcut: type the name, with a menu of installed shortcuts to fill it.
    private var shortcutRow: some View {
        HStack(spacing: Spacing.sm) {
            payloadField(prompt: draft.action.payloadPrompt, mono: false, icon: "bolt.fill")
                .accessibilityLabel("Shortcut name")
            if !installedShortcuts.isEmpty {
                Menu {
                    ForEach(installedShortcuts, id: \.self) { name in
                        Button(name) {
                            draft.payload = name
                            if draft.label.isEmpty { draft.label = name }
                        }
                    }
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 34, height: 40)
                        .innerCard(cornerRadius: 10)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Pick from installed shortcuts")
            }
        }
    }

    private func textRow(prompt: String, mono: Bool, label: String, icon: String) -> some View {
        payloadField(prompt: prompt, mono: mono, icon: icon)
            .accessibilityLabel(label)
    }

    /// A labelled payload text field with a leading action glyph.
    private func payloadField(prompt: String, mono: Bool, icon: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 16)
            TextField("", text: $draft.payload,
                      prompt: Text(prompt).foregroundStyle(Theme.primaryText.opacity(0.4)))
                .textFieldStyle(.plain)
                .font(mono ? .system(size: 12).monospaced() : .system(size: 13))
                .foregroundStyle(Theme.primaryText)
                .tint(accent)
        }
        .padding(.horizontal, Spacing.md)
        .frame(height: 40)
        .frame(maxWidth: .infinity)
        .innerCard(cornerRadius: 10)
    }

    // MARK: Appearance (name + optional icon override)

    private var appearanceRow: some View {
        HStack(spacing: Spacing.sm) {
            // Live preview of the exact key icon.
            DeckIcon(key: draft, size: 26)
                .frame(width: 40, height: 40)
                .innerCard(cornerRadius: 10)
                .accessibilityHidden(true)

            HStack(spacing: Spacing.sm) {
                TextField("", text: $draft.label,
                          prompt: Text("Name").foregroundStyle(Theme.primaryText.opacity(0.4)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
                    .tint(accent)
                    .focused($labelFocused)
                    .accessibilityLabel("Key name")
            }
            .padding(.horizontal, Spacing.md)
            .frame(height: 40)
            .frame(maxWidth: .infinity)
            .innerCard(cornerRadius: 10)

            // Icon override only where there's no natural icon to fall back on.
            if draft.action == .shortcut || draft.action == .shell {
                symbolPickerButton
            }
        }
    }

    private var symbolPickerButton: some View {
        Button { pickingSymbol = true } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: draft.symbol.isEmpty ? draft.action.defaultSymbol : draft.symbol)
                    .font(.system(size: 13, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .foregroundStyle(Theme.primaryText)
            .frame(width: 52, height: 40)
            .innerCard(cornerRadius: 10)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Choose icon")
        .popover(isPresented: $pickingSymbol, arrowEdge: .bottom) {
            SymbolGrid(selected: draft.symbol.isEmpty ? draft.action.defaultSymbol : draft.symbol,
                       accent: accent) { picked in
                draft.symbol = picked
                pickingSymbol = false
            }
            .padding(Spacing.base)
            .frame(width: 240)
        }
    }

    // MARK: Save

    private var saveButton: some View {
        Button { commit() } label: {
            Text(isNew ? "Add Key" : "Save")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.primaryText)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .blackGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous), interactive: true)
        }
        .buttonStyle(.plain)
        .notchHover()
        .disabled(!canSave)
        .opacity(canSave ? 1 : 0.5)
    }

    // MARK: Actions

    private func commit() {
        guard canSave else { return }
        if draft.label.trimmingCharacters(in: .whitespaces).isEmpty {
            draft.label = draft.payloadDisplayName
        }
        onSave(draft)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = draft.action == .file
        panel.canChooseFiles = true
        if draft.action == .app {
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.allowedContentTypes = [.application]
            panel.prompt = "Choose App"
        } else {
            panel.prompt = "Choose File"
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.payload = url.path
        // A chosen app/file has a real icon, so drop any leftover custom glyph.
        draft.symbol = ""
        if draft.label.isEmpty {
            draft.label = url.deletingPathExtension().lastPathComponent
        }
    }

    /// Load the user's installed Shortcuts via the `shortcuts list` CLI, off the
    /// main thread. Best-effort: on any failure the menu just doesn't appear and
    /// the text field still works.
    private func loadShortcuts() {
        guard installedShortcuts.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            task.arguments = ["list"]
            let pipe = Pipe()
            task.standardOutput = pipe
            guard (try? task.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let names = String(decoding: data, as: UTF8.self)
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            DispatchQueue.main.async { installedShortcuts = Array(names.prefix(200)) }
        }
    }

    // MARK: Labels

    /// Short chip labels — the full names ("Open App", "Run Command") are the
    /// accessibility labels; the chips show the compact form.
    static func shortLabel(_ action: DeckButton.Action) -> String {
        switch action {
        case .app:      return "App"
        case .url:      return "URL"
        case .file:     return "File"
        case .shortcut: return "Shortcut"
        case .shell:    return "Command"
        }
    }

    static func destinationCaption(_ action: DeckButton.Action) -> String {
        switch action {
        case .app:      return "APPLICATION"
        case .file:     return "FILE OR FOLDER"
        case .url:      return "WEBSITE"
        case .shortcut: return "SHORTCUT"
        case .shell:    return "COMMAND"
        }
    }
}

/// A compact grid of curated SF Symbols for the icon override — pick visually
/// rather than typing a symbol name.
private struct SymbolGrid: View {
    let selected: String
    let accent: Color
    let onPick: (String) -> Void

    private static let symbols = [
        "bolt.fill", "terminal.fill", "star.fill", "heart.fill", "flag.fill",
        "bell.fill", "folder.fill", "doc.fill", "link", "globe",
        "gearshape.fill", "hammer.fill", "wrench.and.screwdriver.fill", "paintbrush.fill", "wand.and.stars",
        "play.fill", "music.note", "camera.fill", "video.fill", "mic.fill",
        "envelope.fill", "message.fill", "phone.fill", "calendar", "clock.fill",
        "moon.fill", "sun.max.fill", "cloud.fill", "leaf.fill", "flame.fill",
        "cart.fill", "creditcard.fill", "lock.fill", "key.fill", "power",
    ]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: Spacing.s), count: 6)

    var body: some View {
        LazyVGrid(columns: columns, spacing: Spacing.s) {
            ForEach(Self.symbols, id: \.self) { name in
                Button { onPick(name) } label: {
                    Image(systemName: name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(name == selected ? accent.readableForeground : Theme.primaryText)
                        .frame(width: 30, height: 30)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(name == selected ? accent : Theme.line(0.08))
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(name)
            }
        }
    }
}
