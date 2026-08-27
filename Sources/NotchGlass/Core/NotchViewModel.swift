import SwiftUI
import Combine
import AppKit

/// Shared UI state for the notch panel.
@MainActor
final class NotchViewModel: ObservableObject {
    @Published var isOpen = false {
        didSet {
            if !isOpen { flushPendingPersists() }
            else { maybePresentWhatsNew() }
        }
    }
    @Published var selectedTab: NotchTab = .media
    /// When true, the panel shows the Settings screen (and grows taller).
    @Published var showSettings = false

    /// When true, the panel shows the "What's New" release-notes card over its
    /// content. Presented automatically the first time the panel opens after an
    /// update (see ``maybePresentWhatsNew()``), or manually from Settings.
    @Published var showWhatsNew = false
    /// Guards the auto-present so it's considered at most once per app run.
    private var whatsNewConsidered = false

    /// The first time the panel opens this run, surface the release notes if the app
    /// was updated since the user last acknowledged them. Deferred a beat so the card
    /// animates in after the panel finishes unfolding, not on top of the open motion.
    private func maybePresentWhatsNew() {
        guard !whatsNewConsidered else { return }
        whatsNewConsidered = true
        guard WhatsNew.hasUnseenNotes else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.isOpen else { return }
            withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
                self.showWhatsNew = true
            }
        }
    }

    /// Open the What's New card on demand (from the Settings "What's New" action).
    func presentWhatsNew() {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) { showWhatsNew = true }
    }

    /// Dismiss the What's New card and remember the user has caught up, so it won't
    /// reappear until the next update.
    func dismissWhatsNew() {
        WhatsNew.markSeen()
        withAnimation(.easeOut(duration: 0.2)) { showWhatsNew = false }
    }
    /// Which Settings category is on screen. Drives the panel height so the panel
    /// resizes to fit only the visible category rather than the tallest one.
    @Published var settingsCategory: SettingsCategory = .general

    /// Size of the collapsed pill (matches the physical notch when present).
    @Published var collapsedSize = CGSize(width: Metrics.fallbackNotchWidth,
                                          height: Metrics.fallbackNotchHeight)

    /// True while an AirDrop transfer has just landed — drives the transfer spinner
    /// in the collapsed pill. Set by `AirDropWatcher` and auto-cleared after a beat.
    @Published var transferActive = false
    private var transferClearWork: DispatchWorkItem?

    /// Lights the AirDrop transfer spinner in the collapsed pill for `duration`
    /// seconds. Re-arming while it's already showing just extends the window.
    func flashTransfer(for duration: TimeInterval = 4) {
        transferClearWork?.cancel()
        transferActive = true
        let work = DispatchWorkItem { [weak self] in
            self?.transferActive = false
        }
        transferClearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// A transient notice shown in the collapsed pill (e.g. "Fuel refilled"). Set by
    /// `flash(_:)`, auto-cleared after a beat. Icon + short label + optional tint.
    struct CollapsedEvent: Equatable {
        var symbol: String
        var text: String
        var tintHex: String?
    }

    /// The collapsed-pill notice currently showing, if any.
    @Published var collapsedEvent: CollapsedEvent?
    private var collapsedEventWork: DispatchWorkItem?

    /// Shows a transient notice in the collapsed pill for `duration` seconds.
    func flash(_ event: CollapsedEvent, for duration: TimeInterval = 5) {
        collapsedEventWork?.cancel()
        collapsedEvent = event
        let work = DispatchWorkItem { [weak self] in
            self?.collapsedEvent = nil
        }
        collapsedEventWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// True when the panel is welded to a real display notch. When false it floats
    /// below the top edge, so all four corners are rounded instead of only the
    /// bottom two.
    @Published var hasNotch = false

    /// True while a document is being dragged anywhere over the notch. Drives the
    /// large, cursor-clear drag affordances (the "Drop into…" chip, tab labels and
    /// the panel glow) — needed because the system drag image, owned by the source
    /// app, sits over the tiny top tabs and can't be resized by us.
    @Published var dragActive = false
    private var dragEndWork: DispatchWorkItem?

    /// Called by every drop target as the drag enters/leaves it. A short debounce
    /// on leave bridges the gap while the pointer travels between adjacent targets,
    /// so the drag mode doesn't flicker off between a tab and the canvas.
    func noteDrag(active: Bool) {
        dragEndWork?.cancel()
        if active {
            if !dragActive { dragActive = true }
        } else {
            let work = DispatchWorkItem { [weak self] in
                withAnimation(Metrics.closeSpring) { self?.dragActive = false }
            }
            dragEndWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    // Drop shelf
    @Published var droppedItems: [DroppedItem] = []
    @Published var isTargetedForDrop = false

    // Notes
    @Published var notes: [NoteItem] = [] {
        didSet { schedulePersist("notes") { $0.persistNotes() } }
    }
    /// Leather "books" that group notes together.
    @Published var noteFolders: [NoteFolder] = [] {
        didSet { schedulePersist("noteFolders") { $0.persistNoteFolders() } }
    }
    /// The note currently open full-screen in the panel, if any.
    @Published var focusedNoteID: UUID?
    /// A second note opened alongside the focused one (the "open a 2nd note"
    /// button), shown side-by-side. Nil when only one note is open.
    @Published var secondaryNoteID: UUID?
    /// The note book currently drilled into, if any.
    @Published var openNoteFolderID: UUID?
    /// Set to a book id (via the tile's "Rename" menu) to open it with its name
    /// field focused for an immediate rename. Cleared once the field takes focus.
    @Published var bookPendingRename: UUID?

    // Mood board
    @Published var moodItems: [MoodItem] = [] {
        didSet { schedulePersist("mood") { $0.persistMood() } }
    }
    /// When true the board auto-arranges into an (invisible) grid and dragging is
    /// disabled; when false items sit wherever they were dropped, lightly tilted.
    @Published var moodMagnetized = false
    /// When true the Mood board grows the notch into a much larger canvas.
    @Published var moodExpanded = false
    /// When true the Map tab grows the notch into the same larger canvas.
    @Published var mapExpanded = false
    /// When true the open note editor grows the notch into the same larger canvas.
    @Published var noteExpanded = false

    /// Whether the currently-selected tab is blown up into the big floating canvas
    /// (the Mood board, the Map, or a note being edited). Used to size the notch body.
    var isBigCanvas: Bool {
        (selectedTab == .mood && moodExpanded)
            || (selectedTab == .map && mapExpanded)
            || (selectedTab == .note && noteExpanded && focusedNoteID != nil)
    }

    // Ambient sounds
    @Published var ambientScene: AmbientScene = .off {
        didSet {
            defaults.set(ambientScene.rawValue, forKey: "notch.ambientScene")
            AmbientPlayer.shared.apply(scene: ambientScene, volume: ambientVolume)
        }
    }
    @Published var ambientVolume: Double = 0.6 {
        didSet {
            defaults.set(ambientVolume, forKey: "notch.ambientVolume")
            AmbientPlayer.shared.apply(scene: ambientScene, volume: ambientVolume)
        }
    }

    // Websites
    @Published var websites: [WebsiteItem] = [] {
        didSet { schedulePersist("websites") { $0.persistWebsites() } }
    }
    @Published var websiteFolders: [WebsiteFolder] = [] {
        didSet { schedulePersist("websiteFolders") { $0.persistWebsiteFolders() } }
    }
    /// The website folder currently drilled into, if any.
    @Published var openFolderID: UUID?
    /// Set to a website-folder id (via the tile's "Rename" menu) to open it with
    /// its name field focused. Cleared once the field takes focus.
    @Published var websiteFolderPendingRename: UUID?

    private var closeWorkItem: DispatchWorkItem?
    private var openWorkItem: DispatchWorkItem?

    /// Dwell time before a hover actually opens the panel. Without it, merely
    /// moving the cursor *through* the notch (e.g. reaching for a browser tab's
    /// close button just below it) snaps the panel open over what's underneath.
    private let openHoverDelay: TimeInterval = 0.32
    private let defaults = UserDefaults.standard
    private var cancellables = Set<AnyCancellable>()

    /// Trailing-debounce timers per persistence key. Typing a note mutates the whole
    /// `notes` array on every keystroke; without this each keystroke would JSON-encode
    /// the entire collection and write UserDefaults on the main thread, so typing
    /// latency grew with note count. We now coalesce writes to ~0.5 s after the last
    /// edit. Pending writes are flushed when the panel closes so nothing is lost.
    private var persistWork: [String: DispatchWorkItem] = [:]

    private func schedulePersist(_ key: String, delay: TimeInterval = 0.5,
                                 _ persist: @escaping (NotchViewModel) -> Void) {
        persistWork[key]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.persistWork[key] = nil
            persist(self)
        }
        persistWork[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Immediately run any pending debounced writes (called when the panel closes), so
    /// an edit made in the last half-second can't be lost if the app is quit right after.
    private func flushPendingPersists() {
        let pending = persistWork
        persistWork.removeAll()
        for (_, work) in pending { work.perform() }
    }

    init() {
        loadNotes()
        loadNoteFolders()
        loadWebsites()
        loadMood()
        loadAmbient()
        observeOverlays()
    }

    /// When the right-click glass menu or the add-tab gallery closes, resume normal
    /// auto-close: schedule a collapse so an overlay dismissed with the pointer
    /// already off the panel doesn't leave it stuck open. If the pointer is still
    /// over the panel, the hover that resumes once the overlay disappears cancels this.
    private func observeOverlays() {
        for isPresented in [GlassMenuController.shared.$isPresented.eraseToAnyPublisher(),
                            AddTabGalleryController.shared.$isPresented.eraseToAnyPublisher()] {
            isPresented
                .dropFirst()
                .removeDuplicates()
                .filter { !$0 }
                .sink { [weak self] _ in self?.scheduleClose() }
                .store(in: &cancellables)
        }
    }

    // MARK: - Ambient

    private func loadAmbient() {
        // Restore the last volume first, then the scene — assigning the scene fires
        // `didSet`, which resumes playback of whatever was playing when we quit.
        if defaults.object(forKey: "notch.ambientVolume") != nil {
            ambientVolume = defaults.double(forKey: "notch.ambientVolume")
        }
        if let raw = defaults.string(forKey: "notch.ambientScene"),
           let scene = AmbientScene(rawValue: raw) {
            ambientScene = scene
        }
    }

    // MARK: - Mood board

    /// Adds a mood item centered near the drop point (normalized 0...1).
    func addMood(_ kind: MoodItem.Kind, content: String, title: String, at point: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
        var item = MoodItem(kind: kind, content: content, title: title)
        item.x = min(max(point.x, 0.05), 0.95)
        item.y = min(max(point.y, 0.05), 0.95)
        // A gentle random tilt so freeform items feel hand-placed.
        item.rotation = Double.random(in: -5...5)
        moodItems.append(item)
    }

    func addMoodFile(url: URL, at point: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
        addMood(.file, content: url.path, title: url.lastPathComponent, at: point)
    }

    func addMoodLink(_ raw: String, at point: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let probe = MoodItem(kind: .link, content: trimmed)
        addMood(.link, content: trimmed, title: probe.host, at: point)
    }

    func addMoodNote(_ text: String = "", at point: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
        addMood(.note, content: text, title: "", at: point)
    }

    func removeMood(_ id: UUID) {
        moodItems.removeAll { $0.id == id }
    }

    /// Mutates a single mood item in place (used by the note appearance menu).
    func updateMood(_ id: UUID, _ change: (inout MoodItem) -> Void) {
        guard let idx = moodItems.firstIndex(where: { $0.id == id }) else { return }
        change(&moodItems[idx])
    }

    /// Duplicates an item, offsetting it slightly so it doesn't sit exactly on top.
    func duplicateMood(_ id: UUID) {
        guard let source = moodItems.first(where: { $0.id == id }) else { return }
        var copy = source
        copy.id = UUID()
        copy.x = min(source.x + 0.04, 0.97)
        copy.y = min(source.y + 0.04, 0.97)
        moodItems.append(copy)
    }

    /// Moves a freeform item to a new normalized position.
    func moveMood(_ id: UUID, to point: CGPoint) {
        guard let idx = moodItems.firstIndex(where: { $0.id == id }) else { return }
        moodItems[idx].x = min(max(point.x, 0.03), 0.97)
        moodItems[idx].y = min(max(point.y, 0.03), 0.97)
    }

    /// Binding to a note item's text for inline editing.
    func moodNoteBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { self.moodItems.first(where: { $0.id == id })?.content ?? "" },
            set: { newValue in
                guard let idx = self.moodItems.firstIndex(where: { $0.id == id }) else { return }
                self.moodItems[idx].content = newValue
            }
        )
    }

    // MARK: - Notes

    func addNote(inFolder folderID: UUID? = nil) {
        var note = NoteItem()
        note.folderID = folderID
        notes.insert(note, at: 0)
        focusedNoteID = note.id
    }

    /// Opens a second note beside the one being edited. Creates a fresh note in the
    /// same book as the focused note and pins it to the secondary slot, growing the
    /// editor into the big canvas so both notes have room side-by-side.
    func openSecondNote() {
        guard let primaryID = focusedNoteID,
              let primary = notes.first(where: { $0.id == primaryID }) else { return }
        var note = NoteItem()
        note.folderID = primary.folderID
        notes.insert(note, at: 0)
        secondaryNoteID = note.id
        noteExpanded = true
    }

    /// Closes the side-by-side second note (leaves it in the list; doesn't delete).
    func closeSecondNote() {
        secondaryNoteID = nil
    }

    func deleteNote(_ note: NoteItem) {
        // Drop the note's photos from disk so the store doesn't accumulate orphans.
        for image in note.images { NoteImageStore.delete(image) }
        notes.removeAll { $0.id == note.id }
        if secondaryNoteID == note.id {
            secondaryNoteID = nil
        }
        if focusedNoteID == note.id {
            // Promote the side note into the main slot if one is open, so the editor
            // stays up rather than dropping back to the board.
            if let promoted = secondaryNoteID {
                focusedNoteID = promoted
                secondaryNoteID = nil
            } else {
                focusedNoteID = nil
                noteExpanded = false
            }
        }
    }

    /// Leaves the full editor, collapsing the note back into the card list and
    /// dropping the expanded canvas so the list isn't shown blown up.
    func closeNoteEditor() {
        focusedNoteID = nil
        secondaryNoteID = nil
        noteExpanded = false
    }

    // MARK: - Note rename + checklist

    /// Binding to a note's custom title. Reading gives the current custom name (or
    /// empty); writing a blank clears it so the title falls back to the first line.
    func noteTitleBinding(_ noteID: UUID) -> Binding<String> {
        Binding(
            get: { self.notes.first(where: { $0.id == noteID })?.customTitle ?? "" },
            set: { newValue in
                guard let idx = self.notes.firstIndex(where: { $0.id == noteID }) else { return }
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                self.notes[idx].customTitle = trimmed.isEmpty ? nil : newValue
                self.notes[idx].modified = Date()
            }
        )
    }

    /// The checklist for a note (empty when it has none yet).
    func checklist(for noteID: UUID) -> [ChecklistItem] {
        notes.first(where: { $0.id == noteID })?.checklist ?? []
    }

    func addChecklistItem(to noteID: UUID) {
        guard let idx = notes.firstIndex(where: { $0.id == noteID }) else { return }
        notes[idx].checklist = (notes[idx].checklist ?? []) + [ChecklistItem()]
        notes[idx].modified = Date()
    }

    func toggleChecklistItem(_ itemID: UUID, in noteID: UUID) {
        guard let idx = notes.firstIndex(where: { $0.id == noteID }),
              let item = notes[idx].checklist?.firstIndex(where: { $0.id == itemID }) else { return }
        notes[idx].checklist?[item].done.toggle()
        notes[idx].modified = Date()
    }

    func deleteChecklistItem(_ itemID: UUID, in noteID: UUID) {
        guard let idx = notes.firstIndex(where: { $0.id == noteID }) else { return }
        notes[idx].checklist?.removeAll { $0.id == itemID }
        notes[idx].modified = Date()
    }

    /// Binding to a single checklist item's text for inline editing.
    func checklistItemBinding(_ itemID: UUID, in noteID: UUID) -> Binding<String> {
        Binding(
            get: {
                self.notes.first(where: { $0.id == noteID })?
                    .checklist?.first(where: { $0.id == itemID })?.text ?? ""
            },
            set: { newValue in
                guard let idx = self.notes.firstIndex(where: { $0.id == noteID }),
                      let item = self.notes[idx].checklist?.firstIndex(where: { $0.id == itemID }) else { return }
                self.notes[idx].checklist?[item].text = newValue
                self.notes[idx].modified = Date()
            }
        )
    }

    /// Notes filed in a given book (or the loose notes when `folderID` is nil).
    func notes(inFolder folderID: UUID?) -> [NoteItem] {
        notes.filter { $0.folderID == folderID }
    }

    // MARK: - Note images (inline)

    /// The note's inline body. Notes written before inline images (`richBody ==
    /// nil`) migrate on read: their plain `text` becomes one text run and any
    /// legacy photo strip is appended as image cards at the end.
    func noteBody(for noteID: UUID) -> [NoteRun] {
        guard let note = notes.first(where: { $0.id == noteID }) else { return [] }
        if let body = note.richBody { return body }
        var runs: [NoteRun] = []
        if !note.text.isEmpty { runs.append(.text(note.text)) }
        for image in note.images { runs.append(.image(image)) }
        return runs
    }

    /// Persists an edited inline body, keeping `text` (plain-text projection used
    /// for the title/preview) and `images` (used by the card header + deletion)
    /// in sync, and pruning image files the note no longer references.
    func updateNoteBody(_ noteID: UUID, runs: [NoteRun]) {
        guard let idx = notes.firstIndex(where: { $0.id == noteID }) else { return }
        let before = referencedImageFilenames(notes[idx])
        notes[idx].richBody = runs
        notes[idx].text = runs.compactMap { if case .text(let s) = $0 { return s } else { return nil } }.joined()
        notes[idx].images = runs.compactMap { if case .image(let i) = $0 { return i } else { return nil } }
        notes[idx].modified = Date()
        for filename in before.subtracting(referencedImageFilenames(notes[idx])) {
            NoteImageStore.deleteFile(named: filename)
        }
    }

    /// Every image filename a note points at, across both its body and the legacy
    /// `images` array — used to spot files that dropped out after an edit.
    private func referencedImageFilenames(_ note: NoteItem) -> Set<String> {
        var set = Set(note.images.map(\.filename))
        for run in note.richBody ?? [] {
            if case .image(let image) = run { set.insert(image.filename) }
        }
        return set
    }

    // MARK: - Note books (folders)

    @discardableResult
    func addNoteFolder(named name: String = "New Folder") -> UUID {
        let folder = NoteFolder(name: name)
        noteFolders.insert(folder, at: 0)
        return folder.id
    }

    /// Deletes a book but keeps its notes — they fall back to the loose top level
    /// rather than being destroyed with the book.
    func deleteNoteFolder(_ id: UUID) {
        for i in notes.indices where notes[i].folderID == id {
            notes[i].folderID = nil
        }
        noteFolders.removeAll { $0.id == id }
        if openNoteFolderID == id { openNoteFolderID = nil }
    }

    func moveNote(_ noteID: UUID, toFolder folderID: UUID?) {
        guard let idx = notes.firstIndex(where: { $0.id == noteID }) else { return }
        notes[idx].folderID = folderID
    }

    /// Binding to a book's name for inline editing.
    func noteFolderNameBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { self.noteFolders.first(where: { $0.id == id })?.name ?? "" },
            set: { newValue in
                guard let idx = self.noteFolders.firstIndex(where: { $0.id == id }) else { return }
                self.noteFolders[idx].name = newValue
            }
        )
    }


    // MARK: - Hover driven open / close

    /// The display that owns the notch (or the main screen as a fallback) — used to
    /// locate the top edge for the pointer-proximity gate below.
    private var notchScreen: NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main
    }

    /// True only when the pointer is within the thin band at the very top of the
    /// notch display — i.e. genuinely over the notch, not down over a window's
    /// toolbar. SwiftUI's `.onHover` region tracks the pill view's rectangular frame
    /// and ignores the narrow `CenteredHoverShape`, so the hover event alone can fire
    /// from well below the notch; gating the actual open on the real pointer Y keeps
    /// the trigger pinned to the notch regardless of that quirk.
    private var pointerOverNotch: Bool {
        guard let screen = notchScreen else { return true }
        let fromTop = screen.frame.maxY - NSEvent.mouseLocation.y
        let band = max(collapsedSize.height, 1) + Metrics.collapsedTriggerSlack
        return fromTop >= 0 && fromTop <= band
    }

    /// How often the open-tracking poll samples the pointer position while the
    /// cursor is inside the hover region but we're waiting for it to settle over the
    /// notch. Fine enough to feel instant, coarse enough to be free.
    private let openPollInterval: TimeInterval = 0.05
    /// Consecutive over-notch poll ticks so far; the panel opens once this reaches
    /// `openHoverDelay`. Reset whenever the pointer drifts out of the notch band.
    private var overNotchTicks = 0

    func setHover(_ hovering: Bool) {
        closeWorkItem?.cancel()
        openWorkItem?.cancel()
        if hovering {
            guard !isOpen else { return }
            // The hover region can reach well below the notch (SwiftUI's `.onHover`
            // ignores the narrow trigger shape — see `pointerOverNotch`), and it only
            // fires on region-*entry*, so a one-shot check would miss the moment the
            // cursor actually reaches the notch. Poll the real pointer position and
            // open only once it's settled over the notch for the dwell — this is what
            // keeps the panel from deploying down at a browser's toolbar.
            overNotchTicks = 0
            pollOpen()
        } else {
            // A presented glass menu (any right-click menu) or the add-tab gallery
            // (the "+" picker) drops a full-window catcher over the panel body, which
            // steals this hover and fires a phantom leave. While either is up it — not
            // this hover — owns the close decision (its position-aware catcher tracks
            // whether the pointer is still over the notch, and `observeOverlays`
            // schedules a close the instant it's dismissed). Ignoring the phantom
            // leave here keeps the notch from collapsing out from under the overlay.
            // Cancelling the work items above already killed any pending close.
            if GlassMenuController.shared.isPresented
                || AddTabGalleryController.shared.isPresented { return }
            scheduleClose()
        }
    }

    /// One tick of the open-tracking loop: accrue dwell while the pointer is over the
    /// notch, reset it otherwise, and open once the dwell is met. Re-arms itself via
    /// `openWorkItem`, which `setHover(false)` cancels to stop the loop on leave.
    private func pollOpen() {
        guard !isOpen else { return }
        if pointerOverNotch {
            overNotchTicks += 1
            if Double(overNotchTicks) * openPollInterval >= openHoverDelay {
                isOpen = true
                return
            }
        } else {
            overNotchTicks = 0
        }
        let work = DispatchWorkItem { [weak self] in self?.pollOpen() }
        openWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + openPollInterval, execute: work)
    }

    /// Schedules the panel to collapse after the close delay, unless the context
    /// menu is (re)opened before the timer fires.
    private func scheduleClose() {
        closeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            // Leaving collapses the panel and takes any overlay with it.
            GlassMenuController.shared.dismiss()
            AddTabGalleryController.shared.dismiss()
            withAnimation(Metrics.closeSpring) {
                self?.isOpen = false
                self?.showSettings = false
                // Just hide it — closing without acknowledging leaves it unseen so it
                // returns on the next app run until the user actually reads it.
                self?.showWhatsNew = false
                self?.openFolderID = nil
                self?.openNoteFolderID = nil
                self?.moodExpanded = false
                self?.mapExpanded = false
                self?.noteExpanded = false
            }
        }
        closeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + SettingsStore.shared.closeDelay, execute: work)
    }

    /// Keep the panel open while the user is actively interacting (e.g. dragging a file in).
    func keepOpen() {
        closeWorkItem?.cancel()
        openWorkItem?.cancel()
        isOpen = true
    }

    // MARK: - Websites & folders

    /// Builds a website from a raw string, deriving a readable title.
    private func makeSite(from urlString: String) -> WebsiteItem {
        let probe = WebsiteItem(title: "", urlString: urlString)
        let title = probe.host.isEmpty ? urlString : probe.host.capitalized
        return WebsiteItem(title: title, urlString: urlString)
    }

    func addSite(_ urlString: String, toFolder folderID: UUID?) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let site = makeSite(from: trimmed)
        if let folderID, let idx = websiteFolders.firstIndex(where: { $0.id == folderID }) {
            websiteFolders[idx].sites.append(site)
        } else {
            websites.append(site)
        }
    }

    func removeSite(_ siteID: UUID, fromFolder folderID: UUID?) {
        if let folderID, let idx = websiteFolders.firstIndex(where: { $0.id == folderID }) {
            websiteFolders[idx].sites.removeAll { $0.id == siteID }
        } else {
            websites.removeAll { $0.id == siteID }
        }
    }

    @discardableResult
    func addFolder(named name: String = "New Folder") -> UUID {
        let folder = WebsiteFolder(name: name)
        websiteFolders.insert(folder, at: 0)
        return folder.id
    }

    func deleteFolder(_ id: UUID) {
        websiteFolders.removeAll { $0.id == id }
        if openFolderID == id { openFolderID = nil }
    }

    /// Finds a site by id anywhere (loose or in a folder) and moves it into the
    /// given folder. Used by drag-and-drop.
    func moveSite(id siteID: UUID, toFolder folderID: UUID) {
        if let site = websites.first(where: { $0.id == siteID }) {
            moveSite(site, toFolder: folderID)
            return
        }
        for folder in websiteFolders {
            if let site = folder.sites.first(where: { $0.id == siteID }) {
                moveSite(site, toFolder: folderID)
                return
            }
        }
    }

    /// Moves a loose (or already-filed) site into the given folder.
    func moveSite(_ site: WebsiteItem, toFolder folderID: UUID) {
        websites.removeAll { $0.id == site.id }
        for i in websiteFolders.indices {
            websiteFolders[i].sites.removeAll { $0.id == site.id }
        }
        if let idx = websiteFolders.firstIndex(where: { $0.id == folderID }) {
            websiteFolders[idx].sites.append(site)
        }
    }

    /// Binding to a folder's name for inline editing.
    func folderNameBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { self.websiteFolders.first(where: { $0.id == id })?.name ?? "" },
            set: { newValue in
                guard let idx = self.websiteFolders.firstIndex(where: { $0.id == id }) else { return }
                self.websiteFolders[idx].name = newValue
            }
        )
    }

    // MARK: - Drop shelf

    func addDropped(urls: [URL]) {
        let new = urls
            .filter { url in !droppedItems.contains(where: { $0.url == url }) }
            .map { DroppedItem(url: $0) }
        guard !new.isEmpty else { return }
        droppedItems.append(contentsOf: new)
    }

    func removeDropped(_ item: DroppedItem) {
        droppedItems.removeAll { $0.id == item.id }
    }

    func clearDropped() {
        droppedItems.removeAll()
    }

    // MARK: - Persistence

    private func persistNotes() {
        if let data = try? JSONEncoder().encode(notes) {
            defaults.set(data, forKey: "notch.notes")
        }
    }

    private func loadNotes() {
        if let data = defaults.data(forKey: "notch.notes"),
           let saved = try? JSONDecoder().decode([NoteItem].self, from: data) {
            notes = saved
        } else if let legacy = defaults.string(forKey: "notch.note"), !legacy.isEmpty {
            notes = [NoteItem(text: legacy)]
        }
    }

    private func persistNoteFolders() {
        if let data = try? JSONEncoder().encode(noteFolders) {
            defaults.set(data, forKey: "notch.noteFolders")
        }
    }

    private func loadNoteFolders() {
        if let data = defaults.data(forKey: "notch.noteFolders"),
           let saved = try? JSONDecoder().decode([NoteFolder].self, from: data) {
            noteFolders = saved
        }
    }

    private func persistWebsites() {
        if let data = try? JSONEncoder().encode(websites) {
            defaults.set(data, forKey: "notch.websites")
        }
    }

    private func loadWebsites() {
        if let data = defaults.data(forKey: "notch.websites"),
           let saved = try? JSONDecoder().decode([WebsiteItem].self, from: data) {
            websites = saved
        } else {
            websites = [
                WebsiteItem(title: "Apple", urlString: "https://www.apple.com"),
                WebsiteItem(title: "GitHub", urlString: "https://github.com"),
                WebsiteItem(title: "YouTube", urlString: "https://youtube.com")
            ]
        }

        if let data = defaults.data(forKey: "notch.websiteFolders"),
           let saved = try? JSONDecoder().decode([WebsiteFolder].self, from: data) {
            websiteFolders = saved
        }
    }

    private func persistWebsiteFolders() {
        if let data = try? JSONEncoder().encode(websiteFolders) {
            defaults.set(data, forKey: "notch.websiteFolders")
        }
    }

    private func persistMood() {
        if let data = try? JSONEncoder().encode(moodItems) {
            defaults.set(data, forKey: "notch.mood")
        }
    }

    private func loadMood() {
        if let data = defaults.data(forKey: "notch.mood"),
           let saved = try? JSONDecoder().decode([MoodItem].self, from: data) {
            moodItems = saved
        }
    }
}
