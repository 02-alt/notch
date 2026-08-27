import SwiftUI
import UniformTypeIdentifiers

/// Multiple notes, grouped into leather "books". The top level shows books and
/// loose notes as cards; tapping a note focuses it into a full editor (where you
/// can also attach photos), and tapping a book drills into the notes it holds.
struct NoteTabView: View {
    @EnvironmentObject private var vm: NotchViewModel

    var body: some View {
        Group {
            if let id = vm.focusedNoteID,
               let note = vm.notes.first(where: { $0.id == id }) {
                if let secondID = vm.secondaryNoteID,
                   let second = vm.notes.first(where: { $0.id == secondID }) {
                    HStack(spacing: Spacing.sm) {
                        NoteEditor(note: note)
                        NoteEditor(note: second, isSecondary: true)
                    }
                } else {
                    NoteEditor(note: note)
                }
            } else if let id = vm.openNoteFolderID,
                      vm.noteFolders.contains(where: { $0.id == id }) {
                BookDetail(folderID: id)
            } else {
                NoteHome()
            }
        }
        .transition(.opacity)
    }
}

// MARK: - Home (folders + loose notes)

private struct NoteHome: View {
    @EnvironmentObject private var vm: NotchViewModel
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.md) {
                ForEach(vm.noteFolders) { folder in
                    NoteFolderTile(folder: folder,
                                   count: vm.notes(inFolder: folder.id).count) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            vm.openNoteFolderID = folder.id
                        }
                    } delete: {
                        withAnimation { vm.deleteNoteFolder(folder.id) }
                    } dropNote: { noteID in
                        withAnimation { vm.moveNote(noteID, toFolder: folder.id) }
                    }
                }

                ForEach(vm.notes(inFolder: nil)) { note in
                    NoteCard(note: note) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            vm.focusedNoteID = note.id
                        }
                    } delete: {
                        withAnimation { vm.deleteNote(note) }
                    }
                }

                addNoteTile
                newFolderTile
            }
            .padding(.horizontal, Spacing.hair)
            .frame(maxHeight: .infinity)
        }
    }

    private var addNoteTile: some View {
        AddTile(icon: "plus", label: "New Note", tint: settings.accent) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { vm.addNote() }
        }
    }

    private var newFolderTile: some View {
        Button {
            let id = vm.addNoteFolder()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { vm.openNoteFolderID = id }
        } label: {
            VStack(spacing: Spacing.sm) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(settings.accent)
                Text("New Folder")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
            .frame(width: 92, height: 118)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .innerCard()
        .notchHover()
    }
}

// MARK: - Book detail (notes inside a book)

private struct BookDetail: View {
    @EnvironmentObject private var vm: NotchViewModel
    let folderID: UUID
    @FocusState private var nameFocused: Bool

    private var folder: NoteFolder? {
        vm.noteFolders.first(where: { $0.id == folderID })
    }

    /// If this book was opened via the tile's "Rename" menu, focus its name field
    /// so the user can type straight away, then consume the request.
    private func focusIfPendingRename() {
        guard vm.bookPendingRename == folderID else { return }
        nameFocused = true
        vm.bookPendingRename = nil
    }

    var body: some View {
        VStack(spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        vm.openNoteFolderID = nil
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
                    .foregroundStyle(Color(red: 0.72, green: 0.52, blue: 0.34))

                TextField("Folder name", text: vm.noteFolderNameBinding(folderID))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .frame(maxWidth: 220, alignment: .leading)
                    .focused($nameFocused)

                Spacer()

                Button {
                    withAnimation { vm.deleteNoteFolder(folderID) }
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
                HStack(spacing: Spacing.md) {
                    ForEach(vm.notes(inFolder: folderID)) { note in
                        NoteCard(note: note, currentFolder: folderID) {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                vm.focusedNoteID = note.id
                            }
                        } delete: {
                            withAnimation { vm.deleteNote(note) }
                        }
                    }

                    AddTile(icon: "plus", label: "New Note", tint: Theme.secondaryText) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            vm.addNote(inFolder: folderID)
                        }
                    }
                }
                .padding(.horizontal, Spacing.hair)
                .frame(maxHeight: .infinity)
            }
        }
        .onAppear { focusIfPendingRename() }
        .onChange(of: vm.bookPendingRename) { focusIfPendingRename() }
    }
}

// MARK: - Tiles

