import SwiftUI
import AppKit

/// Sizing + layout constants for the notch panel.
enum Metrics {
    /// Fallback notch size for displays without a physical notch.
    static let fallbackNotchWidth: CGFloat = 200
    static let fallbackNotchHeight: CGFloat = 32

    /// Extra hover margin around the collapsed pill.
    static let collapsedHoverPadding: CGFloat = 14

    /// Extra width added to each side of the collapsed pill on displays *without*
    /// a physical notch, where the pill floats below the top edge. On a real notch
    /// the pill matches the notch bounds exactly (see `AppDelegate.notchSize`), so
    /// this padding is not applied there.
    static let collapsedWidthPadding: CGFloat = 16

    /// How far in from each side of the collapsed pill the open-trigger is inset,
    /// so the panel only opens when the pointer is actually over the notch rather
    /// than anywhere near it. Kept fairly large so the open zone is just the central
    /// core of the notch — brushing past the edges (e.g. reaching the menu bar)
    /// won't spring it open.
    static let collapsedTriggerInset: CGFloat = 64

    /// The panel only arms while the pointer is within the notch's own height (plus
    /// this slack) of the very top of the screen — i.e. genuinely over the notch,
    /// not down over a window's toolbar. SwiftUI's `.onHover` tracks the pill view's
    /// rectangular frame and quietly ignores the narrow `CenteredHoverShape`, so
    /// without this vertical gate the panel can spring open from well below the
    /// notch (e.g. down at a browser's search bar). Kept small so the trigger stays
    /// pinned to the notch — a browser's URL bar and everything below it never arm
    /// it. Enforced in `NotchViewModel.pointerOverNotch`.
    static let collapsedTriggerSlack: CGFloat = 6

    /// Once more than this many tabs are enabled the flat tab strip is replaced
    /// by a segmented category row (Media / Tools / Glance); at or below it the
    /// strip stays flat. See `TopBar` in PanelView.
    static let tabCategoryThreshold: Int = 15

    /// Expanded panel size (the floating glass card).
    static let openWidth: CGFloat = 660
    // Tall enough that the immersive Media player (108pt art + transport + source
    // chips) fits without its bottom row being clipped by the panel edge.
    static let openHeight: CGFloat = 244

    /// Body height for each Settings category. The settings are split into broad
    /// categories switched by a top pill selector, so the panel only has to be as
    /// tall as the visible category — much shorter than stacking everything. The
    /// tallest of these (`settingsMaxHeight`) is what `windowContentHeight` grows to.
    static func settingsHeight(for category: SettingsCategory) -> CGFloat {
        // Each setting now floats in its own padded card (rather than packed into
        // one pane), so the categories breathe taller than the old dividered layout.
        switch category {
        // General's left column now carries the Fuel "Update rate" group beneath the
        // three base rows, so it needs the extra height to show it without clipping.
        case .general:    return 460
        case .appearance: return 330
        // Media lost the collapsed-notch group to its own tab, so it's lighter now;
        // Notch carries the fuel-event card with its three-line caption, so it stays tall.
        case .media:      return 392
        case .notch:      return 430
        }
    }

    /// The tallest Settings category — what the fixed window must be able to hold.
    static var settingsMaxHeight: CGFloat {
        SettingsCategory.allCases.map(settingsHeight(for:)).max() ?? openHeight
    }

    /// Taller body used for the Fuel dashboard — the big level meter plus the two
    /// rows of stat readouts need more room than the standard panel. Sized to fit
    /// the whole layout without clipping (an undersized body overflows and, being
    /// centered, pushes the tab bar off the top edge). Still below
    /// `moodExpandedHeight`, so the fixed window never has to resize for it.
    static let fuelHeight: CGFloat = 500

    /// Taller body for the Clock tab — the world-clock column and the timer's
    /// countdown ring plus its preset grid want more vertical room than the
    /// standard `openHeight`. Kept below `moodExpandedHeight` so the fixed window
    /// never has to grow to hold it.
    static let clockHeight: CGFloat = 340

