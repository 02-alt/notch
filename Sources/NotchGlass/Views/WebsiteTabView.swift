import SwiftUI
import UniformTypeIdentifiers

/// A quick-access website shelf with folders. The top level shows folders and
/// loose sites; tapping a folder drills in to manage its sites. Everything opens
/// in the default browser and is persisted.
struct WebsiteTabView: View {
    @EnvironmentObject private var vm: NotchViewModel

    var body: some View {
        Group {
            if let id = vm.openFolderID,
               vm.websiteFolders.contains(where: { $0.id == id }) {
                FolderDetailView(folderID: id)
            } else {
                TopLevelView()
            }
        }
        .transition(.opacity)
    }
}

// MARK: - Top level

private struct TopLevelView: View {
    @EnvironmentObject private var vm: NotchViewModel
    @EnvironmentObject private var settings: SettingsStore
    @State private var isAdding = false
    @State private var newSite = ""
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(vm.websiteFolders) { folder in
                        FolderTile(folder: folder) {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                vm.openFolderID = folder.id
                            }
                        } delete: {
                            withAnimation { vm.deleteFolder(folder.id) }
                        } dropSite: { siteID in
                            withAnimation { vm.moveSite(id: siteID, toFolder: folder.id) }
                        }
                    }

                    ForEach(vm.websites) { site in
                        WebsiteTile(site: site, folders: vm.websiteFolders) {
                            open(site)
                        } remove: {
                            vm.removeSite(site.id, fromFolder: nil)
                        } move: { folderID in
                            withAnimation { vm.moveSite(site, toFolder: folderID) }
                        }
                    }

                    newFolderTile
                    addSiteTile
                }
                .padding(.horizontal, 2)
                .frame(maxHeight: .infinity)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(settings.accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .opacity(isDropTargeted ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .onDrop(of: [.url, .text], isTargeted: dropTarget) { providers in
                handleShelfDrop(providers)
            }

            if isAdding {
                AddSiteField(text: $newSite) {
                    vm.addSite(newSite, toFolder: nil)
                    newSite = ""
                    withAnimation { isAdding = false }
                }
            }
        }
    }

    private var newFolderTile: some View {
        tile(icon: "folder.badge.plus", label: "New Folder", tint: settings.accent) {
            let id = vm.addFolder()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { vm.openFolderID = id }
        }
    }

    private var addSiteTile: some View {
        tile(icon: isAdding ? "xmark" : "plus", label: "Add Site", tint: Theme.secondaryText) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { isAdding.toggle() }
        }
    }

    private func tile(icon: String, label: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .frame(width: 82, height: 96)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .innerCard()
        .notchHover()
    }

    private var dropTarget: Binding<Bool> {
        Binding(get: { isDropTargeted }, set: { t in
            isDropTargeted = t
            if t { vm.keepOpen() }
        })
    }

    /// Accepts a URL/link dropped from a browser and adds it as a loose site.
    private func handleShelfDrop(_ providers: [NSItemProvider]) -> Bool {
        loadDroppedURL(providers) { string in
            // Ignore our own tile drags (a bare UUID); those belong on folders.
            if UUID(uuidString: string) == nil { vm.addSite(string, toFolder: nil) }
        }
    }

    private func open(_ site: WebsiteItem) {
        guard let url = site.url else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Pulls a URL (or plain-text link) out of dropped providers and calls `add`.
@MainActor
private func loadDroppedURL(_ providers: [NSItemProvider], add: @escaping (String) -> Void) -> Bool {
    for provider in providers where provider.canLoadObject(ofClass: URL.self) {
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in add(url.absoluteString) }
        }
        return true
    }
    for provider in providers where provider.canLoadObject(ofClass: String.self) {
        _ = provider.loadObject(ofClass: String.self) { string, _ in
            guard let string, !string.isEmpty else { return }
            Task { @MainActor in add(string.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        return true
    }
    return false
}

// MARK: - Folder detail

private struct FolderDetailView: View {
    @EnvironmentObject private var vm: NotchViewModel
    @EnvironmentObject private var settings: SettingsStore
    let folderID: UUID
    @State private var isAdding = false
    @State private var newSite = ""
    @State private var isDropTargeted = false
    @FocusState private var nameFocused: Bool

    private var folder: WebsiteFolder? {
        vm.websiteFolders.first(where: { $0.id == folderID })
    }

    /// If this folder was opened via the tile's "Rename" menu, focus its name
    /// field so the user can type straight away, then consume the request.
    private func focusIfPendingRename() {
        guard vm.websiteFolderPendingRename == folderID else { return }
        nameFocused = true
        vm.websiteFolderPendingRename = nil
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        vm.openFolderID = nil
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.primaryText)
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .blackGlass(in: Capsule(), interactive: true)
                .linkCursor()

                Image(systemName: "folder.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)

                TextField("Folder name", text: vm.folderNameBinding(folderID))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .frame(maxWidth: 220, alignment: .leading)
                    .focused($nameFocused)

                Spacer()

                Button {
                    withAnimation { vm.deleteFolder(folderID) }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                        .frame(width: 26, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .blackGlass(in: Capsule(), interactive: true, tint: .red.opacity(0.5))
                .linkCursor()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(folder?.sites ?? []) { site in
                        WebsiteTile(site: site, folders: []) {
                            open(site)
                        } remove: {
                            vm.removeSite(site.id, fromFolder: folderID)
                        } move: { _ in }
                    }
                    addTile
                }
                .padding(.horizontal, 2)
                .frame(maxHeight: .infinity)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(settings.accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .opacity(isDropTargeted ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .onDrop(of: [.url, .text], isTargeted: Binding(
                get: { isDropTargeted },
                set: { t in isDropTargeted = t; if t { vm.keepOpen() } }
            )) { providers in
                loadDroppedURL(providers) { string in
                    if UUID(uuidString: string) == nil { vm.addSite(string, toFolder: folderID) }
                }
            }

            if isAdding {
                AddSiteField(text: $newSite) {
                    vm.addSite(newSite, toFolder: folderID)
                    newSite = ""
                    withAnimation { isAdding = false }
                }
            }
        }
        .onAppear { focusIfPendingRename() }
        .onChange(of: vm.websiteFolderPendingRename) { focusIfPendingRename() }
    }

    private var addTile: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { isAdding.toggle() }
        } label: {
            Image(systemName: isAdding ? "xmark" : "plus")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 82, height: 96)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .innerCard()
        .notchHover()
    }

    private func open(_ site: WebsiteItem) {
        guard let url = site.url else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Tiles

private struct FolderTile: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var vm: NotchViewModel
    let folder: WebsiteFolder
    let open: () -> Void
    let delete: () -> Void
    let dropSite: (UUID) -> Void
    @State private var isTargeted = false

    var body: some View {
        Button(action: open) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(settings.accent.opacity(isTargeted ? 0.4 : 0.18))
                    Image(systemName: isTargeted ? "folder.fill.badge.plus" : "folder.fill")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(settings.accent)
                }
                .frame(width: 44, height: 44)

                Text(folder.name)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .frame(width: 74)
            }
            .frame(width: 82, height: 96)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .innerCard()
        .notchHover()
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous)
                .strokeBorder(settings.accent, lineWidth: isTargeted ? 1.5 : 0)
        }
        .onDrop(of: [.text], isTargeted: $isTargeted) { providers in
            for provider in providers where provider.canLoadObject(ofClass: String.self) {
                _ = provider.loadObject(ofClass: String.self) { string, _ in
                    guard let string, let id = UUID(uuidString: string.trimmingCharacters(in: .whitespaces)) else { return }
                    Task { @MainActor in dropSite(id) }
                }
                return true
            }
            return false
        }
        .overlay(alignment: .topLeading) {
            if !folder.sites.isEmpty {
                Text("\(folder.sites.count)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(Color.black.opacity(0.5)))
                    .offset(x: 6, y: 6)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button(action: delete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white, Color.black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .notchHover(scale: 1.2, brighten: 0.15)
            .offset(x: 4, y: -4)
        }
        .glassContextMenu {
            [
                .item("Open", systemImage: "arrow.up.forward.square") { open() },
                .item("Rename", systemImage: "pencil") {
                    vm.websiteFolderPendingRename = folder.id
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        vm.openFolderID = folder.id
                    }
                },
                .item("Delete", systemImage: "trash", destructive: true) { delete() }
            ]
        }
    }
}

private struct WebsiteTile: View {
    let site: WebsiteItem
    let folders: [WebsiteFolder]
    let open: () -> Void
    let remove: () -> Void
    let move: (UUID) -> Void
    @State private var favicon: NSImage?

    var body: some View {
        Button(action: open) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.line(0.08))
                    if let favicon {
                        Image(nsImage: favicon)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 26, height: 26)
                    } else {
                        Text(String(site.host.prefix(1)).uppercased())
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Theme.primaryText)
                    }
                }
                .frame(width: 44, height: 44)

                Text(site.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .frame(width: 74)
            }
            .frame(width: 82, height: 96)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .innerCard()
        .notchHover()
        .onDrag {
            // Carries the site id so it can be dropped onto a folder to file it.
            NSItemProvider(object: site.id.uuidString as NSString)
        }
        .overlay(alignment: .topTrailing) {
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white, Color.black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .notchHover(scale: 1.2, brighten: 0.15)
            .offset(x: 4, y: -4)
        }
        .glassContextMenu {
            var items: [GlassMenuItem] = [
                .item("Open", systemImage: "arrow.up.forward.square") { open() }
            ]
            if !folders.isEmpty {
                items.append(.menu("Move to Folder", systemImage: "folder", folders.map { folder in
                    .item(folder.name) { move(folder.id) }
                }))
            }
            items.append(.item("Remove", systemImage: "trash", destructive: true) { remove() })
            return items
        }
        .task(id: site.faviconURL) {
            await loadFavicon()
        }
    }

    private func loadFavicon() async {
        guard let url = site.faviconURL else { return }
        if let (data, _) = try? await URLSession.shared.data(from: url),
           let image = NSImage(data: data) {
            favicon = image
        }
    }
}

// MARK: - Add field

private struct AddSiteField: View {
    @EnvironmentObject private var settings: SettingsStore
    @Binding var text: String
    let commit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .foregroundStyle(Theme.secondaryText)
            TextField("Add a website (e.g. apple.com)", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.primaryText)
                .onSubmit(commit)
            Button("Add", action: commit)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(settings.accent)
                .notchHover(scale: 1.08)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .innerCard(cornerRadius: 12)
    }
}