/// A plain folder on the note board (styled like the Websites tab): opens on tap,
/// accepts dropped notes to file them, and carries a count badge + delete.
private struct NoteFolderTile: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var vm: NotchViewModel
    let folder: NoteFolder
    let count: Int
    let open: () -> Void
    let delete: () -> Void
    let dropNote: (UUID) -> Void
    @State private var isTargeted = false

    var body: some View {
        Button(action: open) {
            VStack(spacing: Spacing.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(settings.accent.opacity(isTargeted ? 0.4 : 0.18))
                    Image(systemName: isTargeted ? "folder.fill.badge.plus" : "folder.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(settings.accent)
                }
                .frame(width: 52, height: 52)

                Text(folder.name)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .frame(width: 84)
            }
            .frame(width: 92, height: 118)
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
                    guard let string,
                          let id = UUID(uuidString: string.trimmingCharacters(in: .whitespaces))
                    else { return }
                    Task { @MainActor in dropNote(id) }
                }
                return true
            }
            return false
        }
        .overlay(alignment: .topLeading) {
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Spacing.s).padding(.vertical, Spacing.hair)
                    .background(Capsule().fill(Color.black.opacity(0.5)))
                    .offset(x: 6, y: 6)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button(action: delete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
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
                    vm.bookPendingRename = folder.id
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        vm.openNoteFolderID = folder.id
                    }
                },
                .item("Delete", systemImage: "trash", destructive: true) { delete() }
            ]
        }
    }
}

/// A note card. Shows the first photo as a header when the note has images (so
/// it reads like a photo card), and can be dragged onto a folder to file it.
private struct NoteCard: View {
    @EnvironmentObject private var vm: NotchViewModel
    let note: NoteItem
    var currentFolder: UUID? = nil
    let open: () -> Void
    let delete: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                if let first = note.images.first {
                    NoteThumb(image: first)
                        .frame(width: 118, height: 52)
                        .clipped()
                        .overlay(alignment: .topTrailing) { photoBadge }
                }
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(note.title)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(note.images.isEmpty ? 2 : 1)
                    Text(note.preview.isEmpty ? "No additional text" : note.preview)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(note.images.isEmpty ? 3 : 2)
                    Spacer(minLength: 0)
                }
                .padding(Spacing.md)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(width: 118, height: 118, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .innerCard()
        .notchHover()
        .onDrag { NSItemProvider(object: note.id.uuidString as NSString) }
        .overlay(alignment: .topTrailing) {
            Button(action: delete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
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
            let books = vm.noteFolders.filter { $0.id != currentFolder }
            if !books.isEmpty {
                items.append(.menu("Move to Folder", systemImage: "folder", books.map { book in
                    .item(book.name) { withAnimation { vm.moveNote(note.id, toFolder: book.id) } }
                }))
            }
            if currentFolder != nil {
                items.append(.item("Remove from Folder", systemImage: "tray.and.arrow.up") {
                    withAnimation { vm.moveNote(note.id, toFolder: nil) }
                })
            }
            items.append(.item("Delete", systemImage: "trash", destructive: true) { delete() })
            return items
        }
    }

    private var photoBadge: some View {
        Group {
            if note.images.count > 1 {
                HStack(spacing: Spacing.hair) {
                    Image(systemName: "photo.on.rectangle")
                    Text("\(note.images.count)")
                }
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, Spacing.s).padding(.vertical, Spacing.hair)
                .background(Capsule().fill(Color.black.opacity(0.55)))
                .padding(Spacing.s)
            }
        }
    }
}

/// A generic "add" card matching the note-card footprint.
private struct AddTile: View {
    let icon: String
    let label: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Spacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
            .frame(width: 92, height: 118)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .blackGlass(in: RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous),
                    interactive: true, tint: tint.opacity(0.4))
        .linkCursor()
    }
}

// MARK: - Thumbnails

/// Loads and shows a note photo, scaled to fill its frame.
private struct NoteThumb: View {
    let image: NoteImage
    @State private var loaded: NSImage?

    var body: some View {
        ZStack {
            if let loaded {
                Image(nsImage: loaded)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(Theme.line(0.06))
            }
        }
        .task(id: image.id) {
            loaded = NoteImageStore.load(image)
        }
    }
}

// MARK: - Full editor

