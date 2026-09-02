import SwiftUI
import AppKit
import QuickLookThumbnailing

/// The Mood board: a freeform canvas you can pin notes, links and files onto.
///
/// Two option buttons live in the corner toolbar:
///   • **Magnetize** — snaps every item into a tidy (invisible) grid and locks
///     dragging; toggle it off to go back to the loose, hand-placed layout.
///   • **Expand** — blows the whole notch up into a much larger canvas (a "bigger
///     notch", not a real fullscreen) so there's room to arrange things.
struct MoodTabView: View {
    @EnvironmentObject private var vm: NotchViewModel
    @EnvironmentObject private var settings: SettingsStore

    @State private var showLinkField = false
    @State private var linkText = ""
    @State private var isDropTargeted = false
    /// Local keyDown monitor that turns ⌘V (or ⌃V) into a board item.
    @State private var pasteMonitor: Any?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                dottedGrid
                    .allowsHitTesting(false)

                // Tapping empty canvas ends any text-editing focus (clicking out).
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { NSApp.keyWindow?.makeFirstResponder(nil) }

                if vm.moodItems.isEmpty {
                    emptyState
                        .allowsHitTesting(false)
                }

                ForEach(Array(vm.moodItems.enumerated()), id: \.element.id) { index, item in
                    let base = position(for: item, index: index, count: vm.moodItems.count, size: size)
                    MoodTile(
                        item: item,
                        magnetized: vm.moodMagnetized,
                        accent: settings.accent,
                        noteText: vm.moodNoteBinding(item.id),
                        onOpen: { open(item) },
                        onDelete: { vm.removeMood(item.id) },
                        onMove: { translation in
                            let point = CGPoint(
                                x: (base.x + translation.width) / max(size.width, 1),
                                y: (base.y + translation.height) / max(size.height, 1)
                            )
                            vm.moveMood(item.id, to: point)
                        },
                        onResize: { newScale in
                            vm.updateMood(item.id) { $0.scale = newScale }
                        }
                    )
                    .position(base)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous)
                    .fill(isDropTargeted ? settings.accent.opacity(0.08) : Color.black.opacity(0.18))
            }
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous)
                    .strokeBorder(isDropTargeted ? settings.accent : Theme.cardStroke, lineWidth: 1)
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.82), value: vm.moodMagnetized)
            .onDrop(of: [.fileURL, .url, .text], isTargeted: dropTargetBinding) { providers, location in
                let point = CGPoint(x: location.x / max(size.width, 1),
                                    y: location.y / max(size.height, 1))
                handleDrop(providers, at: point)
                return true
            }
            // Paste (⌘V) whatever's on the clipboard — link, text or file —
            // straight onto the board without going through the + button. The panel
            // is a non-activating utility window, so we make it key while the board
            // is showing and watch for the paste keystroke ourselves.
            .background(PanelKeyGrabber())
            .overlay(alignment: .bottomLeading) { leadingToolbar }
            .overlay(alignment: .bottomTrailing) { expandButton }
            .onAppear(perform: installPasteMonitor)
            .onDisappear(perform: removePasteMonitor)
        }
    }

    private var dropTargetBinding: Binding<Bool> {
        Binding(
            get: { isDropTargeted },
            set: { targeted in
                isDropTargeted = targeted
                vm.noteDrag(active: targeted)
                if targeted { vm.keepOpen() }
            }
        )
    }

    // MARK: - Layout

    /// Absolute canvas position for an item — its stored freeform spot, or a grid
    /// cell when the board is magnetized.
    private func position(for item: MoodItem, index: Int, count: Int, size: CGSize) -> CGPoint {
        guard vm.moodMagnetized else {
            return CGPoint(x: item.x * size.width, y: item.y * size.height)
        }
        let pitch: CGFloat = 150
        let cols = max(1, min(count, Int(size.width / pitch)))
        let rows = max(1, Int(ceil(Double(count) / Double(cols))))
        let c = index % cols
        let r = index / cols
        let x = (CGFloat(c) + 0.5) / CGFloat(cols)
        let y = (CGFloat(r) + 0.5) / CGFloat(rows)
        return CGPoint(x: x * size.width, y: y * size.height)
    }

    // MARK: - Pieces

    private var dottedGrid: some View {
        Canvas { ctx, size in
            let step: CGFloat = 22
            let dot: CGFloat = 1.4
            var y: CGFloat = step / 2
            while y < size.height {
                var x: CGFloat = step / 2
                while x < size.width {
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: dot, height: dot)),
                             with: .color(.white.opacity(0.06)))
                    x += step
                }
                y += step
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 22, weight: .medium))
            Text("Drop links, files or notes here")
                .font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(Theme.secondaryText)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var leadingToolbar: some View {
        GlassEffectContainer(spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                addMenu
                toolButton(symbol: "square.grid.2x2.fill",
                           active: vm.moodMagnetized,
                           help: vm.moodMagnetized ? "Unsnap" : "Magnetize into a grid") {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                        vm.moodMagnetized.toggle()
                    }
                }
            }
        }
        .padding(Spacing.base)
        .popover(isPresented: $showLinkField, arrowEdge: .top) { linkPopover }
    }

    private var addMenu: some View {
        Menu {
            Button {
                vm.addMoodNote(at: randomSpot())
            } label: { Label("New Note", systemImage: "note.text") }
            Button {
                showLinkField = true
            } label: { Label("Add Link…", systemImage: "link") }
            Button {
                pickFiles()
            } label: { Label("Add File…", systemImage: "doc") }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .blackGlass(in: Circle(), interactive: true)
        .linkCursor()
        .help("Add to board")
    }

    private var expandButton: some View {
        toolButton(symbol: vm.moodExpanded
                   ? "arrow.down.right.and.arrow.up.left"
                   : "arrow.up.left.and.arrow.down.right",
                   active: vm.moodExpanded,
                   help: vm.moodExpanded ? "Shrink" : "Expand the notch") {
            withAnimation(Metrics.openSpring) { vm.moodExpanded.toggle() }
        }
        .padding(Spacing.base)
    }

    private func toolButton(symbol: String, active: Bool, help: String, action: @escaping () -> Void) -> some View {
        GlassButton(shape: AnyShape(Circle()),
                    tint: active ? settings.accent.opacity(0.6) : nil,
                    action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
        }
        .help(help)
    }

    private var linkPopover: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "link").foregroundStyle(Theme.secondaryText)
            TextField("https://…", text: $linkText)
                .textFieldStyle(.plain)
                .frame(width: 200)
                .onSubmit(commitLink)
            Button("Add", action: commitLink)
                .buttonStyle(.borderedProminent)
                .disabled(linkText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(Spacing.base)
    }

    // MARK: - Actions

    private func commitLink() {
        vm.addMoodLink(linkText, at: randomSpot())
        linkText = ""
        showLinkField = false
    }

    // MARK: - Paste

    private func installPasteMonitor() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isPaste = event.charactersIgnoringModifiers?.lowercased() == "v"
                && (mods == .command || mods == .control)
            // Swallow the keystroke (return nil) only when we actually pasted, so
            // ⌘V still works normally inside a note's text editor.
            if isPaste, pasteFromClipboard() { return nil }
            return event
        }
    }

    private func removePasteMonitor() {
        if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
        pasteMonitor = nil
    }

    /// Reads the general pasteboard and pins whatever it finds — a file, a link,
    /// or plain text — onto the board. Returns false when there's nothing usable.
    @discardableResult
    private func pasteFromClipboard() -> Bool {
        let pb = NSPasteboard.general

        // Finder file copies.
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            vm.keepOpen()
            for url in urls { vm.addMoodFile(url: url, at: randomSpot()) }
            return true
        }
        // Web URLs (e.g. copied from a browser's address bar).
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL],
           let url = urls.first {
            vm.keepOpen()
            vm.addMoodLink(url.absoluteString, at: randomSpot())
            return true
        }
        // Plain text — a bare URL becomes a link, anything else a note.
        if let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            vm.keepOpen()
            if text.hasPrefix("http://") || text.hasPrefix("https://") {
                vm.addMoodLink(text, at: randomSpot())
            } else {
                vm.addMoodNote(text, at: randomSpot())
            }
            return true
        }
        return false
    }

    private func randomSpot() -> CGPoint {
        CGPoint(x: .random(in: 0.3...0.7), y: .random(in: 0.3...0.7))
    }

    private func open(_ item: MoodItem) {
        switch item.kind {
        case .link: if let url = item.url { NSWorkspace.shared.open(url) }
        case .file: NSWorkspace.shared.open(URL(fileURLWithPath: item.content))
        case .note: break
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        vm.keepOpen()
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            vm.addMoodFile(url: url, at: randomSpot())
        }
    }

    private func handleDrop(_ providers: [NSItemProvider], at point: CGPoint) {
        vm.keepOpen()
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        if url.isFileURL {
                            vm.addMoodFile(url: url, at: point)
                        } else {
                            vm.addMoodLink(url.absoluteString, at: point)
                        }
                    }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text, !text.isEmpty else { return }
                    Task { @MainActor in
                        if text.hasPrefix("http://") || text.hasPrefix("https://") {
                            vm.addMoodLink(text, at: point)
                        } else {
                            vm.addMoodNote(text, at: point)
                        }
                    }
                }
            }
        }
    }
}

