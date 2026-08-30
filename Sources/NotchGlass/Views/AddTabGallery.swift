import SwiftUI
import AppKit

/// App-wide presenter for the add-tab gallery — the search-first picker the "+"
/// button opens instead of a flat dropdown, so the panel can scale to a large
/// (and growing) set of tabs. Mirrors ``GlassMenuController``: injected into the
/// environment, triggered from `TopBar`, rendered by a single ``AddTabGalleryHost``
/// mounted in RootView (above the panel body so it isn't clipped by the notch).
@MainActor
final class AddTabGalleryController: ObservableObject {
    static let shared = AddTabGalleryController()

    @Published var isPresented = false
    /// Window-space point the gallery drops from (just under the "+" button).
    @Published var anchor: CGPoint = .zero

    func present(at point: CGPoint) {
        anchor = point
        withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
            isPresented = true
        }
    }

    func dismiss() {
        withAnimation(.easeOut(duration: 0.14)) { isPresented = false }
    }
}

/// Renders the active add-tab gallery. One instance lives in RootView; it reads
/// ``AddTabGalleryController`` and draws a frosted card — search field, category
/// chips and a grid of tab tiles — anchored under the "+" button. It reuses the
/// same position-aware dismiss machinery as ``GlassMenuHost``: an off-card pointer
/// that settles drops the gallery, and only collapses the notch if the pointer has
/// also left the panel body.
struct AddTabGalleryHost: View {
    @EnvironmentObject private var gallery: AddTabGalleryController
    @EnvironmentObject private var vm: NotchViewModel
    @EnvironmentObject private var settings: SettingsStore

    /// Card footprint. Height is a ceiling — the card sizes to its content and the
    /// grid scrolls past it once there are enough tabs.
    private let cardWidth: CGFloat = 384
    private let maxCardHeight: CGFloat = 380

    @State private var leaveWork: DispatchWorkItem?
    @State private var lastLocation: CGPoint = .zero
    /// Whether the pointer has reached the card yet. Until it has, off-card hovers
    /// are ignored so a freshly opened gallery can't dismiss itself in the gap
    /// between the "+" button and the card (mirrors `GlassMenuHost.hasEnteredMenu`).
    @State private var hasEnteredCard = false

    var body: some View {
        GeometryReader { geo in
            if gallery.isPresented {
                ZStack(alignment: .topLeading) {
                    // Full-window catcher. The card sits on top, so events landing
                    // here mean the pointer is *off* the card. Tapping dismisses;
                    // the notch only collapses if the tap is off the panel too.
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { leave(inPanel: panelRect(in: geo.size).contains(lastLocation)) }
                        .onContinuousHover(coordinateSpace: .local) { phase in
                            switch phase {
                            case .active(let loc):
                                lastLocation = loc
                                guard hasEnteredCard else { return }
                                scheduleLeave(inPanel: panelRect(in: geo.size).contains(loc))
                            case .ended:
                                scheduleLeave(inPanel: false)
                            }
                        }

                    AddTabGalleryCard(
                        width: cardWidth,
                        maxHeight: maxCardHeight,
                        onHoverChange: { onCard in
                            if onCard { hasEnteredCard = true; cancelLeave(); vm.keepOpen() }
                        },
                        onPick: { gallery.dismiss() }
                    )
                    .frame(width: cardWidth)
                    .offset(x: clampedX(in: geo.size), y: clampedY(in: geo.size))
                    .transition(.scale(scale: 0.92, anchor: .topLeading).combined(with: .opacity))
                }
                .ignoresSafeArea()
                .onAppear { hasEnteredCard = false; vm.keepOpen() }
            }
        }
    }

    // MARK: - Dismiss / collapse coordination (parallels GlassMenuHost)

    private func scheduleLeave(inPanel: Bool) {
        cancelLeave()
        let work = DispatchWorkItem { leave(inPanel: inPanel) }
        leaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    private func cancelLeave() {
        leaveWork?.cancel()
        leaveWork = nil
    }

    private func leave(inPanel: Bool) {
        cancelLeave()
        gallery.dismiss()
        if inPanel { vm.keepOpen() } else { vm.setHover(false) }
    }

    /// The panel body's frame within the window — used to tell "off the card, still
    /// on the notch" from "off the notch entirely". Same computation as GlassMenuHost.
    private func panelRect(in size: CGSize) -> CGRect {
        let bodySize: CGSize
        if vm.isBigCanvas {
            bodySize = CGSize(width: Metrics.moodExpandedWidth, height: Metrics.moodExpandedHeight)
        } else {
            bodySize = CGSize(width: CGFloat(settings.panelWidth),
                              height: Metrics.bodyHeight(for: vm.selectedTab, showingSettings: vm.showSettings, settingsCategory: vm.settingsCategory, mediaLyrics: settings.mediaLyrics))
        }
        return CGRect(x: (size.width - bodySize.width) / 2, y: 0,
                      width: bodySize.width, height: bodySize.height)
    }

    private func clampedX(in size: CGSize) -> CGFloat {
        min(max(gallery.anchor.x, 8), max(8, size.width - cardWidth - 8))
    }

    private func clampedY(in size: CGSize) -> CGFloat {
        min(max(gallery.anchor.y, 8), max(8, size.height - maxCardHeight - 8))
    }
}

/// The gallery card itself: a search field, a row of category chips, and a
/// scrolling grid of the tabs not yet in the bar (`settings.addableTabs`). Always
/// drawn as dark black-glass regardless of the panel theme, matching the context
/// menu, so it reads as the same floating surface in every theme.
private struct AddTabGalleryCard: View {
    let width: CGFloat
    let maxHeight: CGFloat
    var onHoverChange: (Bool) -> Void = { _ in }
    let onPick: () -> Void

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var vm: NotchViewModel

