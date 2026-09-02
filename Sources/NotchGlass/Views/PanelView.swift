import SwiftUI

/// The expanded glass panel: a top bar (tabs + gear) and the active tab body.
struct PanelView: View {
    @EnvironmentObject private var vm: NotchViewModel
    @EnvironmentObject private var settings: SettingsStore

    /// Tabs built as dark surfaces (media artwork backdrop, the Fuel/Clock panes
    /// that pin their own dark appearance, the Map, the Mood board). On the Light
    /// theme these keep a dark appearance so their white-on-dark content, glass
    /// buttons and materials stay legible rather than washing out on the pale panel.
    private static let darkTabs: Set<NotchTab> = [.media, .fuel, .clock, .map, .weather, .mood, .calendar, .scratch]

    /// The appearance the tab content is pinned to. On Light, panel-native tabs and
    /// Settings go light (dark-on-light, light-frosted glass); the dark-native tabs
    /// above stay dark so their glass frosts dark and white icons keep contrast.
    private var contentColorScheme: ColorScheme {
        guard Theme.isLight else { return .dark }
        if vm.showSettings { return .light }
        return Self.darkTabs.contains(vm.selectedTab) ? .dark : .light
    }

    /// The Mood board / Map "bigger notch" mode overrides the normal panel size.
    private var isMoodBig: Bool { vm.isBigCanvas }

    private var bodyWidth: CGFloat {
        isMoodBig ? Metrics.moodExpandedWidth : CGFloat(settings.panelWidth)
    }

    private var bodyHeight: CGFloat {
        isMoodBig ? Metrics.moodExpandedHeight : Metrics.bodyHeight(for: vm.selectedTab, showingSettings: vm.showSettings, showingWhatsNew: vm.showWhatsNew, whatsNewChanges: WhatsNew.visibleChangeCount, settingsCategory: vm.settingsCategory, mediaLyrics: settings.mediaLyrics)
    }