/// Makes the host panel the key window while the Mood board is on screen, so it
/// receives keystrokes (⌘V) without the user having to click into a text field.
/// The panel is a non-activating utility window, so taking key focus doesn't
/// bring the app forward or steal the frontmost app's visual focus.
private struct PanelKeyGrabber: NSViewRepresentable {
    func makeNSView(context: Context) -> KeyGrabView { KeyGrabView() }
    func updateNSView(_ nsView: KeyGrabView, context: Context) { nsView.grabKey() }

    /// Grabs key on every window move (the board is only mounted while visible) and
    /// re-asserts a beat later, since the panel isn't ordered in until after the
    /// SwiftUI view is first attached.
    final class KeyGrabView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            grabKey()
        }

        func grabKey() {
            guard let window else { return }
            window.makeKey()
            DispatchQueue.main.async { [weak window] in window?.makeKey() }
        }
    }
}

/// A single pinned item on the Mood board. Draggable to reposition (unless the
/// board is magnetized), with a hover-revealed remove button.
private struct MoodTile: View {
    @EnvironmentObject private var vm: NotchViewModel
    let item: MoodItem
    let magnetized: Bool
    let accent: Color
    @Binding var noteText: String
    let onOpen: () -> Void
    let onDelete: () -> Void
    let onMove: (CGSize) -> Void
    let onResize: (Double) -> Void

