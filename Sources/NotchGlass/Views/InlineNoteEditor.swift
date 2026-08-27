import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A rich note editor where photos live *inside* the text. Drag an image in (or
/// hit the photo button) and it drops in as a rounded "card" right where the
/// caret is, flowing with the words like any other character. Backed by an
/// `NSTextView` with inline `NSTextAttachment`s; the content is serialised to a
/// list of text/image ``NoteRun``s so it stays small on disk (image bytes keep
/// living in `NoteImageStore`, the note only keeps filenames).
struct InlineNoteEditor: NSViewRepresentable {
    /// The note's current body, driven by the view model.
    let runs: [NoteRun]
    /// Called whenever the user edits (types, deletes, or inserts an image).
    let onChange: ([NoteRun]) -> Void
    /// Lets the surrounding SwiftUI toolbar drive the editor (e.g. the photo
    /// button inserts at the caret).
    let controller: NoteEditorController
    /// Keeps the panel open while a drag/import is in flight.
    var onKeepOpen: () -> Void = {}
    /// Called when an inline image card is clicked, passing every photo in the
    /// clicked group (one for a lone sticker, several for a stacked pile) so the
    /// surrounding view can open a gallery scoped to just that pile.
    var onImageActivate: ([NoteImage]) -> Void = { _ in }
    /// Called to start a checklist for this note — triggered by typing "/list "
    /// or via the editor's right-click menu.
    var onAddChecklist: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = InlineTextView()
        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.importsGraphics = false           // we handle image drops ourselves
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textColor = .white
        textView.insertionPointColor = .white
        textView.font = NoteRichText.baseFont
        textView.typingAttributes = NoteRichText.baseAttributes
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.registerForDraggedTypes(
            [.fileURL] + NSImage.imageTypes.map { NSPasteboard.PasteboardType($0) }
        )
        textView.textStorage?.setAttributedString(NoteRichText.attributed(from: runs))

        // The toolbar's "add photo" button funnels imported images to the caret.
        controller.insert = { [weak textView] images in
            textView?.insertImageCards(images)
        }

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .allowed

        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? InlineTextView,
              let storage = textView.textStorage else { return }
        // Only rebuild when the note actually changed underneath us — never in
        // response to our own edits, which would fight the caret. (Switching
        // notes recreates this view via `.id`, so this mostly guards outside
        // mutations to the same note.) Compare by content signature, not `==`:
        // image runs carry a fresh `NoteImage.id` each round-trip, so plain
        // equality would report a spurious change on every keystroke.
        if NoteRichText.signature(NoteRichText.runs(from: storage)) != NoteRichText.signature(runs) {
            let caret = textView.selectedRange()
            storage.setAttributedString(NoteRichText.attributed(from: runs))
            let clamped = min(caret.location, storage.length)
            textView.setSelectedRange(NSRange(location: clamped, length: 0))
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InlineNoteEditor
        init(_ parent: InlineNoteEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView,
                  let storage = textView.textStorage else { return }
            // "/list " shortcut: typing it strips the token and starts a checklist.
            let string = storage.string as NSString
            let caret = textView.selectedRange().location
            if caret >= 6,
               string.substring(with: NSRange(location: caret - 6, length: 6)).lowercased() == "/list " {
                storage.replaceCharacters(in: NSRange(location: caret - 6, length: 6), with: "")
                textView.setSelectedRange(NSRange(location: caret - 6, length: 0))
                parent.onAddChecklist()
            }
            parent.onChange(NoteRichText.runs(from: storage))
        }

        /// Adds an "Add list" item to the editor's right-click menu.
        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent,
                      at charIndex: Int) -> NSMenu? {
            let item = NSMenuItem(title: "Add list",
                                  action: #selector(InlineTextView.addListFromMenu),
                                  keyEquivalent: "")
            item.target = view
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
            return menu
        }
    }
}

/// Drives an ``InlineNoteEditor`` from the surrounding SwiftUI view.
final class NoteEditorController: ObservableObject {
    /// Set by the editor; call to drop image cards in at the current caret.
    var insert: (([NoteImage]) -> Void)?
}

// MARK: - Text view

/// `NSTextView` subclass that turns dropped/pasted images into inline cards at
/// the drop point instead of embedding raw bitmaps.
final class InlineTextView: NSTextView {
    weak var coordinator: InlineNoteEditor.Coordinator?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        canImportImages(from: sender.draggingPasteboard) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Cheap type check only — importing here (decoding/copying the file on
        // every hover frame) is what made drops feel laggy, so it's deferred to
        // the actual drop below.
        canImportImages(from: sender.draggingPasteboard) ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let images = importableImages(from: sender.draggingPasteboard)
        guard !images.isEmpty else { return super.performDragOperation(sender) }
        let point = convert(sender.draggingLocation, from: nil)
        insertImageCards(images, at: characterIndexForInsertion(at: point))
        return true
    }