private struct NoteEditor: View {
    @EnvironmentObject private var vm: NotchViewModel
    @EnvironmentObject private var settings: SettingsStore
    let note: NoteItem
    /// True for the side-by-side second note, so its toolbar shows a "close the
    /// second note" button instead of the back/expand chrome and drops the
    /// "open a 2nd note" footer.
    var isSecondary: Bool = false
    @StateObject private var editorController = NoteEditorController()
    /// The photos of the image pile the user tapped, shown in a scrollable grid
    /// over a blurred backdrop. Empty when no gallery is open. Scoped to just the
    /// clicked pile — not every photo in the note.
    @State private var galleryImages: [NoteImage] = []

    private var hasChecklist: Bool { !vm.checklist(for: note.id).isEmpty }

    var body: some View {
        ZStack {
            content
            if !galleryImages.isEmpty {
                CoverFlowGallery(images: galleryImages) {
                    withAnimation(.easeOut(duration: 0.18)) { galleryImages = [] }
                }
                .transition(.opacity)
            }
        }
    }

    private var content: some View {
        VStack(spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        if isSecondary { vm.closeSecondNote() } else { vm.closeNoteEditor() }
                    }
                } label: {
                    Image(systemName: isSecondary ? "xmark" : "chevron.left")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.primaryText)
                        .frame(width: 26, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .blackGlass(in: Capsule(), interactive: true)
                .linkCursor()
                .help(isSecondary ? "Close second note" : "Back")

                // Editable title — type to rename the note; leave it blank to fall
                // back to the note's first line (shown as the placeholder).
                TextField(note.title, text: vm.noteTitleBinding(note.id))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !isSecondary {
                    Button {
                        withAnimation(Metrics.openSpring) { vm.noteExpanded.toggle() }
                    } label: {
                        Image(systemName: vm.noteExpanded
                              ? "arrow.down.right.and.arrow.up.left"
                              : "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.primaryText)
                            .frame(width: 28, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .blackGlass(in: Capsule(), interactive: true,
                                tint: vm.noteExpanded ? settings.accent.opacity(0.6) : nil)
                    .linkCursor()
                    .help(vm.noteExpanded ? "Shrink" : "Bigger screen")
                }

                Button(action: pickImages) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .blackGlass(in: Capsule(), interactive: true)
                .linkCursor()

                Button {
                    withAnimation { vm.deleteNote(note) }
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

            editor

            // The checklist only appears once you start one (type "/list " or use
            // the editor's right-click "Add list").
            if hasChecklist {
                ChecklistSection(noteID: note.id, expanded: vm.noteExpanded)
            }

            // The former "Add checklist" bar is now the way to open a note beside
            // this one. Hidden on the second note itself and while one's already open.
            if !isSecondary && vm.secondaryNoteID == nil {
                openSecondNoteButton
            }
        }
    }

    private var openSecondNoteButton: some View {
        Button {
            withAnimation(Metrics.openSpring) { vm.openSecondNote() }
        } label: {
            HStack(spacing: Spacing.s) {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 12, weight: .semibold))
                Text("Open a 2nd note")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(settings.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .innerCard(cornerRadius: 12)
        .linkCursor()
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if note.text.isEmpty && note.images.isEmpty {
                Text("Jot something down…  (drag a photo right into the text)")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.tertiaryText)
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.lg)
                    .allowsHitTesting(false)
            }
            InlineNoteEditor(
                runs: vm.noteBody(for: note.id),
                onChange: { vm.updateNoteBody(note.id, runs: $0) },
                controller: editorController,
                onKeepOpen: { vm.keepOpen() },
                onImageActivate: { pile in
                    vm.keepOpen()
                    // Open a gallery scoped to just the pile that was clicked, so
                    // a stack shows its own photos rather than the whole note's.
                    guard !pile.isEmpty else { return }
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        galleryImages = pile
                    }
                },
                onAddChecklist: {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        vm.addChecklistItem(to: note.id)
                    }
                }
            )
            .id(note.id)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.hair)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .innerCard()
    }

    // MARK: Importing

    /// Opens a file picker and drops the chosen photos in as inline cards at the
    /// caret. Drag-and-drop is handled inside `InlineNoteEditor` so it can land
    /// the image exactly where it's dropped.
    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        vm.keepOpen()
        guard panel.runModal() == .OK else { return }
        let images = panel.urls.compactMap { NoteImageStore.importImage(from: $0) }
        if !images.isEmpty { editorController.insert?(images) }
    }
}

// MARK: - Checklist