    @GestureState private var drag = CGSize.zero
    /// Live scale delta while the corner handle is being dragged.
    @GestureState private var resizeDelta: CGFloat = 0
    @State private var hovering = false
    @State private var editing = false
    @FocusState private var focused: Bool

    // Resolved per-note appearance (with defaults for notes saved before these).
    private var noteColor: Color { (item.noteColor ?? .accent).color(accent: accent) }
    private var noteStyle: NoteStyle { item.noteStyle ?? .minimal }
    private var noteFont: Font { .system(size: (item.noteTextSize ?? .medium).points, weight: .medium) }

    private var draggable: Bool { !magnetized && !editing }
    private var resizable: Bool { !editing }

    /// Allowed size range for a tile.
    private static let minScale: CGFloat = 0.6
    private static let maxScale: CGFloat = 2.4

    /// The tile's committed size multiplier, plus any in-progress drag, clamped.
    private var effectiveScale: CGFloat {
        min(max(CGFloat(item.scale ?? 1) + resizeDelta, Self.minScale), Self.maxScale)
    }

    var body: some View {
        content
            // A soft brighten while the pointer is over a tile (but not mid-edit),
            // so every pinned item answers the cursor like the rest of the UI.
            .brightness(hovering && !editing ? 0.06 : 0)
            .overlay(alignment: .bottomTrailing) { resizeHandle }
            .scaleEffect(effectiveScale, anchor: .center)
            .rotationEffect(.degrees(magnetized ? 0 : item.rotation))
            .offset(drag)
            .animation(.easeOut(duration: 0.18), value: hovering)
            .onHover { hovering = $0 }
            .pointerStyle(draggable ? .grabIdle : .link)
            .gesture(dragGesture)
            .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.8), value: drag)
            .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.8), value: resizeDelta)
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .note: noteTile
        case .link:
            if item.youTubeVideoID != nil { videoTile } else { linkTile }
        case .file: fileTile
        }
    }

    // MARK: Tiles

    /// Text color for the current style (dark on the light paper styles).
    private var noteTextColor: Color {
        switch noteStyle {
        case .sticky: return noteColor.readableForeground
        case .index:  return .black
        case .minimal, .glass: return .white
        }
    }

    private var noteTile: some View {
        Group {
            if editing {
                TextEditor(text: $noteText)
                    .font(noteFont)
                    .scrollContentBackground(.hidden)
                    .foregroundStyle(noteTextColor)
                    .focused($focused)
                    .frame(width: 130, height: 84)
            } else {
                Text(noteText.isEmpty ? "New Note" : noteText)
                    .font(noteFont)
                    .foregroundStyle(noteText.isEmpty ? noteTextColor.opacity(0.5) : noteTextColor)
                    .lineLimit(5)
                    .frame(width: 130, height: 84, alignment: .topLeading)
            }
        }
        .padding(Spacing.md)
        .background { noteBackground }
        .overlay { noteBorder }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { beginEditing() }
        .onChange(of: focused) { if !focused { editing = false } }
        .glassContextMenu { noteMenuItems }
    }

    @ViewBuilder
    private var noteBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        switch noteStyle {
        case .minimal:
            shape.fill(noteColor.opacity(0.16))
        case .sticky:
            shape.fill(noteColor.opacity(0.92))
        case .index:
            ZStack {
                shape.fill(Color(white: 0.93))
                // Faint ruled lines.
                VStack(spacing: Spacing.lg) {
                    ForEach(0..<5, id: \.self) { _ in
                        Rectangle().fill(Color.black.opacity(0.06)).frame(height: 1)
                    }
                }
                .padding(.horizontal, Spacing.sm)
                .padding(.top, Spacing.xl)
            }
        case .glass:
            shape.fill(Color.black.opacity(0.25))
                .blackGlass(in: shape, tint: noteColor.opacity(0.25))
        }
    }

    private var noteBorder: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(
                noteStyle == .index ? Color.black.opacity(0.12) : noteColor.opacity(editing ? 0.9 : 0.35),
                lineWidth: 1
            )
    }

    private var noteMenuItems: [GlassMenuItem] {
        let id = item.id
        return [
            .menu("Color", systemImage: "paintpalette", NoteColor.allCases.map { c in
                .item(c.label) { vm.updateMood(id) { $0.noteColor = c } }
            }),
            .menu("Style", systemImage: "sparkles", NoteStyle.allCases.map { s in
                .item(s.label) { vm.updateMood(id) { $0.noteStyle = s } }
            }),
            .menu("Text Size", systemImage: "textformat.size", NoteTextSize.allCases.map { t in
                .item(t.label) { vm.updateMood(id) { $0.noteTextSize = t } }
            }),
            .item("Edit", systemImage: "pencil") { beginEditing() },
            .item("Duplicate", systemImage: "plus.square.on.square") { vm.duplicateMood(id) },
            .item("Reset Size", systemImage: "arrow.counterclockwise") { onResize(1) },
            .item("Delete", systemImage: "trash", destructive: true) { onDelete() }
        ]
    }

    /// A wide 16:9 card for YouTube links: the full video thumbnail (no square
    /// crop) plus a couple of title lines and the channel name underneath.
    private var videoTile: some View {
        MoodVideoCard(item: item)
            .onTapGesture(perform: onOpen)
            .glassContextMenu {
                [
                    .item("Open", systemImage: "arrow.up.forward.square") { onOpen() },
                    .item("Copy Link", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.content, forType: .string)
                    },
                    .item("Reset Size", systemImage: "arrow.counterclockwise") { onResize(1) },
                    .item("Delete", systemImage: "trash", destructive: true) { onDelete() }
                ]
            }
    }

    private var linkTile: some View {
        VStack(spacing: Spacing.s) {
            MoodLinkThumbnail(item: item, size: 96)
            Text(item.title.isEmpty ? item.host : item.title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 96)
        }
        .padding(Spacing.sm)
        .innerCard(cornerRadius: 12)
        .onTapGesture(perform: onOpen)
        .glassContextMenu {
            [
                .item("Open", systemImage: "arrow.up.forward.square") { onOpen() },
                .item("Copy Link", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.content, forType: .string)
                },
                .item("Reset Size", systemImage: "arrow.counterclockwise") { onResize(1) },
                .item("Delete", systemImage: "trash", destructive: true) { onDelete() }
            ]
        }
    }

    private var fileTile: some View {
        VStack(spacing: Spacing.s) {
            MoodFileThumbnail(url: URL(fileURLWithPath: item.content), size: 96)
            Text(item.title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 96)
        }
        .padding(Spacing.sm)
        .innerCard(cornerRadius: 12)
        .onTapGesture(perform: onOpen)
        .glassContextMenu {
            [
                .item("Open", systemImage: "arrow.up.forward.square") { onOpen() },
                .item("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.content)])
                },
                .item("Reset Size", systemImage: "arrow.counterclockwise") { onResize(1) },
                .item("Delete", systemImage: "trash", destructive: true) { onDelete() }
            ]
        }
    }

    // MARK: Chrome

    /// A corner grip that appears on hover; drag it to resize the tile. Counter-
    /// scaled so it stays a constant size regardless of how big the tile is.
    @ViewBuilder
    private var resizeHandle: some View {
        if resizable && (hovering || resizeDelta != 0) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.black.opacity(0.65)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
                .scaleEffect(1 / effectiveScale)
                .offset(x: 7, y: 7)
                .transition(.opacity)
                .highPriorityGesture(resizeGesture)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .updating($drag) { value, state, _ in
                if draggable { state = value.translation }
            }
            .onEnded { value in
                if draggable { onMove(value.translation) }
            }
    }

    /// Diagonal drag on the corner handle → size multiplier. Dragging out grows the
    /// tile, dragging in shrinks it; committed to the item on release.
    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .updating($resizeDelta) { value, state, _ in
                state = (value.translation.width + value.translation.height) / 180
            }
            .onEnded { value in
                let delta = (value.translation.width + value.translation.height) / 180
                let newScale = min(max(CGFloat(item.scale ?? 1) + delta, Self.minScale), Self.maxScale)
                onResize(Double(newScale))
            }
    }

    private func beginEditing() {
        guard item.kind == .note, !magnetized else { return }
        editing = true
        focused = true
    }
}