    /// A cheap "are there any images here?" check for use during a drag — reads
    /// only the pasteboard's declared types, never the payload.
    private func canImportImages(from pasteboard: NSPasteboard) -> Bool {
        let imageURLs: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingContentsConformToTypes: [UTType.image.identifier]
        ]
        return pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
            || pasteboard.canReadObject(forClasses: [NSURL.self], options: imageURLs)
    }

    /// Right-click menu "Add list" → starts a checklist for this note.
    @objc func addListFromMenu() {
        coordinator?.parent.onAddChecklist()
    }

    /// Clicking directly on an image card activates it (open / deploy chooser)
    /// rather than placing the caret.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let filenames = attachmentFilenames(at: point) {
            coordinator?.parent.onImageActivate(filenames.map { NoteImage(filename: $0) })
            return
        }
        super.mouseDown(with: event)
    }

    /// The stored filenames of the image group the click actually landed on, or
    /// nil when the click missed every card. Returns the whole pile (not just the
    /// top photo) so the gallery opens scoped to exactly that group. Uses precise
    /// glyph bounds so clicking *near* an image (to place the caret) isn't
    /// mistaken for clicking it.
    private func attachmentFilenames(at point: NSPoint) -> [String]? {
        guard let layoutManager, let textContainer, let storage = textStorage,
              storage.length > 0 else { return nil }
        let local = NSPoint(x: point.x - textContainerInset.width,
                            y: point.y - textContainerInset.height)
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: local, in: textContainer,
                                             fractionOfDistanceThroughGlyph: &fraction)
        let charIndex = layoutManager.characterIndexForGlyph(at: glyph)
        guard charIndex < storage.length,
              let filenames = storage.attribute(.noteImageFilenames, at: charIndex,
                                                effectiveRange: nil) as? [String],
              !filenames.isEmpty,
              layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1),
                                         in: textContainer).contains(local)
        else { return nil }
        return filenames
    }

    /// Inserts image cards at `index` (or the caret when nil). If the insertion
    /// point touches an existing image group, the new photos merge into it so
    /// adjacent images always collapse into a single pile.
    func insertImageCards(_ images: [NoteImage], at index: Int? = nil) {
        guard !images.isEmpty, let storage = textStorage else { return }
        let location = max(0, min(index ?? selectedRange().location, storage.length))

        var filenames: [String] = []
        var start = location, end = location
        if location > 0,
           let left = storage.attribute(.noteImageFilenames, at: location - 1, effectiveRange: nil) as? [String] {
            filenames += left
            start = location - 1
        }
        filenames += images.map(\.filename)
        if location < storage.length,
           let right = storage.attribute(.noteImageFilenames, at: location, effectiveRange: nil) as? [String] {
            filenames += right
            end = location + 1
        }

        let replacement = NoteRichText.groupAttachmentString(for: filenames.map { NoteImage(filename: $0) })
        let range = NSRange(location: start, length: end - start)
        guard shouldChangeText(in: range, replacementString: replacement.string) else { return }
        storage.replaceCharacters(in: range, with: replacement)
        setSelectedRange(NSRange(location: start + replacement.length, length: 0))
        didChangeText()
        coordinator?.parent.onKeepOpen()
    }

    /// Turns image/file-URL pasteboard contents into stored ``NoteImage``s.
    private func importableImages(from pasteboard: NSPasteboard) -> [NoteImage] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingContentsConformToTypes: [UTType.image.identifier]
        ]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] {
            let imported = urls.compactMap { NoteImageStore.importImage(from: $0) }
            if !imported.isEmpty { return imported }
        }
        if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] {
            return images.compactMap { NoteImageStore.importImage(nsImage: $0) }
        }
        return []
    }
}

// MARK: - Rich text <-> runs

extension NSAttributedString.Key {
    /// Marks an attachment as a note-image *group*, carrying the store filenames
    /// of every photo in it (one for a lone sticker, several for a stacked pile)
    /// so the body round-trips without embedding bytes.
    static let noteImageFilenames = NSAttributedString.Key("noteImageFilenames")
}

