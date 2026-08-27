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
                Image(systemName: key.symbol.isEmpty ? key.action.defaultSymbol : key.symbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
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

/// The inline editor overlay for creating/reconfiguring a key.
private struct DeckKeyEditor: View {
    @State var draft: DeckButton
    let isNew: Bool
    let accent: Color
    let onSave: (DeckButton) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
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
            }

            Picker("", selection: $draft.action) {
                ForEach(DeckButton.Action.allCases) { a in
                    Text(a.title).tag(a)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: draft.action) { _, a in
                if draft.symbol.isEmpty || DeckButton.Action.allCases.contains(where: { $0.defaultSymbol == draft.symbol }) {
                    draft.symbol = a.defaultSymbol
                }
            }

            field("Label", text: $draft.label, prompt: "My Key")

            HStack(spacing: Spacing.sm) {
                Image(systemName: draft.symbol.isEmpty ? draft.action.defaultSymbol : draft.symbol)
                    .font(.system(size: 15))
                    .frame(width: 30, height: 30)
                    .blackGlass(in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                editField(text: $draft.symbol, prompt: "SF Symbol name")
            }

            HStack(spacing: Spacing.sm) {
                editField(text: $draft.payload, prompt: draft.action.payloadPrompt)
                if draft.action == .app || draft.action == .file {
                    Button("Choose…") { choose() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent)
                }
            }

            Spacer(minLength: 0)

            Button {
                onSave(draft)
            } label: {
                Text(isNew ? "Add Key" : "Save")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .blackGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous), interactive: true)
            }
            .buttonStyle(.plain)
            .notchHover()
            .disabled(draft.payload.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(draft.payload.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
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

    private func field(_ title: String, text: Binding<String>, prompt: String) -> some View {
        editField(text: text, prompt: prompt)
    }

    private func editField(text: Binding<String>, prompt: String) -> some View {
        TextField("", text: text, prompt: Text(prompt).foregroundStyle(Theme.primaryText.opacity(0.4)))
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(Theme.primaryText)
            .padding(.horizontal, Spacing.md)
            .frame(height: 30)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.primaryText.opacity(0.08))
            }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = draft.action == .file
        panel.canChooseFiles = true
        if draft.action == .app {
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.allowedContentTypes = [.application]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.payload = url.path
        if draft.label.isEmpty {
            draft.label = url.deletingPathExtension().lastPathComponent
        }
    }
}