    @State private var query = ""
    /// `nil` = "All"; otherwise the picked category chip.
    @State private var filter: NotchTab.Category?
    @FocusState private var searchFocused: Bool

    private let columns = [GridItem(.flexible(), spacing: Spacing.sm),
                           GridItem(.flexible(), spacing: Spacing.sm)]
    /// Fixed tile height, so the grid's visible height is exact math (no guessing
    /// around variable-height tiles).
    private let tileHeight: CGFloat = 56
    private let rowSpacing: CGFloat = Spacing.sm
    /// Rows shown before the grid starts scrolling.
    private let maxVisibleRows = 4

    /// The categories that actually have an addable tab, so we never show a chip
    /// that would filter to an empty grid.
    private var presentCategories: [NotchTab.Category] {
        NotchTab.Category.allCases.filter { cat in
            settings.addableTabs.contains { $0.category == cat }
        }
    }

    /// Addable tabs after the category chip and the search query are applied.
    private var results: [NotchTab] {
        settings.addableTabs.filter { tab in
            (filter == nil || tab.category == filter) && tab.matches(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            searchField
            if presentCategories.count > 1 {
                categoryChips
            }
            content
        }
        .padding(Spacing.lg)
        .frame(width: width)
        .background {
            let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
            shape.fill(Color.black.opacity(0.3)).blackGlass(in: shape)
        }
        .shadow(color: .black.opacity(0.4), radius: 22, y: 12)
        .environment(\.colorScheme, .dark)
        // Entering the card grabs window key so the search field can take keystrokes
        // in the non-activating panel; also holds the panel open (see host).
        .grabsWindowKeyForDrag()
        .onHover { onHoverChange($0) }
        .onAppear { searchFocused = true }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
            TextField("Search tabs…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .tint(settings.accent)
                .focused($searchFocused)
                .onSubmit { addFirstResult() }
                .onKeyPress(.escape) { onPick(); return .handled }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .linkCursor()
            }
        }
        .padding(.horizontal, Spacing.base)
        .frame(height: 38)
        .background {
            let shape = Capsule(style: .continuous)
            shape.fill(Color.white.opacity(0.08))
                .overlay { shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 1) }
        }
    }

    // MARK: - Category chips

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.s) {
                chip(title: "All", symbol: "square.grid.2x2", isOn: filter == nil) { filter = nil }
                ForEach(presentCategories) { cat in
                    chip(title: cat.title, symbol: cat.symbol, isOn: filter == cat) { filter = cat }
                }
            }
            .padding(.horizontal, Spacing.hair)
        }
    }

    private func chip(title: String, symbol: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { action() }
        } label: {
            HStack(spacing: Spacing.s) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(isOn ? .black : .white.opacity(0.85))
            .padding(.horizontal, Spacing.base)
            .frame(height: 28)
            .background {
                Capsule(style: .continuous)
                    .fill(isOn ? Color.white : Color.white.opacity(0.09))
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .linkCursor()
    }

    // MARK: - Grid / empty state

    @ViewBuilder
    private var content: some View {
        let tabs = results
        if tabs.isEmpty {
            emptyState
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: columns, spacing: rowSpacing) {
                    ForEach(tabs) { tab in
                        AddTabTile(tab: tab, accent: settings.accent, height: tileHeight) { add(tab) }
                    }
                }
                .padding(.horizontal, Spacing.hair)
            }
            // Cap the grid to a few rows and let it scroll past that, so the card
            // stays compact no matter how many tabs exist.
            .frame(height: gridHeight(count: tabs.count))
        }
    }

    /// Exact visible height for `count` tiles laid out two-up, capped at
    /// `maxVisibleRows` rows (beyond which the grid scrolls).
    private func gridHeight(count: Int) -> CGFloat {
        let rows = (count + 1) / 2
        let shown = min(rows, maxVisibleRows)
        return CGFloat(shown) * tileHeight + CGFloat(max(0, shown - 1)) * rowSpacing
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
            Text("No tabs match “\(query)”")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xxl)
    }

    // MARK: - Actions

    private func add(_ tab: NotchTab) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            settings.addTab(tab)
            vm.selectedTab = tab
        }
        onPick()
    }

    /// Enter adds the top result — so the flow can be pure keyboard: open, type,
    /// Return.
    private func addFirstResult() {
        if let first = results.first { add(first) }
    }
}

/// One tab tile in the gallery grid: icon chip + title + one-line subtitle.
private struct AddTabTile: View {
    let tab: NotchTab
    let accent: Color
    let height: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.md) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.12))
                    }
                VStack(alignment: .leading, spacing: Spacing.hair) {
                    Text(tab.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(tab.subtitle)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .frame(height: height)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    }
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .notchHover(scale: 1.03)
    }
}