/// A tick-box list inside a note. Each row has a radio button you click to mark a
/// task complete (striking it through), an inline-editable label, and a delete
/// button on hover. The whole section collapses to an "Add checklist" button when
/// the note has no items yet, so it stays out of the way until you want it.
private struct ChecklistSection: View {
    @EnvironmentObject private var vm: NotchViewModel
    @EnvironmentObject private var settings: SettingsStore
    let noteID: UUID
    /// Taller item area when the editor is blown up into the bigger canvas.
    let expanded: Bool

    private var items: [ChecklistItem] { vm.checklist(for: noteID) }
    private var doneCount: Int { items.filter(\.done).count }

    var body: some View {
        if items.isEmpty {
            // A checklist is started via "/list " or the editor's right-click menu,
            // so there's no empty-state button here anymore.
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack(spacing: Spacing.s) {
                    Image(systemName: "checklist")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                    Text("\(doneCount)/\(items.count)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.tertiaryText)
                    Spacer()
                    addButton(label: "Add")
                }

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: Spacing.xs) {
                        ForEach(items) { item in
                            ChecklistRow(item: item, noteID: noteID)
                        }
                    }
                }
                .frame(maxHeight: expanded ? 220 : 92)
            }
            .padding(Spacing.md)
            .innerCard(cornerRadius: 12)
        }
    }

    private func addButton(label: String) -> some View {
        Button {
            vm.addChecklistItem(to: noteID)
        } label: {
            HStack(spacing: Spacing.s) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(settings.accent)
            .frame(maxWidth: items.isEmpty ? .infinity : nil)
            .padding(.vertical, items.isEmpty ? 8 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(ChecklistAddChrome(fullWidth: items.isEmpty))
        .linkCursor()
    }
}

/// Gives the empty-state add button a full card look; the inline "Add" stays bare.
private struct ChecklistAddChrome: ViewModifier {
    let fullWidth: Bool
    @ViewBuilder
    func body(content: Content) -> some View {
        if fullWidth {
            content.innerCard(cornerRadius: 12)
        } else {
            content
        }
    }
}

/// One checklist row: radio button + editable label + hover delete.
private struct ChecklistRow: View {
    @EnvironmentObject private var vm: NotchViewModel
    @EnvironmentObject private var settings: SettingsStore
    let item: ChecklistItem
    let noteID: UUID
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                    vm.toggleChecklistItem(item.id, in: noteID)
                }
            } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(item.done ? settings.accent : Theme.secondaryText)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .linkCursor()

            TextField("List item", text: vm.checklistItemBinding(item.id, in: noteID))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(item.done ? Theme.tertiaryText : .white)
                .strikethrough(item.done, color: Theme.tertiaryText)

            Button {
                withAnimation { vm.deleteChecklistItem(item.id, in: noteID) }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white, Color.black.opacity(0.5))
            }
            .buttonStyle(.plain)
            .notchHover(scale: 1.15)
            .opacity(hovering ? 1 : 0)
        }
        .padding(.vertical, Spacing.xs)
        .padding(.horizontal, Spacing.s)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.line(hovering ? 0.06 : 0))
        }
        .onHover { hovering = $0 }
    }
}

// MARK: - Image gallery (cover flow)

/// Deployed over a blurred backdrop when an image pile is tapped: the pile's photos
/// laid out as a **cover-flow fan**. The focused photo sits front-and-centre, big and
/// upright with a drop shadow; its neighbours shrink, tilt like a fanned deck and dip
/// into a shallow arc behind it. Click a side photo (or drag / use the chevrons) to
/// glide it to the centre with a springy settle; click the centred photo to open it
/// full-size; tap the backdrop to dismiss.
private struct CoverFlowGallery: View {
    let images: [NoteImage]
    let onClose: () -> Void

    /// The photo currently at the centre of the fan.
    @State private var selected = 0
    /// Live horizontal drag translation, so the fan tracks the finger before it snaps.
    @State private var drag: CGFloat = 0
    @State private var appeared = false

    /// The signature settle — quick to respond, loose enough to overshoot and wobble
    /// as a card lands, which is what gives the fan its playful feel.
    private let settle = Animation.spring(response: 0.42, dampingFraction: 0.7)

    var body: some View {
        GeometryReader { geo in
            // Card sized to the pile's stage; portrait-ish so photos read like covers.
            let cardW = min(geo.size.width * 0.44, geo.size.height * 0.66)
            let cardH = cardW * 1.16
            let step = cardW * 0.52          // gap between neighbouring card centres
            // Fractional position of the fan's centre — integer at rest, dragged smoothly.
            let position = CGFloat(selected) - drag / step

            ZStack {
                backdrop

                ZStack {
                    ForEach(window(around: position), id: \.self) { i in
                        card(i, position: position, size: CGSize(width: cardW, height: cardH), step: step)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(swipe(step: step))

                overlays
            }
            .scaleEffect(appeared ? 1 : 0.95)
            .opacity(appeared ? 1 : 0)
        }
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous))
        .onExitCommand { onClose() }
        .onAppear {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { appeared = true }
        }
    }