    var body: some View {
        Group {
            if vm.showWhatsNew {
                // Rendered as the panel's own content (not a floating overlay) so it
                // welds into the notch and the body grows to fit the whole list.
                WhatsNewView(releases: WhatsNew.notesToShow) { vm.dismissWhatsNew() }
                    // On the Light theme, sit on a dark stage like the other dark-native
                    // panes so its white-on-dark card stays legible.
                    .background {
                        if Theme.isLight {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(LinearGradient(colors: [Color(white: 0.14), Color(white: 0.10)],
                                                     startPoint: .top, endPoint: .bottom))
                        }
                    }
            } else if vm.showSettings {
                NotchSettingsView()
            } else {
                VStack(spacing: Spacing.base) {
                    // Kept above the tab body in the hit-test order: Mood board tiles
                    // are positioned freely and a tile near the top overflows upward
                    // past the (visually clipped) board, so without this its invisible
                    // hit area sits over the tab bar and steals clicks — e.g. tapping
                    // Home would open whatever tile is pinned up there.
                    TopBar()
                        .zIndex(1)
                    Group {
                        switch vm.selectedTab {
                        case .media:   MediaTabView()
                        case .mood:    MoodTabView()
                        case .drop:    DropTabView()
                        case .website: WebsiteTabView()
                        case .note:    NoteTabView()
                        case .ambient: AmbientTabView()
                        case .map:     MapTabView()
                        case .weather: WeatherTabView()
                        case .clock:   ClockTabView()
                        case .calendar: CalendarTabView()
                        case .scratch: AIScratchTabView()
                        case .fuel:    FuelTabView()
                        case .record:  RecordTabView()
                        case .deck:    DeckTabView()
                        case .now:     NowTabView()
                        case .countdown: CountdownTabView()
                        case .shortcuts: ShortcutsTabView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // The media / data / board tabs are built as dark surfaces (they
                    // pin their own dark appearance and use white-on-dark fills). On
                    // the Light theme they'd be illegible on the pale panel, so give
                    // them a dark "stage" card to sit on — a deliberate dark island
                    // below the light chrome, rather than half-broken light versions.
                    .background {
                        // Media paints its own full artwork backdrop; the other
                        // dark-native tabs get a dark "stage" card on the light panel.
                        if Theme.isLight && Self.darkTabs.contains(vm.selectedTab)
                            && vm.selectedTab != .media {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(LinearGradient(colors: [Color(white: 0.14), Color(white: 0.10)],
                                                     startPoint: .top, endPoint: .bottom))
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
        // Generous insets so nothing hugs the welded top edge or the sides.
        // A little extra up top to clear the flared corners.
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.xl)
        .padding(.bottom, Spacing.xl)
        // Top-aligned: the panel welds to the screen's top edge, so content hangs
        // from the top. If a tab's content ever exceeds the body height it spills
        // downward (off the bottom) rather than centering and shoving the tab bar
        // above the screen edge where it can't be reached.
        .frame(width: bodyWidth, height: bodyHeight, alignment: .top)
        // Large, cursor-clear destination readout shown while dragging — it sits in
        // the middle of the panel, below the drag image, and updates live as the
        // hovered tabs spring-load.
        .overlay {
            if vm.dragActive && !vm.showSettings {
                DragDestinationChip(tab: vm.selectedTab, accent: settings.accent)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(Metrics.openSpring, value: vm.dragActive)
        .foregroundStyle(Theme.primaryText)
        // Pin the panel subtree's appearance so Liquid Glass buttons and system
        // materials frost the right way — light for the light chrome, dark for the
        // media/data/board tabs — regardless of the user's system appearance.
        .environment(\.colorScheme, contentColorScheme)
        // The surface, corner shape and shadow are drawn by the morphing notch body
        // in RootView, which clips this content as it expands.
    }
}

/// Tab switcher on the left, settings menu on the right.
private struct TopBar: View {
    @EnvironmentObject private var vm: NotchViewModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var glassMenu: GlassMenuController
    @EnvironmentObject private var gallery: AddTabGalleryController

    /// Live frames of each tab within the strip, so a drag hovering the strip can
    /// be mapped to whichever tab sits under the pointer.
    @State private var tabFrames: [NotchTab: CGRect] = [:]
    /// The tab a hovering drag is currently charging to spring-load onto.
    @State private var springTab: NotchTab?
    @State private var springTask: Task<Void, Never>?
    /// 0→1 charge that fills the arming tab's ring over `springLoadDelay`.
    @State private var charge: CGFloat = 0
    /// The "+" button's frame in window coordinates, so the add menu drops from it.
    @State private var addFrame: CGRect = .zero
    /// The tab currently being dragged to reorder. Its neighbours shuffle around it
    /// as the pointer moves; the tab itself stays in its glass slot (see the drag
    /// modifiers below for why it isn't free-floated).
    @State private var draggingTab: NotchTab?
    /// Which category's tabs the segmented row is showing. Only meaningful once
    /// the strip is categorized (more than `Metrics.tabCategoryThreshold` tabs).
    @State private var selectedCategory: NotchTab.Category = .media

    /// Past the threshold the flat strip is swapped for a segmented category row.
    private var isCategorized: Bool {
        settings.enabledTabs.count > Metrics.tabCategoryThreshold
    }

    /// The categories that actually have an enabled tab, in canonical order.
    private var presentCategories: [NotchTab.Category] {
        NotchTab.Category.allCases.filter { cat in
            settings.enabledTabs.contains { $0.category == cat }
        }
    }

    /// The tabs the strip renders: all of them when flat, or just the picked
    /// category's tabs (in their enabled order) once categorized.
    private var visibleTabs: [NotchTab] {
        guard isCategorized else { return settings.enabledTabs }
        return settings.enabledTabs.filter { $0.category == selectedCategory }
    }

    var body: some View {
        // Always a single row so the bar never eats vertical height. When
        // categorized the row holds the category pills, and the picked category
        // expands its tabs inline to its right (see `tabStrip`).
        HStack(spacing: Spacing.sm) {
            tabStrip
            Spacer()
            gearButton
        }
        // Keep the category selection in step with the active tab, and never leave
        // it pointing at a category that no longer has any enabled tabs.
        .onAppear { selectedCategory = vm.selectedTab.category }
        .onChange(of: vm.selectedTab) { _, tab in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                selectedCategory = tab.category
            }
        }
        .onChange(of: settings.enabledTabs) { _, _ in
            if !presentCategories.contains(selectedCategory) {
                selectedCategory = presentCategories.first ?? .media
            }
        }
    }

    /// The horizontal glass row. Flat below the category threshold (every tab in a
    /// line); once categorized it becomes a single row of category pills where the
    /// picked category expands its tabs inline to its right — so it never grows to
    /// a second row and the panel stays short.
    private var tabStrip: some View {
        GlassEffectContainer(spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                if isCategorized {
                    ForEach(presentCategories) { cat in
                        categoryPill(cat)
                        // The selected category unfurls its tabs right after its
                        // pill, nested in a recessed tray so they read as that
                        // category's contents — not more top-level chips.
                        if cat == selectedCategory {
                            HStack(spacing: Spacing.s) {
                                ForEach(visibleTabs) { tab in tabButton(for: tab, compact: true) }
                            }
                            .padding(.horizontal, Spacing.s)
                            .padding(.vertical, Spacing.xs)
                            .background(Capsule(style: .continuous).fill(Color.white.opacity(0.08)))
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                        }
                    }
                } else {
                    ForEach(visibleTabs) { tab in tabButton(for: tab) }
                }

                // The "+" opens a menu of the tabs not yet in the bar (Fuel, …).
                if !settings.addableTabs.isEmpty {
                    addButton
                }
            }
        }
        .coordinateSpace(name: "tabstrip")
        .onPreferenceChange(TabFrameKey.self) { tabFrames = $0 }
        // A single drop delegate over the whole strip. Per-tab `.onDrop` only
        // reports a bool ("is it over me"), which is fragile across a row of
        // tiny targets; a `DropDelegate` reports the live pointer *location*, so
        // we can map it to the tab under the cursor and spring-load it — letting
        // you scrub through tabs with an item held.
        .onDrop(of: [.fileURL, .url, .text],
                delegate: TabStripDropDelegate(
                    tabAt: { point in tabFrames.first(where: { $0.value.contains(point) })?.key },
                    onHover: { hover($0) }
                ))
    }

    /// One tab button plus all the drag-to-reorder / spring-load plumbing. Shared
    /// by the flat strip and the inline tabs of the selected category.
    @ViewBuilder
    private func tabButton(for tab: NotchTab, compact: Bool = false) -> some View {
        TabButton(
            tab: tab,
            isSelected: vm.selectedTab == tab,
            arming: springTab == tab && vm.selectedTab != tab,
            charge: springTab == tab ? charge : 0,
            accent: settings.accent,
            compact: compact
        ) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                vm.selectedTab = tab
            }
        }
        .background {
            GeometryReader { geo in
                Color.clear.preference(
                    key: TabFrameKey.self,
                    value: [tab: geo.frame(in: .named("tabstrip"))]
                )
            }
        }
        // Drag-to-reorder: the picked-up tab stays put in the glass strip and its
        // neighbours shuffle around it as the pointer moves. We deliberately do NOT
        // free-float it with an `.offset` — a glass child offset out of its slot
        // inside a GlassEffectContainer (and the whole panel is clipped by the
        // morphing notch body in RootView) detaches from the unified glass render
        // and disappears, which looked like the tab "leaving the notch". A scale +
        // shadow gives the picked-up feel without ever moving it out of bounds.
        .scaleEffect(draggingTab == tab ? 1.1 : 1)
        .shadow(color: draggingTab == tab ? .black.opacity(0.45) : .clear, radius: 7, y: 2)
        .zIndex(draggingTab == tab ? 1 : 0)
        .simultaneousGesture(reorderGesture(for: tab))
        // Optional (non-default) tabs can be taken back off the bar.
        .glassContextMenu { removeMenu(for: tab) }
        .transition(.scale(scale: 0.6).combined(with: .opacity))
    }

    /// The settings gear, pinned to the top-right of the bar in both layouts.
    private var gearButton: some View {
        Button {
            withAnimation(Metrics.openSpring) { vm.showSettings = true }
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .blackGlass(in: Circle(), interactive: true)
        .linkCursor()
    }

    /// One category pill in the single-row categorized strip. Tapping it unfurls
    /// that category's tabs inline to its right; it does not itself switch tabs.
    private func categoryPill(_ cat: NotchTab.Category) -> some View {
        let selected = selectedCategory == cat
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                selectedCategory = cat
            }
        } label: {
            // Always icon + label + a disclosure chevron, so a category always reads
            // as a labelled, expandable header — visually unlike the bare icon tabs
            // in its tray. The chevron points right when closed, down when open.
            HStack(spacing: Spacing.s) {
                Image(systemName: cat.symbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(cat.title)
                    .font(.system(size: 11, weight: .bold))
                    .fixedSize()
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(selected ? 90 : 0))
                    .opacity(0.7)
            }
            .foregroundStyle(selected ? .white : Theme.secondaryText)
            .frame(height: 28)
            .padding(.horizontal, Spacing.base)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .blackGlass(
            in: Capsule(style: .continuous),
            interactive: true, tint: selected ? settings.accent.opacity(0.55) : nil
        )
        .linkCursor()
    }

    /// The "+" button — sits at the end of the tab strip and drops the searchable
    /// add-tab gallery of the tabs that aren't currently shown.
    private var addButton: some View {
        Button {
            presentAddGallery()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .blackGlass(in: Capsule(), interactive: true)
        .notchHover(scale: 1.12)
        .accessibilityLabel("Add tab")
        // Track the button's window-space frame so the menu drops from just below it.
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { addFrame = geo.frame(in: .global) }
                    .onChange(of: geo.frame(in: .global)) { _, f in addFrame = f }
            }
        }
    }

    /// Presents the searchable add-tab gallery anchored under the "+" button. It
    /// replaces the old flat menu so the picker scales to a large (and growing) set
    /// of tabs — see ``AddTabGalleryHost``.
    private func presentAddGallery() {
        gallery.present(at: CGPoint(x: addFrame.minX, y: addFrame.maxY + 4))
    }

    /// Right-click menu for a tab: any tab can be removed, down to the last one.
    private func removeMenu(for tab: NotchTab) -> [GlassMenuItem] {
        guard settings.isRemovable(tab) else { return [] }
        return [GlassMenuItem.item("Remove \(tab.title)", systemImage: "minus.circle", destructive: true) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                if vm.selectedTab == tab {
                    vm.selectedTab = settings.enabledTabs.first { $0 != tab } ?? .media
                }
                settings.removeTab(tab)
            }
        }]
    }

    // MARK: - Drag to reorder

    /// A drag that reorders `settings.enabledTabs` live. `minimumDistance` lets a
    /// plain click still fall through to the tab's own switch action.
    private func reorderGesture(for tab: NotchTab) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named("tabstrip"))
            .onChanged { value in
                if draggingTab != tab {
                    draggingTab = tab
                    vm.keepOpen()
                }
                updateOrder(dragging: tab, pointerX: value.location.x)
            }
            .onEnded { _ in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    draggingTab = nil
                }
            }
    }

    /// Moves `tab` to the slot the pointer is currently over, based on the other
    /// tabs' live centers.
    private func updateOrder(dragging tab: NotchTab, pointerX: CGFloat) {
        // Reorder only within what's on screen — when categorized that's the
        // picked category's tabs, otherwise the whole strip (`visibleTabs`
        // returns everything). Tabs in other categories keep their slots.
        let visible = visibleTabs
        let others = visible.filter { $0 != tab }
        var target = 0
        for other in others {
            guard let center = tabFrames[other]?.midX, center < pointerX else { break }
            target += 1
        }
        guard let current = visible.firstIndex(of: tab), current != target else { return }
        var reordered = visible
        reordered.remove(at: current)
        reordered.insert(tab, at: min(target, reordered.count))
        // Splice the reordered subset back into the full list, leaving every tab
        // outside `visible` exactly where it was.
        let subset = Set(visible)
        var next = reordered.makeIterator()
        let newOrder = settings.enabledTabs.map { subset.contains($0) ? (next.next() ?? $0) : $0 }
        guard newOrder != settings.enabledTabs else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
            settings.enabledTabs = newOrder
        }
    }

    /// Called continuously as a drag moves over the strip with the tab currently
    /// under the pointer (or nil in the gaps / off the strip). Restarts the
    /// spring-load timer whenever the hovered tab changes.
    private func hover(_ tab: NotchTab?) {
        vm.noteDrag(active: tab != nil)
        if tab != nil { vm.keepOpen() }
        // Still over the same tab: let the running timer keep charging.
        guard tab != springTab else { return }

        springTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { charge = 0 }
        springTab = tab

        // Only charge toward a tab that isn't already selected.
        guard let tab, tab != vm.selectedTab else { return }
        withAnimation(.linear(duration: Metrics.springLoadDelay)) { charge = 1 }
        springTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Metrics.springLoadDelay))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                vm.selectedTab = tab
            }
            springTab = nil
            charge = 0
        }
    }
}

