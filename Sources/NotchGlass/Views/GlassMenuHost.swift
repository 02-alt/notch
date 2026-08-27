import SwiftUI

/// Renders the active Liquid Glass context menu. One instance lives in RootView;
/// it reads `GlassMenuController` and draws a frosted panel of rows at the
/// right-click point. Rows with a submenu open a *side flyout column* on hover
/// (native-menu style), rather than replacing the current level.
struct GlassMenuHost: View {
    @EnvironmentObject private var controller: GlassMenuController
    @EnvironmentObject private var vm: NotchViewModel
    @EnvironmentObject private var settings: SettingsStore

    private let width: CGFloat = 220
    private let rowHeight: CGFloat = 42
    private let vPadding: CGFloat = 6
    /// Gap between a column and its flyout — must match `GlassMenuColumn.gap`.
    private let flyoutGap: CGFloat = 4

    @State private var leaveWork: DispatchWorkItem?
    /// The last place the pointer was seen off the menu, so a tap can reuse the
    /// same in-panel / off-panel decision the hover tracking makes.
    @State private var lastLocation: CGPoint = .zero
    /// Whether the pointer has actually reached the menu since it opened. The menu
    /// opens with the cursor sitting on its rounded top-left corner — a spot the
    /// column's own hover often misses — so until the pointer genuinely lands on
    /// the menu we mustn't let the off-menu tracking auto-dismiss it. Otherwise it
    /// vanishes in the blink between the right-click and the user reaching it.
    @State private var hasEnteredMenu = false

    var body: some View {
        GeometryReader { geo in
            if controller.isPresented {
                ZStack(alignment: .topLeading) {
                    // Full-window catcher. The menu sits on top of it, so receiving
                    // pointer events here means the pointer is *off* the menu. Because
                    // the catcher also covers the panel body, we can't just collapse
                    // the notch — we track the pointer's position and only collapse
                    // when it's off the panel too. Off the menu but still over the
                    // panel simply drops the menu and keeps the notch open.
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { leftMenu(inPanel: panelRect(in: geo.size).contains(lastLocation)) }
                        .onContinuousHover(coordinateSpace: .local) { phase in
                            switch phase {
                            case .active(let loc):
                                lastLocation = loc
                                // Until the pointer has first reached the menu, ignore
                                // off-menu hovers so a freshly opened menu can't dismiss
                                // itself before the user gets to it.
                                guard hasEnteredMenu else { return }
                                scheduleLeave(inPanel: panelRect(in: geo.size).contains(loc))
                            case .ended:
                                // Pointer left the window entirely — off the panel.
                                scheduleLeave(inPanel: false)
                            }
                        }

                    GlassMenuColumn(items: controller.items,
                                    width: width,
                                    flyLeft: flyLeft(in: geo.size),
                                    onPick: { controller.dismiss() },
                                    onHoverChange: { onMenu in
                                        // Back on the menu: cancel any pending leave and
                                        // hold the panel open. Leaving the menu is handled
                                        // by the position-aware catcher above.
                                        if onMenu { hasEnteredMenu = true; cancelLeave(); vm.keepOpen() }
                                    })
                        .offset(x: clampedX(in: geo.size), y: clampedY(in: geo.size))
                        .transition(.scale(scale: 0.9, anchor: .topLeading).combined(with: .opacity))
                }
                .ignoresSafeArea()
                // Opening the menu cancels the spurious close the catcher's
                // appearance triggers by stealing hover from the panel body. The
                // "reached the menu yet?" gate also resets here for each fresh open.
                .onAppear { hasEnteredMenu = false; vm.keepOpen() }
            }
        }
    }

    /// Debounced leave: once the pointer settles off the menu, drop the menu. If it
    /// settled *outside* the panel too, let the panel collapse; if it's still over
    /// the panel, keep the notch open. Re-entering the menu cancels this, and the
    /// debounce bridges the tiny gap between a parent row and its flyout column.
    private func scheduleLeave(inPanel: Bool) {
        cancelLeave()
        let work = DispatchWorkItem { leftMenu(inPanel: inPanel) }
        leaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    private func cancelLeave() {
        leaveWork?.cancel()
        leaveWork = nil
    }

    private func leftMenu(inPanel: Bool) {
        cancelLeave()
        controller.dismiss()
        // Only collapse the notch if the pointer has also left the panel body.
        if inPanel { vm.keepOpen() } else { vm.setHover(false) }
    }

    /// The panel body's frame within the window: it's horizontally centered and
    /// welded to the top edge. Used to tell "off the menu, still on the notch" from
    /// "off the notch entirely".
    private func panelRect(in size: CGSize) -> CGRect {
        let bodySize: CGSize
        if vm.isBigCanvas {
            bodySize = CGSize(width: Metrics.moodExpandedWidth, height: Metrics.moodExpandedHeight)
        } else {
            bodySize = CGSize(width: CGFloat(settings.panelWidth),
                              height: Metrics.bodyHeight(for: vm.selectedTab, showingSettings: vm.showSettings, settingsCategory: vm.settingsCategory))
        }
        return CGRect(x: (size.width - bodySize.width) / 2, y: 0,
                      width: bodySize.width, height: bodySize.height)
    }

    private var estimatedHeight: CGFloat {
        vPadding * 2 + CGFloat(controller.items.count) * rowHeight
    }

    /// Flyouts open to the left only when a right-opening flyout would actually run
    /// past the window edge. Based on the column's *clamped* position and true width
    /// (not the raw anchor), so it doesn't flip sides prematurely.
    private func flyLeft(in size: CGSize) -> Bool {
        clampedX(in: size) + width + flyoutGap + width + 8 > size.width
    }

    private func clampedX(in size: CGSize) -> CGFloat {
        min(max(controller.anchor.x, 8), max(8, size.width - width - 8))
    }

    private func clampedY(in size: CGSize) -> CGFloat {
        min(max(controller.anchor.y, 8), max(8, size.height - estimatedHeight - 8))
    }
}

/// One column of menu rows. Hovering a row that has a submenu reveals a child
/// `GlassMenuColumn` beside it (recursively, for deeper levels).
private struct GlassMenuColumn: View {
    let items: [GlassMenuItem]
    let width: CGFloat
    let flyLeft: Bool
    let onPick: () -> Void
    /// Reports whether the pointer is over this column (or, recursively, a flyout),
    /// so the host can keep the panel open while on the menu and close when off it.
    var onHoverChange: (Bool) -> Void = { _ in }