    // MARK: Pieces

    private var backdrop: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay(Color.black.opacity(0.28))
            .contentShape(Rectangle())
            .onTapGesture { onClose() }
    }

    /// The header (count + close) and the two chevrons that step through the fan.
    private var overlays: some View {
        VStack {
            HStack {
                Text("\(selected + 1) of \(images.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .contentTransition(.numericText())
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.primaryText)
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .blackGlass(in: Capsule(), interactive: true)
                .linkCursor()
            }

            Spacer()

            HStack {
                chevron("chevron.left", enabled: selected > 0) { step(by: -1) }
                Spacer()
                chevron("chevron.right", enabled: selected < images.count - 1) { step(by: 1) }
            }
        }
        .padding(Spacing.base)
        .allowsHitTesting(true)
    }

    private func chevron(_ symbol: String, enabled: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.primaryText)
                .frame(width: 30, height: 42)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .blackGlass(in: Capsule(), interactive: true)
        .opacity(enabled ? 1 : 0.25)
        .disabled(!enabled)
        .linkCursor()
    }

    /// One photo in the fan, transformed by its distance `d` from centre: farther cards
    /// slide out along the arc, shrink, tilt (pivoting from their base like a dealt
    /// card), dim, blur and fall behind.
    private func card(_ i: Int, position: CGFloat, size: CGSize, step: CGFloat) -> some View {
        let d = CGFloat(i) - position
        let ad = min(abs(d), 3)
        let isCentre = i == selected
        return CoverCard(image: images[i], size: size, focused: isCentre) {
            if isCentre {
                NSWorkspace.shared.open(NoteImageStore.url(for: images[i]))
            } else {
                withAnimation(settle) { selected = i }
            }
        }
        .rotationEffect(.degrees(Double(max(-3, min(3, d))) * 5), anchor: .bottom)
        .scaleEffect(1 - ad * 0.12)
        .offset(x: d * step, y: ad * size.height * 0.08)
        .opacity(Double(max(0.32, 1 - ad * 0.26)))
        .blur(radius: ad > 1 ? (ad - 1) * 1.6 : 0)
        .zIndex(-Double(ad))
        .shadow(color: .black.opacity(isCentre ? 0.42 : 0.16),
                radius: isCentre ? 18 : 6, y: isCentre ? 11 : 4)
    }

    // MARK: Navigation

    /// Only the cards near the centre are mounted (and load their bitmaps); the rest of
    /// a large pile stays off-stage.
    private func window(around position: CGFloat) -> [Int] {
        images.indices.filter { abs(CGFloat($0) - position) <= 3 }
    }

    private func step(by delta: Int) {
        withAnimation(settle) {
            selected = min(images.count - 1, max(0, selected + delta))
        }
    }

    /// Horizontal drag tracks the fan live, then snaps to the nearest card on release.
    private func swipe(step: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { drag = $0.translation.width }
            .onEnded { value in
                let moved = -value.predictedEndTranslation.width / step
                let target = min(images.count - 1, max(0, Int((CGFloat(selected) + moved).rounded())))
                withAnimation(settle) {
                    selected = target
                    drag = 0
                }
            }
    }
}

/// A single cover-flow card: the photo scaled to fill a rounded frame, with a brighter
/// border and an "open" hint while it's the focused (centre) card.
private struct CoverCard: View {
    let image: NoteImage
    let size: CGSize
    let focused: Bool
    let action: () -> Void
    @State private var loaded: NSImage?
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if let loaded {
                    Image(nsImage: loaded)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle().fill(Theme.line(0.08))
                        .overlay(ThinkingOrb(size: 22))
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.line(focused ? 0.4 : 0.16), lineWidth: focused ? 1.5 : 1)
            }
            .overlay {
                // Only the focused card offers "open full size", surfaced on hover.
                if focused && hovering {
                    ZStack {
                        Color.black.opacity(0.32)
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .transition(.opacity)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .pointerStyle(.link)
        .task(id: image.id) { loaded = NoteImageStore.load(image) }
    }
}