/// Converts between a note's ``NoteRun`` body and the `NSAttributedString` the
/// text view renders, and draws the inline "card" bitmap for each photo.
enum NoteRichText {
    static let baseFont = NSFont.systemFont(ofSize: 13)

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: NSColor.white]
    }

    static func attributed(from runs: [NoteRun]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        // Collect runs of adjacent images so they render as one stacked pile
        // instead of a row of separate stickers.
        var pending: [NoteImage] = []
        func flushImages() {
            if !pending.isEmpty { out.append(groupAttachmentString(for: pending)); pending = [] }
        }
        for run in runs {
            switch run {
            case .text(let string):
                flushImages()
                out.append(NSAttributedString(string: string, attributes: baseAttributes))
            case .image(let image):
                pending.append(image)
            }
        }
        flushImages()
        return out
    }

    /// A content fingerprint that ignores the ephemeral `NoteImage.id` (which is
    /// regenerated every time we rebuild runs from the text storage), so two
    /// bodies compare equal when their text and photo *filenames* match.
    static func signature(_ runs: [NoteRun]) -> [String] {
        runs.map {
            switch $0 {
            case .text(let s):  return "t:" + s
            case .image(let i): return "i:" + i.filename
            }
        }
    }

    static func runs(from attributed: NSAttributedString) -> [NoteRun] {
        var runs: [NoteRun] = []
        var text = ""
        let full = NSRange(location: 0, length: attributed.length)
        let string = attributed.string as NSString
        attributed.enumerateAttributes(in: full, options: []) { attrs, range, _ in
            if let filenames = attrs[.noteImageFilenames] as? [String] {
                if !text.isEmpty { runs.append(.text(text)); text = "" }
                for filename in filenames { runs.append(.image(NoteImage(filename: filename))) }
            } else {
                text += string.substring(with: range)
            }
        }
        if !text.isEmpty { runs.append(.text(text)) }
        return runs
    }

    /// A one-character attributed string holding an image group — a lone sticker
    /// for a single photo, or an overlapping pile for several — tagged with the
    /// group's filenames so it survives the round trip.
    static func groupAttachmentString(for images: [NoteImage]) -> NSAttributedString {
        let attachment = NSTextAttachment()
        if let card = images.count == 1 ? cardImage(for: images[0]) : stackImage(for: images) {
            attachment.image = card
            // Sit the card *in* the line, centred on the text rather than resting
            // its whole height on the baseline (which shoved it up/down).
            let midline = (baseFont.ascender + baseFont.descender) / 2
            attachment.bounds = CGRect(x: 0, y: midline - card.size.height / 2,
                                       width: card.size.width, height: card.size.height)
        }
        let out = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
        let range = NSRange(location: 0, length: out.length)
        out.addAttribute(.noteImageFilenames, value: images.map(\.filename), range: range)
        out.addAttribute(.font, value: baseFont, range: range)
        return out
    }

    /// Renders several photos as a small overlapping pile of rounded cards, so a
    /// group of images reads as one stacked sticker inline. Shows up to four.
    static func stackImage(for images: [NoteImage]) -> NSImage? {
        let loaded = images.prefix(4).compactMap { NoteImageStore.load($0) }
        guard !loaded.isEmpty else { return nil }
        let count = loaded.count
        let each = NSSize(width: 40, height: 27)
        let dx: CGFloat = 6, dy: CGFloat = 4, pad: CGFloat = 5
        let angles: [CGFloat] = [-7, 5, -4, 7]
        let canvas = NSSize(width: each.width + dx * CGFloat(count - 1) + pad * 2,
                            height: each.height + dy * CGFloat(count - 1) + pad * 2)
        let out = NSImage(size: canvas)
        out.lockFocus()
        // Back-to-front: deeper cards sit higher/right, the first photo lands on top.
        for i in stride(from: count - 1, through: 0, by: -1) {
            let center = NSPoint(x: pad + each.width / 2 + dx * CGFloat(i),
                                 y: pad + each.height / 2 + dy * CGFloat(i))
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: center.x, yBy: center.y)
            transform.rotate(byDegrees: angles[i % angles.count])
            transform.translateX(by: -each.width / 2, yBy: -each.height / 2)
            transform.concat()
            let rect = NSRect(origin: .zero, size: each)
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).addClip()
            loaded[i].draw(in: rect, from: .zero, operation: .copy, fraction: 1)
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75),
                                      xRadius: 6, yRadius: 6)
            border.lineWidth = 1.5
            border.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
        out.unlockFocus()
        return out
    }

    /// Renders a photo as a small, rounded "sticker" that sits inline in the
    /// line of text (kept compact on purpose — the full image opens from the
    /// chooser). Roughly two text lines tall.
    static func cardImage(for image: NoteImage,
                          maxWidth: CGFloat = 72,
                          maxHeight: CGFloat = 32) -> NSImage? {
        guard let source = NoteImageStore.load(image),
              source.size.width > 0, source.size.height > 0 else { return nil }
        let scale = min(1, min(maxWidth / source.size.width, maxHeight / source.size.height))
        let target = NSSize(width: floor(source.size.width * scale),
                            height: floor(source.size.height * scale))
        let radius: CGFloat = 10
        let card = NSImage(size: target)
        card.lockFocus()
        let rect = NSRect(origin: .zero, size: target)
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
        source.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
        NSColor.white.withAlphaComponent(0.18).setStroke()
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                  xRadius: radius, yRadius: radius)
        border.lineWidth = 1
        border.stroke()
        card.unlockFocus()
        return card
    }
}