/// Renders a real preview of a file — the actual picture for images, a QuickLook
/// thumbnail for PDFs/docs, and the file-type icon only as a last resort. Without
/// this a moodboard just shows generic file icons.
private struct MoodFileThumbnail: View {
    let url: URL
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.06))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: size * 0.5, height: size * 0.5)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: size * 2, height: size * 2),
            scale: scale,
            representationTypes: .thumbnail
        )
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            image = rep.nsImage
            return
        }
        // Fallback: load the file directly if it's a plain image.
        if let direct = NSImage(contentsOf: url) { image = direct }
    }
}

/// A wide card for a pinned YouTube link: the full 16:9 poster with the video
/// title (two lines) and channel name below, fetched from YouTube's oEmbed
/// endpoint. Falls back to the stored host/title until the metadata arrives.
private struct MoodVideoCard: View {
    let item: MoodItem
    @State private var title: String?
    @State private var author: String?

    private let width: CGFloat = 152

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            MoodLinkThumbnail(item: item, size: width, aspect: 16.0 / 9.0)
            VStack(alignment: .leading, spacing: Spacing.hair) {
                Text(title ?? (item.title.isEmpty ? item.host : item.title))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let author, !author.isEmpty {
                    Text(author)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
            }
            .frame(width: width, alignment: .leading)
        }
        .padding(Spacing.sm)
        .innerCard(cornerRadius: 12)
        .task(id: item.content) { await loadMeta() }
    }

    /// Pulls the video title and channel from YouTube's public oEmbed endpoint.
    private func loadMeta() async {
        guard let url = item.url,
              let encoded = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let api = URL(string: "https://www.youtube.com/oembed?url=\(encoded)&format=json"),
              let (data, _) = try? await URLSession.shared.data(from: api),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        title = json["title"] as? String
        author = json["author_name"] as? String
    }
}