    /// Taller body for the Weather tab. The forecast face is a bento board of city
    /// blocks that resize up to 3 wide and **2 tall**, so the body must clear two
    /// full rows of the 148pt blocks (296pt + gap) plus the header + mode pills —
    /// otherwise a 2-row tile clips against the bottom edge. After the top bar,
    /// header and pills (~152pt of chrome), 476 leaves ~324pt for the board, enough
    /// for two rows with a little breathing room. Kept below `moodExpandedHeight` so
    /// the fixed window never has to grow to hold it.
    static let weatherHeight: CGFloat = 476

    /// Taller body for the Calendar tab so a comfortable stretch of the upcoming
    /// agenda is visible before it needs scrolling. Kept below `moodExpandedHeight`
    /// so the fixed window never has to grow to hold it.
    static let calendarHeight: CGFloat = 360

    /// Taller body for the AI Scratch tab so a useful stretch of the conversation
    /// transcript plus the input bar are visible at once. Kept below
    /// `moodExpandedHeight` so the fixed window never has to grow to hold it.
    static let scratchHeight: CGFloat = 420

    /// Slightly taller body for the Record tab. The standard `openHeight` leaves
    /// the Region/Window/Full capture tiles jammed against the bottom panel edge;
    /// a little extra room lets them breathe under the mode switch. Kept well below
    /// `moodExpandedHeight` so the fixed window never has to grow to hold it.
    static let recordHeight: CGFloat = 300

    /// Taller body for the Deck tab. The always-visible "Deck" header sits above
    /// the content, and the "New Key" editor overlay (segmented action picker +
    /// label/symbol/payload fields + Add Key button) fills only the area below it,
    /// so the body must hold header (~44pt) + editor (~290pt) or the Add Key button
    /// clips off the bottom. The visual editor (action chips + adaptive destination
    /// control + name/preview row + save) is taller than the old field stack, so the
    /// body grew to suit. The grid sits in a fill-to-height ScrollView, so the extra
    /// room just shows more keys when not editing. Kept below `moodExpandedHeight`.
    static let deckHeight: CGFloat = 384

    /// Taller body for the System (Now) tab: three stacked vitals rows (CPU, memory,
    /// network), each a hero readout plus a sparkline of recent history, want more
    /// room than the standard `openHeight`. Kept below `moodExpandedHeight`.
    static let nowHeight: CGFloat = 400

    /// Taller body for the Countdown tab: a hero "days remaining" block over a
    /// scrolling list of the other pinned dates — sized so the tallest state, the
    /// add form with its month calendar, fits without scrolling (the list state
    /// just gets more breathing room). Kept below `moodExpandedHeight`.
    static let countdownHeight: CGFloat = 470

    /// Taller body for the Shortcuts tab: a grid of launch tiles plus the inline
    /// "new shortcut" editor. Kept below `moodExpandedHeight`.
    static let shortcutsHeight: CGFloat = 388

    /// The "bigger notch" the Mood board grows into when expanded (not a real
    /// fullscreen — just a much larger floating canvas).
    static let moodExpandedWidth: CGFloat = 880
    static let moodExpandedHeight: CGFloat = 520

    /// The panel hangs directly from the top edge of the screen (attached to the
    /// notch), so there is no gap above it.
    static let openTopGap: CGFloat = 0

    /// How far the *floating* Dynamic Island drops below the screen's top edge when
    /// that mode is on — enough that the desktop shows above and around it, so the
    /// collapsed pill reads as a detached iPhone-style island rather than welding to
    /// the bezel. Only applies to the collapsed pill; the open panel still welds.
    static let islandFloatGap: CGFloat = 10

    /// The window is fixed at the tallest body it will ever show, so it never has
    /// to resize — the body just grows/shrinks inside it.
    static var windowContentHeight: CGFloat { max(openHeight, settingsMaxHeight, fuelHeight, moodExpandedHeight) }

    /// The window is fixed at the widest body it will ever show, for the same
    /// reason. `panelWidth` is user-configurable, so take the max.
    static func windowContentWidth(panelWidth: CGFloat) -> CGFloat {
        max(panelWidth, moodExpandedWidth)
    }