/// Collects each tab's frame in the strip's coordinate space so a drag can be
/// hit-tested against them.
private struct TabFrameKey: PreferenceKey {
    static let defaultValue: [NotchTab: CGRect] = [:]
    static func reduce(value: inout [NotchTab: CGRect], nextValue: () -> [NotchTab: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Drives spring-loaded tab switching while a drag scrubs across the tab strip.
/// `onHover` fires with the tab under the pointer (or nil) as the drag moves; the
/// strip itself never consumes the drop (the real drop targets are the tab bodies).
private struct TabStripDropDelegate: DropDelegate {
    let tabAt: (CGPoint) -> NotchTab?
    let onHover: (NotchTab?) -> Void

    func validateDrop(info: DropInfo) -> Bool { true }
    func dropEntered(info: DropInfo) { onHover(tabAt(info.location)) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        onHover(tabAt(info.location))
        // A .copy proposal keeps the cursor friendly rather than flashing "no drop"
        // as the item passes over the strip.
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) { onHover(nil) }
    func performDrop(info: DropInfo) -> Bool { false }
}

/// The floating "where will this land" readout shown mid-panel during a drag.
private struct DragDestinationChip: View {
    let tab: NotchTab
    let accent: Color

    /// The tabs that actually take a dropped item; others just get switched to.
    private var acceptsDrop: Bool { tab == .drop || tab == .mood }

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: tab.symbol)
                .font(.system(size: 16, weight: .semibold))
            VStack(alignment: .leading, spacing: Spacing.hair) {
                Text(acceptsDrop ? "Drop into" : "Switch to")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.7))
                Text(tab.title)
                    .font(.system(size: 15, weight: .bold))
            }
        }
        // Always white — the chip floats on its own dark capsule, independent of
        // the panel theme.
        .foregroundStyle(.white)
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.base)
        .background { Capsule(style: .continuous).fill(Color.black.opacity(0.55)) }
        .overlay { Capsule(style: .continuous).strokeBorder(accent.opacity(0.85), lineWidth: 1.5) }
        .shadow(color: accent.opacity(0.5), radius: 16)
        .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
    }
}

