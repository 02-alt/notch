import SwiftUI
import AppKit

/// The Obsidian tab — a window onto your local Obsidian vault, entirely file-based:
/// it reads and writes the vault's plain-Markdown files directly, so anything you do
/// here shows up in Obsidian (and vice-versa) with no plugin or server. Quick-capture
/// appends to today's daily note; the list browses/searches every note; tapping one
/// previews it, and "Open" jumps straight into the Obsidian app via its URL scheme.
///
/// Panel-native (``Theme`` + `settings.accent`) so it reads on every theme. The app
/// isn't sandboxed (it already uses Full Disk Access for Messages), so a folder the
/// user picks with the open panel is readable across launches from its stored path.
struct ObsidianTabView: View {
    @EnvironmentObject private var settings: SettingsStore

    /// The chosen vault's absolute path. Empty until the user picks one.
    @AppStorage("obsidian.vaultPath") private var vaultPath = ""

    @StateObject private var vault = ObsidianVault()

    @State private var query = ""
    @State private var capture = ""
    /// The note being previewed, or nil while showing the list.
    @State private var preview: ObsidianNote?
    @State private var previewBody = ""

    var body: some View {
        VStack(spacing: Spacing.base) {
            header
            if vaultPath.isEmpty {
                chooser
            } else if let preview {
                previewPane(preview)
            } else {
                captureBar
                searchBar
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { vault.point(at: vaultPath); vault.refresh() }
        .onChange(of: vaultPath) { _, new in vault.point(at: new); vault.refresh() }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("OBSIDIAN")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.secondaryText)
                .kerning(0.6)
            if !vault.name.isEmpty {
                Text(vault.name)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if preview != nil {
                iconButton("chevron.left", help: "Back to notes") {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { preview = nil }
                }
            } else if !vaultPath.isEmpty {
                iconButton("arrow.clockwise", help: "Refresh") { vault.refresh() }
                iconButton("folder", help: "Change vault") { pickVault() }
            }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.primaryText)
                .frame(width: 24, height: 24)
                .background { Circle().fill(Theme.line(0.10)) }
        }
        .buttonStyle(.plain)
        .notchHover(scale: 1.08)
        .help(help)
    }

    // MARK: No-vault state

    private var chooser: some View {
        VStack(spacing: Spacing.base) {
            Spacer(minLength: 0)
            Image(systemName: "circle.hexagongrid.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
            Text("Connect your vault")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.primaryText)
            Text("Pick your Obsidian vault folder to browse, search and capture notes right from the notch.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Spacing.xl)
            Button(action: pickVault) {
                Text("Choose vault folder…")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.sm)
                    .background { Capsule().fill(settings.accent) }
            }
            .buttonStyle(.plain)
            .notchHover(scale: 1.05)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Quick capture

    private var captureBar: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
            TextField("Capture to today's daily note…", text: $capture)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.primaryText)
                .onSubmit(commitCapture)
            if !capture.isEmpty {
                Button(action: commitCapture) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(settings.accent)
                }
                .buttonStyle(.plain)
                .notchHover(scale: 1.1)
                .help("Add to today's daily note")
            }
        }
        .padding(.horizontal, Spacing.base)
        .frame(height: 40)
        .innerCard(cornerRadius: 12)
    }

    private func commitCapture() {
        let text = capture.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        vault.capture(text)
        capture = ""
    }

    // MARK: Search

    private var searchBar: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
            TextField("Search notes", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.primaryText)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.tertiaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Spacing.base)
        .frame(height: 34)
        .innerCard(cornerRadius: 10)
    }

    // MARK: Note list

    private var filtered: [ObsidianNote] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return vault.notes }
        return vault.notes.filter { $0.name.lowercased().contains(q) }
    }

    private var list: some View {
        Group {
            if vault.notes.isEmpty {
                VStack(spacing: Spacing.sm) {
                    Spacer(minLength: 0)
                    Text(vault.loadFailed ? "Couldn't read that folder." : "No notes found.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: Spacing.xs) {
                        ForEach(filtered) { note in row(note) }
                    }
                    .padding(.vertical, Spacing.hair)
                }
            }
        }
    }

    private func row(_ note: ObsidianNote) -> some View {
        Button {
            openPreview(note)
        } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "doc.text")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(settings.accent)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(note.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    Text(note.modifiedString)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: Spacing.sm)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .padding(.horizontal, Spacing.base)
            .frame(height: 44)
            .innerCard(cornerRadius: 12)
        }
        .buttonStyle(.plain)
        .notchHover(scale: 1.01)
        .contextMenu {
            Button("Open in Obsidian") { vault.open(note) }
        }
    }

    private func openPreview(_ note: ObsidianNote) {
        previewBody = ""
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { preview = note }
        Task {
            let body = await vault.read(note)
            if preview?.id == note.id { previewBody = body }
        }
    }

    // MARK: Preview

    private func previewPane(_ note: ObsidianNote) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Text(note.name)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: Spacing.sm)
                Button { vault.open(note) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.forward.app.fill").font(.system(size: 10, weight: .bold))
                        Text("Open").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.xs)
                    .background { Capsule().fill(settings.accent) }
                }
                .buttonStyle(.plain)
                .notchHover(scale: 1.05)
                .help("Open in Obsidian")
            }
            ScrollView(.vertical, showsIndicators: false) {
                Text(previewBody.isEmpty ? "…" : previewBody)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.base)
            }
            .innerCard(cornerRadius: 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Vault picker

    private func pickVault() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Vault"
        panel.message = "Select your Obsidian vault folder."
        if panel.runModal() == .OK, let url = panel.url {
            vaultPath = url.path
        }
    }
}