/// A rich preview image for a pinned link: the YouTube video thumbnail, or the
/// page's Open Graph image (covers Are.na block images and most sites), falling
/// back to the favicon. Without this a link is just a favicon — not moodboard-y.
private struct MoodLinkThumbnail: View {
    let item: MoodItem
    /// Rendered width; height follows from `aspect` (1 = square, 16/9 = video).
    let size: CGFloat
    var aspect: CGFloat = 1
    @State private var image: NSImage?

    private var height: CGFloat { size / aspect }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.06))
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                AsyncImage(url: item.faviconURL) { img in
                    img.resizable().scaledToFit()
                } placeholder: {
                    Image(systemName: "globe")
                        .font(.system(size: size * 0.28))
                        .foregroundStyle(Theme.secondaryText)
                }
                .frame(width: size * 0.42, height: size * 0.42)
            }
        }
        .frame(width: size, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        }
        .task(id: item.content) { await load() }
    }

    private func load() async {
        guard let url = item.url else { return }
        // Prefer the full-resolution 16:9 poster; fall back to the always-present
        // hqdefault (4:3 with letterbox bars, which the 16:9 frame crops away).
        if let id = item.youTubeVideoID {
            for name in ["maxresdefault", "sddefault", "hqdefault"] {
                if let img = await Self.fetchImage("https://i.ytimg.com/vi/\(id)/\(name).jpg") {
                    image = img
                    return
                }
            }
            return
        }
        // Are.na blocks: the page's og:image is a tiny thumbnail, so pull the
        // full-resolution image straight from the public API instead.
        if let arena = await Self.arenaImageURL(for: url),
           let img = await Self.fetchImage(arena) {
            image = img
            return
        }
        if let og = await Self.ogImageURL(for: url),
           let img = await Self.fetchImage(Self.upgraded(og)) {
            image = img
        }
    }

    /// The numeric block id from an `are.na/block/<id>` URL, if this is one.
    private static func arenaBlockID(_ url: URL) -> String? {
        guard let host = url.host()?.lowercased(), host.contains("are.na") else { return nil }
        let parts = url.pathComponents
        guard let i = parts.firstIndex(of: "block"), i + 1 < parts.count else { return nil }
        let id = parts[i + 1]
        return id.allSatisfy(\.isNumber) && !id.isEmpty ? id : nil
    }

    /// Best available image URL for an Are.na block, largest first.
    private static func arenaImageURL(for url: URL) async -> String? {
        guard let id = arenaBlockID(url),
              let api = URL(string: "https://api.are.na/v2/blocks/\(id)"),
              let (data, _) = try? await URLSession.shared.data(from: api),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let image = json["image"] as? [String: Any] else { return nil }
        // Largest variant first so Are.na blocks come back crisp.
        for key in ["original", "large", "display"] {
            if let variant = image[key] as? [String: Any],
               let s = variant["url"] as? String, !s.isEmpty {
                return s
            }
        }
        return nil
    }

    /// Bumps the width on Are.na's imgix-served images so an og:image thumbnail
    /// comes back sharp; leaves every other URL untouched.
    private static func upgraded(_ urlString: String) -> String {
        guard urlString.contains("images.are.na"),
              var comps = URLComponents(string: urlString) else { return urlString }
        var items = (comps.queryItems ?? []).filter { $0.name != "w" && $0.name != "h" }
        items.append(URLQueryItem(name: "w", value: "1600"))
        comps.queryItems = items
        return comps.string ?? urlString
    }

    private static func fetchImage(_ urlString: String) async -> NSImage? {
        guard let url = URL(string: urlString), isPublicWebURL(url),
              let (data, resp) = try? await URLSession.shared.data(from: url),
              ((resp as? HTTPURLResponse)?.statusCode ?? 200) < 400,
              let img = NSImage(data: data), img.size.width > 1 else { return nil }
        return img
    }

    private static func ogImageURL(for url: URL) async -> String? {
        guard isPublicWebURL(url) else { return nil }
        var request = URLRequest(url: url)
        // Identify honestly rather than masquerading as a browser — we're fetching a
        // link the user pinned only to pull its preview image.
        request.setValue("NotchGlass/1.0 (link preview)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        let html = String(decoding: data.prefix(300_000), as: UTF8.self)
        for key in ["og:image:secure_url", "og:image:url", "og:image", "twitter:image"] {
            if let found = firstMeta(html, property: key) { return absolute(found, base: url) }
        }
        return nil
    }

    private static func firstMeta(_ html: String, property: String) -> String? {
        let esc = NSRegularExpression.escapedPattern(for: property)
        let patterns = [
            "<meta[^>]+(?:property|name)=[\"']\(esc)[\"'][^>]+content=[\"']([^\"']+)[\"']",
            "<meta[^>]+content=[\"']([^\"']+)[\"'][^>]+(?:property|name)=[\"']\(esc)[\"']"
        ]
        for pattern in patterns {
            if let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: html) {
                return String(html[r])
            }
        }
        return nil
    }

    private static func absolute(_ s: String, base: URL) -> String {
        if s.hasPrefix("http") { return s }
        if s.hasPrefix("//") { return "https:" + s }
        return URL(string: s, relativeTo: base)?.absoluteString ?? s
    }

    /// Whether it's safe to auto-fetch this URL for a preview. Blocks anything that
    /// isn't a public web address — localhost, `.local`/single-label intranet names,
    /// and private/loopback/link-local IP literals — so pinning a link can never
    /// silently fire a request at the user's own network. Also closes the SSRF-style
    /// second hop, since the scraped page's `og:image` (fetched via `fetchImage`) is a
    /// URL that page controls.
    private static func isPublicWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".internal") { return false }
        // A single-label host (no dot) is an intranet name, not a public site.
        if !host.contains(".") { return false }
        return !isPrivateIP(host)
    }

    /// True for IPv4/IPv6 literals in the private, loopback or link-local ranges. A
    /// dotted name that isn't a numeric IP (a normal DNS hostname) is treated as public.
    private static func isPrivateIP(_ host: String) -> Bool {
        if host.contains(":") {
            let h = host.hasPrefix("[") ? String(host.dropFirst().dropLast()) : host
            if h == "::1" { return true }
            return h.hasPrefix("fc") || h.hasPrefix("fd") || h.hasPrefix("fe80")
        }
        let parts = host.split(separator: ".")
        guard parts.count == 4, let a = Int(parts[0]), let b = Int(parts[1]),
              parts.allSatisfy({ Int($0) != nil }) else { return false }
        switch (a, b) {
        case (10, _), (127, _), (0, _):        return true
        case (169, 254), (192, 168):           return true
        case (172, 16...31):                   return true
        default:                               return false
        }
    }
}