    /// Body height for the What's New card, sized to the number of change rows so
    /// the whole release list shows without scrolling — the panel grows to fit it
    /// and stays welded to the notch, exactly like a Settings category.
    static func whatsNewHeight(changeCount: Int) -> CGFloat {
        let h = 150 + CGFloat(max(1, changeCount)) * 88
        return min(500, max(220, h))
    }

    /// Body height for a given panel mode. What's New and Settings size to their
    /// content; the Fuel dashboard grows taller; every other tab uses `openHeight`.
    static func bodyHeight(for tab: NotchTab, showingSettings: Bool,
                           showingWhatsNew: Bool = false, whatsNewChanges: Int = 0,
                           settingsCategory: SettingsCategory) -> CGFloat {
        if showingWhatsNew { return whatsNewHeight(changeCount: whatsNewChanges) }
        if showingSettings { return settingsHeight(for: settingsCategory) }
        if tab == .fuel { return fuelHeight }
        if tab == .clock { return clockHeight }
        if tab == .weather { return weatherHeight }
        if tab == .calendar { return calendarHeight }
        if tab == .scratch { return scratchHeight }
        if tab == .deck { return deckHeight }
        if tab == .record { return recordHeight }
        if tab == .now { return nowHeight }
        if tab == .countdown { return countdownHeight }
        if tab == .shortcuts { return shortcutsHeight }
        return openHeight
    }

    static let panelCornerRadius: CGFloat = 26
    static let cardCornerRadius: CGFloat = 18

    /// Opening spring: bouncy, so the panel visibly springs *out* of the notch
    /// with a hint of overshoot (mirrors DynamicNotchKit's `.bouncy(0.4)`).
    static let openSpring: Animation = .spring(response: 0.40, dampingFraction: 0.68)

    /// Closing spring: smooth and near-critically damped, so the panel contracts
    /// cleanly back into the notch without jittering.
    static let closeSpring: Animation = .spring(response: 0.34, dampingFraction: 0.92)

    /// Dynamic Island expand: a quick, lively pop with a touch more overshoot than
    /// the panel open — the pill is small, so it should snap out and bounce a hair
    /// to read as a physical *jump*, iPhone-style, rather than a slow unfold.
    static let islandExpand: Animation = .spring(response: 0.36, dampingFraction: 0.62)

    /// Dynamic Island settle: smooth and fully damped, so the pill eases back into
    /// the bare notch with no wobble once the activity's moment has passed.
    static let islandSettle: Animation = .spring(response: 0.42, dampingFraction: 0.95)

    /// How long a dragged item must hover a tab before the board spring-loads
    /// (switches to that tab). Tuned shorter than a literal "couple seconds" so it
    /// feels responsive rather than stuck; nudge up if it triggers too eagerly.
    static let springLoadDelay: Double = 0.9
}

/// The shared spacing scale — one place for every `.padding(…)` and stack
/// `spacing:` in the app, so gaps stay on a common grid instead of each view
/// hard-coding its own near-duplicate literals.
///
/// The scale is a **2pt grid** because that is the rhythm the notch UI already
/// follows: 2/6/8/10/12 are all load-bearing (6 and 10 are the two most common
/// stack gaps), so a coarser 4pt scale would move the app's most-used spacings
/// everywhere. Adopting these tokens snapped the genuine off-grid outliers
/// (odd values, and the sparse 18/22/26) to the nearest step; everything already
/// on the grid tokenizes with no pixel change.
///
/// Naming is size-ordered so call sites read as intent, not magic numbers:
/// `.padding(Spacing.lg)` instead of `.padding(Spacing.lg)`.
enum Spacing {
    /// 2 — hairline gap (dividers, tight insets).
    static let hair: CGFloat = 2
    /// 4 — extra-small.
    static let xs: CGFloat = 4
    /// 6 — small.
    static let s: CGFloat = 6
    /// 8 — the default control gap.
    static let sm: CGFloat = 8
    /// 10 — medium.
    static let md: CGFloat = 10
    /// 12 — the default card/row inset.
    static let base: CGFloat = 12
    /// 16 — large; section padding.
    static let lg: CGFloat = 16
    /// 24 — extra-large; between distinct groups.
    static let xl: CGFloat = 24
    /// 32 — section separation.
    static let xxl: CGFloat = 32
    /// 48 — page-level breathing room.
    static let xxxl: CGFloat = 48
}