    private let vPadding: CGFloat = 6
    /// Gap between a column and its flyout. Kept small so the pointer crosses it
    /// well within the close debounce below.
    private let gap: CGFloat = 4

    @State private var openSubmenu: UUID?
    @State private var closeWork: DispatchWorkItem?

    var body: some View {
        VStack(spacing: 2) {
            ForEach(items) { item in
                row(for: item)
            }
        }
        .padding(vPadding)
        // Fixed width (not intrinsic) so a flyout offset by `width + gap` lands flush
        // against this column's edge instead of leaving a gap.
        .frame(width: width)
        .background {
            let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
            shape.fill(Color.black.opacity(0.3))
                .blackGlass(in: shape)
        }
        .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
        .fixedSize(horizontal: false, vertical: true)
        .onHover { onHoverChange($0) }
    }

    @ViewBuilder
    private func row(for item: GlassMenuItem) -> some View {
        GlassMenuRow(title: item.title,
                     systemImage: item.systemImage,
                     isDestructive: item.isDestructive,
                     hasSubmenu: item.submenu != nil,
                     isActive: openSubmenu == item.id) {
            // Leaves fire and dismiss; parents are hover-driven, so a click just
            // opens their flyout too.
            if let submenu = item.submenu {
                requestOpen(item.id, hasSubmenu: submenu.isEmpty == false)
            } else {
                item.action?()
                onPick()
            }
        }
        .onHover { hovering in
            if item.submenu != nil {
                hovering ? requestOpen(item.id, hasSubmenu: true) : requestClose()
            } else if hovering {
                // Moving onto a sibling leaf collapses any open flyout.
                requestClose()
            }
        }
        .overlay(alignment: flyLeft ? .topTrailing : .topLeading) {
            if openSubmenu == item.id, let submenu = item.submenu, !submenu.isEmpty {
                // The row is inset from the column edge by `vPadding`, so shift by
                // that much less than a full column width to land flush against it.
                let step = width + gap - vPadding
                GlassMenuColumn(items: submenu, width: width, flyLeft: flyLeft,
                                onPick: onPick, onHoverChange: onHoverChange)
                    .offset(x: flyLeft ? -step : step)
                    .onHover { hovering in if hovering { cancelClose() } }
                    .transition(.scale(scale: 0.92,
                                       anchor: flyLeft ? .topTrailing : .topLeading)
                        .combined(with: .opacity))
            }
        }
    }

    private func requestOpen(_ id: UUID, hasSubmenu: Bool) {
        cancelClose()
        guard hasSubmenu, openSubmenu != id else { return }
        withAnimation(.easeOut(duration: 0.12)) { openSubmenu = id }
    }

    /// Debounced close so the pointer can travel from a parent row into its flyout
    /// across the small gap without the flyout vanishing.
    private func requestClose() {
        cancelClose()
        let work = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.12)) { openSubmenu = nil }
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func cancelClose() {
        closeWork?.cancel()
        closeWork = nil
    }
}

private struct GlassMenuRow: View {
    let title: String
    let systemImage: String?
    let isDestructive: Bool
    let hasSubmenu: Bool
    let isActive: Bool
    let action: () -> Void

    @State private var hovering = false

    /// Highlighted while hovered *or* while its flyout is open.
    private var highlighted: Bool { hovering || isActive }

    private var foreground: Color {
        if highlighted { return isDestructive ? .white : .black }
        return isDestructive ? Color(red: 1, green: 0.42, blue: 0.42) : .white
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background {
                            if !highlighted {
                                Circle().fill(Color.white.opacity(0.12))
                            }
                        }
                }
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                Spacer(minLength: 0)
                if hasSubmenu {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .opacity(0.7)
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .frame(height: 38)
            .frame(maxWidth: .infinity)
            .background {
                if highlighted {
                    Capsule(style: .continuous)
                        .fill(isDestructive ? Color(red: 0.9, green: 0.25, blue: 0.25) : .white)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