/// One Markdown note in the vault. `id` is its absolute path, so a note keeps its
/// identity across refreshes and previews.
struct ObsidianNote: Identifiable, Sendable, Equatable {
    let path: String
    let name: String       // filename without the .md extension
    let modified: Date

    var id: String { path }

    var modifiedString: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: modified, relativeTo: Date())
    }
}

/// Reads and writes an Obsidian vault as plain files. All scanning and file I/O runs
/// off the main actor; only the published results land back on it.
@MainActor
final class ObsidianVault: ObservableObject {
    @Published private(set) var notes: [ObsidianNote] = []
    @Published private(set) var name = ""
    @Published private(set) var loadFailed = false

    private var root: URL?

    /// Point the vault at a folder path (empty clears it).
    func point(at path: String) {
        guard !path.isEmpty else { root = nil; name = ""; notes = []; return }
        let url = URL(fileURLWithPath: path)
        root = url
        name = url.lastPathComponent
    }

    /// Rescan the vault for Markdown notes, newest first. Capped so a huge vault can't
    /// stall the panel; the search field narrows within the loaded set.
    func refresh() {
        guard let root else { return }
        Task.detached(priority: .userInitiated) {
            let (found, failed) = Self.scan(root)
            await MainActor.run {
                self.notes = found
                self.loadFailed = failed
            }
        }
    }

    private nonisolated static func scan(_ root: URL) -> ([ObsidianNote], Bool) {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root,
                                    includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                    options: [.skipsHiddenFiles]) else {
            return ([], true)
        }
        var out: [ObsidianNote] = []
        for case let url as URL in e {
            // Skip Obsidian's own config/trash trees.
            if url.pathComponents.contains(where: { $0 == ".obsidian" || $0 == ".trash" }) { continue }
            guard url.pathExtension.lowercased() == "md" else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            out.append(ObsidianNote(path: url.path,
                                    name: url.deletingPathExtension().lastPathComponent,
                                    modified: values?.contentModificationDate ?? .distantPast))
            if out.count >= 2000 { break }
        }
        out.sort { $0.modified > $1.modified }
        return (out, false)
    }

    /// Read a note's Markdown body.
    func read(_ note: ObsidianNote) async -> String {
        await Task.detached(priority: .userInitiated) {
            (try? String(contentsOfFile: note.path, encoding: .utf8)) ?? ""
        }.value
    }

    /// Append a line to today's daily note (`YYYY-MM-DD.md` at the vault root),
    /// creating it — with a dated H1 — when it doesn't exist yet. Mirrors Obsidian's
    /// default daily-note filename so the capture lands where you'd expect.
    func capture(_ text: String) {
        guard let root else { return }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let tf = DateFormatter(); tf.dateFormat = "HH:mm"
        let now = Date()
        let fileURL = root.appendingPathComponent("\(df.string(from: now)).md")
        let line = "- \(tf.string(from: now)) \(text)\n"

        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            if fm.fileExists(atPath: fileURL.path) {
                if let handle = try? FileHandle(forWritingTo: fileURL) {
                    handle.seekToEndOfFile()
                    handle.write(Data(line.utf8))
                    try? handle.close()
                }
            } else {
                let header = "# \(df.string(from: now))\n\n"
                try? (header + line).write(to: fileURL, atomically: true, encoding: .utf8)
            }
            await self.refresh()
        }
    }

    /// Open a note in the Obsidian app via its URL scheme (`obsidian://open?path=…`).
    func open(_ note: ObsidianNote) {
        var comps = URLComponents()
        comps.scheme = "obsidian"
        comps.host = "open"
        comps.queryItems = [URLQueryItem(name: "path", value: note.path)]
        if let url = comps.url { NSWorkspace.shared.open(url) }
    }
}