/// Reused colors + a couple of Liquid Glass helpers.
///
/// The neutral palette is **appearance-dynamic**: each color below resolves from
/// the *pinned* `colorScheme` of the subtree that draws it (white-on-dark under a
/// dark appearance, dark-on-light under a light one). `PanelView` pins the light
/// chrome to `.light` and the media/data/board tabs to `.dark`, so under the Light
/// theme the panel-native surfaces flip to dark-on-light while the immersive tabs
/// keep their legible light-on-dark — no per-view branching, and every existing
/// `Theme.*` call site adapts for free.
enum Theme {
    /// True while the Light panel *surface* is active — used only for structural
    /// choices that aren't expressible as a per-subtree color (which panel surface
    /// RootView paints, whether PanelView adds a dark stage). Written by
    /// ``SettingsStore``. `nonisolated(unsafe)`: only ever touched on the main
    /// thread — during UI setup and inside SwiftUI `body` evaluation.
    nonisolated(unsafe) static var isLight = false

    /// True while the Noir surface is active. Like ``isLight`` it's a structural
    /// flag (deep-black panel + baked ember accent), but Noir is still a dark
    /// white-on-black scheme, so it does *not* flip ``colorScheme``. Written by
    /// ``SettingsStore``; read only on the main thread inside SwiftUI `body`.
    nonisolated(unsafe) static var isNoir = false

    /// Noir's baked-in accent — a *muted* burnt-orange ember. Deliberately quieter
    /// than a saturated orange so it reads as the single, restrained point of
    /// colour in an otherwise monochrome, Analogue-minimal space. ~#BC4F2E.
    static let ember = Color(red: 0.737, green: 0.310, blue: 0.180)

    /// The palette-level accent used by chrome that doesn't read the user accent
    /// (currently just the open-morph sheen). Ember under Noir, the neutral blue
    /// otherwise. The user-configurable accent lives on ``SettingsStore/accent``.
    static var accent: Color { isNoir ? ember : Color(red: 0.30, green: 0.52, blue: 0.98) }

    /// A color that resolves differently under dark vs. light appearance. SwiftUI
    /// resolves it against the current `colorScheme` environment, so pinning a
    /// subtree's colorScheme picks the variant.
    private static func dyn(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    /// Primary body text — white on dark, near-black on light.
    static var primaryText: Color { dyn(dark: .white, light: NSColor(white: 0.13, alpha: 1)) }
    // Text opacities are tuned to clear WCAG AA (4.5:1) on each appearance's fill.
    static var secondaryText: Color { dyn(dark: NSColor(white: 1, alpha: 0.75), light: NSColor(white: 0, alpha: 0.62)) }
    static var tertiaryText: Color { dyn(dark: NSColor(white: 1, alpha: 0.60), light: NSColor(white: 0, alpha: 0.45)) }

    // Noir sits on near-pure black, so its inner cards want a slightly crisper
    // hairline than the grey Solid surface to stay legible without looking heavy.
    static var cardFill: Color {
        if isNoir { return Color.white.opacity(0.045) }
        return dyn(dark: NSColor(white: 1, alpha: 0.05), light: NSColor(white: 0, alpha: 0.05))
    }
    static var cardStroke: Color {
        if isNoir { return Color.white.opacity(0.13) }
        return dyn(dark: NSColor(white: 1, alpha: 0.10), light: NSColor(white: 0, alpha: 0.10))
    }

    /// The neutral used for the many spots that inline a bare `Color.white.opacity`
    /// (dividers, control tracks, tile outlines): white on dark, black on light.
    private static var neutral: Color { dyn(dark: .white, light: .black) }
    static func line(_ opacity: Double) -> Color { neutral.opacity(opacity) }

    /// The panel body's hairline edge — structural, so `isLight`-driven.
    static var panelStroke: Color {
        if isNoir { return Color.white.opacity(0.11) }
        return isLight ? Color.black.opacity(0.10) : Color.white.opacity(0.08)
    }

    /// The colorScheme the top-level panel surface is pinned to.
    static var colorScheme: ColorScheme { isLight ? .light : .dark }
}