private struct TabButton: View {
    let tab: NotchTab
    let isSelected: Bool
    /// True while a hovering drag is charging to spring-load this tab.
    let arming: Bool
    /// 0→1 fill of the arming ring, driven by the tab strip's spring-load timer.
    let charge: CGFloat
    let accent: Color
    /// Icon-only round mode used for the tabs nested under a category, so they read
    /// as sub-items rather than another labelled chip like the category pills.
    var compact: Bool = false
    let action: () -> Void

    /// True while the pointer is over this tab (drives the hover lift below).
    @State private var hovering = false

    /// The label only appears in the full (flat-strip) mode; compact category tabs
    /// stay icon-only.
    private var showsLabel: Bool { !compact && (isSelected || arming) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.s) {
                // While spring-loading, the icon becomes a dotted "thinking orb"
                // to signal the tab is charging; the ring overlay still carries
                // the 0→1 countdown.
                if arming {
                    ThinkingOrb(size: 16)
                } else {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 12, weight: .semibold))
                }
                // Reveal the tab's name beside its icon when the tab is the
                // focused one, or while a drag is hovering it — so the active /
                // destination tab is legible even with a drag image over the icon.
                if showsLabel {
                    Text(tab.title)
                        .font(.system(size: 11, weight: .semibold))
                        .fixedSize()
                }
            }
            .foregroundStyle(isSelected || arming ? .white : Theme.secondaryText)
            .frame(minWidth: compact ? 28 : 32)
            .frame(height: 28)
            .padding(.horizontal, showsLabel ? 10 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .blackGlass(
            in: Capsule(style: .continuous),
            interactive: true, tint: (isSelected || arming) ? accent.opacity(0.55) : nil
        )
        .shadow(color: accent.opacity(arming ? 0.7 : 0), radius: 8)
        // Charging ring: a faint track plus an accent arc that sweeps closed over
        // the spring-load delay, so it's obvious the tab is about to open under the
        // held document — and that moving away cancels it.
        .overlay {
            if arming {
                ZStack {
                    Capsule(style: .continuous)
                        .stroke(accent.opacity(0.25), lineWidth: 2)
                    Capsule(style: .continuous)
                        .trim(from: 0, to: charge)
                        .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }
        }
        // A small lift as it arms, springing back when the drag leaves. A gentler
        // lift + brighten also answers an ordinary pointer hover, so an unselected
        // tab visibly responds before you click it.
        .brightness(hovering && !isSelected && !arming ? 0.08 : 0)
        .scaleEffect(arming ? 1.12 : (hovering ? 1.06 : 1))
        .animation(.spring(response: 0.26, dampingFraction: 0.7), value: arming)
        .animation(.spring(response: 0.26, dampingFraction: 0.72), value: hovering)
        .onHover { hovering = $0 }
        .linkCursor()
    }
}
