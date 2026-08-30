import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// Fills the fixed-size panel window and morphs between the collapsed notch pill
/// and the expanded glass panel. The window never resizes — only this content
/// changes — so hover targets are the pill / panel themselves, not the whole
/// (mostly transparent) window.
///
/// The morph is a *single continuous shape* (the notch body) whose width, height
/// and corner radius animate between the collapsed and expanded sizes — so it
/// genuinely grows out of the notch when opening and contracts back into it when
/// closing, rather than cross-fading between two separate views. (Same technique
/// DynamicNotchKit uses: content on a black surface, masked by a growing shape.)
struct RootView: View {
    @EnvironmentObject private var vm: NotchViewModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var glassMenu: GlassMenuController
    @EnvironmentObject private var gallery: AddTabGalleryController
    @EnvironmentObject private var np: NowPlayingManager
    @EnvironmentObject private var lyrics: LyricsService

    /// Whether the collapsed pill should widen into a "lyrics ticker" — the pin is on
    /// and the current track actually has synced lyrics to show.
    private var lyricTickerActive: Bool {
        lyrics.tickerActive(pinned: settings.pinLyrics, hasTrack: np.hasTrack)
    }

    /// The line currently shown on the ticker (title as a fallback during an intro /
    /// instrumental gap). Nil when the ticker isn't active — also the animation key, so
    /// the pill morphs to its new width each time the line changes.
    private var lyricTickerLine: String? {
        lyricTickerActive ? (lyrics.currentLine(at: np.position) ?? np.title) : nil
    }

    /// The collapsed pill width when showing the pinned lyric line — sized to *fit* the
    /// current line (so it isn't truncated), then clamped so a very long line can't run
    /// the pill off-screen. `CollapsedMediaView` fills this width with the line.
    private var lyricTickerWidth: CGFloat {
        let base = vm.collapsedSize
        let vInset = max(4, base.height * 0.15)
        let art = max(0, base.height - vInset * 2)
        let hInset = max(12, base.height * 0.42)
        let fontSize = art * 0.42
        // Measure the line's *actual* rendered width (proportional fonts vary too much
        // to estimate by character count) so the pill is sized to fit exactly, then add
        // the album-art tile + the surrounding insets, with a little slack.
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let textWidth = ((lyricTickerLine ?? "") as NSString)
            .size(withAttributes: [.font: font]).width
        // Round up + generous slack: SwiftUI's Text renders a hair wider than this
        // measurement, so a tight fit clips the last word on long lines.
        let needed = art + hInset * 3 + textWidth.rounded(.up) + 24
        // Grow as far as the hosting window allows (it's the wide Mood-canvas width),
        // leaving a small margin so the pill never touches the window edge.
        let maxWidth = Metrics.windowContentWidth(panelWidth: openWidth) - 24
        return min(max(base.width, needed), maxWidth)
    }

    /// True while a drag session is hovering the notch body.
    @State private var dragOver = false

    private var openWidth: CGFloat { CGFloat(settings.panelWidth) }

    /// The full window content width — the body is centered inside it, so the outer
    /// frame must match or the pill/panel drifts off the notch when the Mood board's
    /// wider expanded canvas widens the window.
    private var frameWidth: CGFloat { Metrics.windowContentWidth(panelWidth: openWidth) }

    /// True when the Mood board is blown up into its "bigger notch" canvas.
    private var isMoodBig: Bool {
        vm.isOpen && vm.isBigCanvas
    }

    /// The animated size of the notch body: the collapsed pill, the panel, the
    /// taller Settings panel, or the expanded Mood board.
    private var bodySize: CGSize {
        guard vm.isOpen else { return collapsedBodySize }
        if isMoodBig {
            return CGSize(width: Metrics.moodExpandedWidth, height: Metrics.moodExpandedHeight)
        }
        return CGSize(width: openWidth, height: Metrics.bodyHeight(for: vm.selectedTab, showingSettings: vm.showSettings, showingWhatsNew: vm.showWhatsNew, whatsNewChanges: WhatsNew.visibleChangeCount, settingsCategory: vm.settingsCategory, mediaLyrics: settings.mediaLyrics))
    }

    /// The collapsed pill's size — the bare notch normally, but while a fuel event is
    /// flashing the pill widens and drops a touch into a small banner, so the notch
    /// visibly *opens a little* to deliver the message before settling back.
    private var collapsedBodySize: CGSize {
        guard !vm.isOpen else { return vm.collapsedSize }
        let base = vm.collapsedSize
        // A fuel-style notice pops a short banner; the Dynamic Island morphs a touch
        // wider and taller so its two-slot activity (art + EQ) has room to breathe.
        if vm.islandActivity != nil {
            return CGSize(width: max(base.width + 220, 360), height: base.height + 18)
        }
        if vm.collapsedEvent != nil {
            return CGSize(width: max(base.width + 168, 320), height: base.height + 12)
        }
        // Persistent island: even at rest the pill sits wider than the bare notch, so
        // switching the mode on visibly transforms the notch into an always-on island
        // with room for the time + battery either side of the camera.
        if settings.dynamicIsland {
            return CGSize(width: max(base.width + 150, 300), height: base.height + 6)
        }
        // Pinned lyrics: widen into a ticker sized to fit the current line beside the
        // album art, without touching the bare-notch height.
        if lyricTickerActive {
            return CGSize(width: lyricTickerWidth, height: base.height)
        }
        return base
    }

    /// Dynamic Island mode detaches the *whole* panel — collapsed capsule and open
    /// card alike — from the top edge into a free-floating rounded shape (iPhone
    /// style), rather than welding to the bezel. The open panel grows out of the
    /// floating pill and stays a detached rounded card instead of snapping to a notch.
    private var islandMode: Bool { settings.dynamicIsland }

    /// True only for the collapsed floating capsule — drives its resting shadow.
    private var floatingCollapsed: Bool { islandMode && !vm.isOpen }

    /// The floating drop below the screen's top edge. A *constant* gap whenever island
    /// mode is on, so the open card and the resting capsule share the same top inset
    /// and the morph between them never jumps vertically; zero when welded.
    private var islandTopGap: CGFloat { islandMode ? Metrics.islandFloatGap : 0 }

    /// Bottom corner radius: the open panel's soft corner, the floating capsule's full
    /// round, or the welded pill's tight curve.
    private var bottomRadius: CGFloat {
        if vm.isOpen { return Metrics.panelCornerRadius }
        if islandMode { return collapsedBodySize.height / 2 }
        return min(vm.collapsedSize.height / 2, 12)
    }

    /// Top corner radius. Welded panels keep a near-flat 12pt flare so they read as a
    /// notch; the floating island rounds fully — a soft card when open, a capsule when
    /// collapsed — so it never looks welded to the bezel.
    private var topRadius: CGFloat {
        if vm.isOpen { return islandMode ? Metrics.panelCornerRadius : 12 }
        if islandMode { return collapsedBodySize.height / 2 }
        return min(vm.collapsedSize.height / 2, 8)
    }

    /// The notch body outline.
    ///
    /// **Always welds** — a flat full-width top that hangs from the screen's top
    /// edge — so both the collapsed pill and the expanded panel read as a notch on
    /// every display, notch or not. That's the app's signature ("All in a notch"),
    /// and it's what users expect even on a display without a physical notch, so we
    /// no longer fall back to a plain rounded card there.
    private var bodyShape: NotchShape {
        // Weld to the bezel unless Dynamic Island mode is on, where the panel floats
        // free with all four corners rounded — open and closed alike.
        NotchShape(topRadius: topRadius, bottomRadius: bottomRadius, weld: !islandMode)
    }

    /// Hit-test shape for the hover trigger — the full body when open, a narrower
    /// centered zone when collapsed (see `Metrics.collapsedTriggerInset`).
    private var hoverShape: AnyShape {
        if vm.isOpen {
            return AnyShape(bodyShape)
        }
        return AnyShape(CenteredHoverShape(horizontalInset: Metrics.collapsedTriggerInset))
    }

    /// True only when the Liquid Glass theme is on *and* the panel is expanded —
    /// the collapsed pill always stays the opaque black notch so it welds to the
    /// bezel rather than turning into a floating glass chip.
    private var glassActive: Bool {
        settings.panelTheme == .glass && vm.isOpen
    }

    /// True only when the Light theme is on *and* the panel is expanded — the
    /// collapsed pill always stays the opaque black notch (welded to the bezel),
    /// exactly like the glass theme.
    private var lightActive: Bool {
        settings.panelTheme == .light && vm.isOpen
    }

    /// True only when the Noir theme is on *and* the panel is expanded — the
    /// collapsed pill always stays the opaque black notch (welded to the bezel),
    /// exactly like the glass and light themes.
    private var noirActive: Bool {
        settings.panelTheme == .noir && vm.isOpen
    }

    /// The morphing notch body's fill. Cross-fading layers so switching theme (or
    /// opening/closing) dissolves smoothly:
    ///   - the solid dark card (`MorphSurface`), shown for the solid theme and for
    ///     the collapsed pill in every theme;
    ///   - a full-bleed Liquid Glass layer, revealed once the glass theme's panel
    ///     is open so the desktop frosts through the whole panel;
    ///   - a light card, revealed once the Light theme's panel is open.
    /// All are trimmed to the notch silhouette by the `clipShape` in `body`.
    private var bodySurface: some View {
        ZStack {
            MorphSurface(progress: vm.isOpen ? 1 : 0)
                .opacity(glassActive || lightActive || noirActive ? 0 : 1)
            GlassPanelSurface(shape: AnyShape(bodyShape))
                .opacity(glassActive ? 1 : 0)
            LightPanelSurface()
                .opacity(lightActive ? 1 : 0)
            NoirPanelSurface()
                .opacity(noirActive ? 1 : 0)
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Click absorber: the visible notch body always swallows mouse clicks so
            // one never falls through to the window beneath it. Sits under everything
            // and matches the body's exact silhouette (and its island offset), so the
            // transparent window area around the notch still passes clicks through.
            //
            // It's a *filled* shape at a hair of opacity, not `Color.clear` +
            // `contentShape`: on a borderless transparent panel AppKit only refuses to
            // pass a click through where the hosting view actually draws a pixel, so a
            // truly clear region still falls through. A ~0.1%-opacity fill is invisible
            // but paints real (hittable) pixels across the whole silhouette.
            //
            // It carries no hover of its own — opening stays gated to the narrow
            // central trigger (`hoverShape`) so the collapsed pill still only arms
            // when the pointer is genuinely over the notch core.
            bodyShape
                .fill(Color.white.opacity(0.001))
                .frame(width: bodySize.width, height: bodySize.height)
                .offset(y: islandTopGap)

            // Surface: colors morph continuously as it expands — from the pure
            // notch-black of the collapsed pill to the panel's dark gradient, with
            // a faint accent sheen that blooms mid-motion and settles back to
            // neutral. Driven by an animatable progress so the blend is frame-by
            // -frame in step with the spring, not a plain opacity crossfade.
            bodySurface
                .frame(width: bodySize.width, height: bodySize.height)
            // Panel content rides on top and is revealed through the clip as the
            // body grows around it.
            .overlay(alignment: .top) {
                PanelView()
                    .fixedSize()
                    .modifier(NotchUnfoldModifier(progress: vm.isOpen ? 1 : 0))
                    .allowsHitTesting(vm.isOpen)
            }
            // Now-playing peek shown while collapsed: art + a live EQ hugging the
            // notch edges. Fades out as the panel opens and never steals the hover.
            .overlay {
                CollapsedMediaView(size: collapsedBodySize)
                    .opacity(vm.isOpen ? 0 : 1)
                    .allowsHitTesting(false)
            }
            .clipShape(bodyShape)
            .overlay {
                // Hairline edge on the open panel — white on the dark themes, a
                // faint dark line on Light. The collapsed pill has no edge.
                bodyShape.strokeBorder(vm.isOpen ? Theme.panelStroke : .clear, lineWidth: 1)
            }
            .overlay {
                // Glass lip (Liquid Glass theme only): the transparent bottom of the
                // Siri hood is where you see the glass's *thickness*, so the rounded
                // bottom edge catches light. A stroke that's clear up top and bright
                // along the bottom curve — the refractive lip that sells "glass".
                if glassActive {
                    // strokeBorder (not stroke) keeps the lip *inside* the clipped
                    // edge, exactly on the hairline — a centred stroke would sit half
                    // outside and read as a faint second outline at the corners. The
                    // refractive lip: a bright highlight along the rounded bottom edge
                    // where the glass is thickest and catches light — beefed up so the
                    // bottom reads as real, thick glass. (No chromatic/rainbow tint.)
                    bodyShape
                        .strokeBorder(
                            LinearGradient(
                                colors: [.clear, .clear, Color.white.opacity(0.55)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 2.5
                        )
                        .allowsHitTesting(false)
                }
            }
            // Accent outline + glow while a document is being dragged over the
            // notch, so the whole panel visibly "arms" for the drop.
            .overlay {
                bodyShape.strokeBorder(settings.accent.opacity(vm.dragActive ? 0.9 : 0), lineWidth: 2)
            }
            // No drop shadow on the open panel: against a light window sitting behind
            // the notch, any shadow traces a grey rounded halo around the panel that
            // reads as a second "back panel". The panel welds to the top bezel, so it
            // doesn't need a cast shadow to sit right.
            // Depth under the detached floating capsule so it reads as hovering off
            // the desktop rather than painted onto the bezel. (The open card already
            // gets the isOpen shadow above.)
            .shadow(color: .black.opacity(floatingCollapsed ? 0.5 : 0),
                    radius: floatingCollapsed ? 12 : 0,
                    y: floatingCollapsed ? 6 : 0)
            .shadow(color: settings.accent.opacity(vm.dragActive ? 0.45 : 0),
                    radius: vm.dragActive ? 16 : 0)
            // Drop the floating island down off the top edge so the desktop shows
            // above and around it — open card and collapsed capsule alike. Welded
            // (non-island) states keep gap = 0 and hang from the bezel.
            .offset(y: islandTopGap)
            // Hover target. Open: the whole panel silhouette, so it stays open
            // while the pointer roams the panel. Collapsed: a central zone inset
            // from the pill's sides, so it only opens when the pointer is actually
            // over the notch — not from anywhere near it.
            .contentShape(hoverShape)
            .onHover { hovering in setHover(hovering) }
            // Spring-load: a document dragged onto the notch springs the panel
            // open (and keeps it open) even though the mouse isn't "hovering" in
            // the normal sense during a drag. We only open here — the actual drop
            // is caught by the frontmost tab content once the panel is expanded.
            .onDrop(of: [.fileURL, .url, .text], isTargeted: dragOverBinding) { _ in false }
        }
        // The window content area is sized for the largest body it will ever show
        // (the expanded Mood board) so the window itself never has to resize; the
        // body grows within it, centered.
        .frame(width: frameWidth,
               height: Metrics.windowContentHeight + Metrics.openTopGap + Metrics.islandFloatGap,
               alignment: .top)
        // One animation drives the whole morph — frame, corner radius, surface,
        // stroke, shadow and the content reveal all move together.
        .animation(vm.isOpen ? Metrics.openSpring : Metrics.closeSpring, value: vm.isOpen)
        // The little "notch opens" bump when a fuel event flashes in, and back.
        .animation(Metrics.openSpring, value: vm.collapsedEvent)
        // Note: the Dynamic Island's expand/settle is driven by explicit
        // `withAnimation` in `presentIsland` (distinct springs each way), so it
        // deliberately has *no* implicit `.animation(value: vm.islandActivity)` here —
        // one would override those springs with a single curve.
        .animation(Metrics.openSpring, value: settings.panelTheme)
        // Toggling Dynamic Island morphs the resting pill wider/narrower — spring it.
        .animation(Metrics.islandExpand, value: settings.dynamicIsland)
        // Widening into (and out of) the pinned-lyrics ticker morphs like the island —
        // and re-sizes to each new line as the song plays.
        .animation(Metrics.islandExpand, value: lyricTickerActive)
        .animation(Metrics.islandExpand, value: lyricTickerLine)
        .animation(Metrics.openSpring, value: vm.showSettings)
        .animation(Metrics.openSpring, value: vm.showWhatsNew)
        // Each Settings category has its own height — animate the resize on switch.
        .animation(Metrics.openSpring, value: vm.settingsCategory)
        // The Fuel tab is taller than the rest, so switching to/from it morphs the
        // body height — animate on the selected tab so that grow/shrink is smooth.
        .animation(Metrics.openSpring, value: vm.selectedTab)
        .animation(Metrics.openSpring, value: vm.moodExpanded)
        .animation(Metrics.openSpring, value: vm.mapExpanded)
        .animation(Metrics.openSpring, value: vm.noteExpanded)
        .animation(Metrics.openSpring, value: vm.dragActive)
        // The app-wide Liquid Glass context menu renders above everything, using
        // the full window area (so it isn't clipped by the panel body).
        .overlay { GlassMenuHost() }
        // The add-tab gallery (the "+" picker) renders in the same full-window
        // space, above the panel body, for the same reason.
        .overlay { AddTabGalleryHost() }
        .onChange(of: vm.isOpen) { _, open in
            if !open {
                glassMenu.dismiss()
                gallery.dismiss()
            }
        }
    }

    private func setHover(_ hovering: Bool) {
        vm.setHover(hovering)
    }

    /// While a drag is over the notch we hold the panel open; we never schedule a
    /// close from here — once the drag ends, ordinary mouse hover-out closes it, so
    /// the panel can't collapse mid-drag while the pointer moves between tabs.
    private var dragOverBinding: Binding<Bool> {
        Binding(
            get: { dragOver },
            set: { targeted in
                dragOver = targeted
                vm.noteDrag(active: targeted)
                if targeted { vm.keepOpen() }
            }
        )
    }
}

/// The panel surface, whose colors morph as the notch body expands / contracts.
///
/// `progress` (0 = collapsed pill, 1 = open panel) is `animatableData`, so during
/// an animation SwiftUI interpolates it and rebuilds the body every frame — a true
/// color blend in step with the spring, rather than a stepped opacity crossfade.
///   - base: pure notch-black → the panel's dark (very slightly cool) gradient.
///   - sheen: a faint accent wash that blooms at the midpoint of the motion and
///     fades to nothing once settled, so only the *transition* carries color.
private struct MorphSurface: View, Animatable {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let p = min(1, max(0, progress))
        // Grayscale-with-a-hint-of-cool base, interpolated up from black.
        let top = Color(red: 0.138 * p, green: 0.150 * p, blue: 0.170 * p)
        let bottom = Color(white: 0.085 * p)
        // 0 at both ends, peaks mid-morph — the sheen only shows while moving.
        let bloom = sin(p * .pi)

        ZStack {
            // Solid black floor: keeps it fully opaque even if the spring overshoots.
            Color.black
            LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
            LinearGradient(
                colors: [Theme.accent.opacity(0.16 * bloom), .clear],
                startPoint: .top,
                endPoint: .center
            )
        }
    }
}

/// The Liquid Glass fill for the whole expanded panel — the macOS/iOS **Siri
/// overlay**: a solid, opaque **black cap welded to the notch** that holds through
/// the top (where the response text sits), then ramps **all the way to fully
/// clear** so the desktop shows straight through the bottom — "black at the top,
/// transparent the further down you go". A real `.glassEffect` sits underneath so
/// the translucent lower region stays frosted and the rounded bottom edge lenses
/// the wallpaper; the bright refractive **glass lip** on that bottom edge is drawn
/// by the caller (it needs the notch silhouette). Fills its frame; clipped to the
/// notch shape by the caller.
///
/// Why a black→clear gradient over frosted glass, not a flat glass tint: a glass
/// tint is one flat colour and the system drops it on tall surfaces anyway (see
/// `blackGlass`), so it can't give the opaque-top / clear-bottom ramp that defines
/// this look. We keep a frost layer for the glassy translucency and take the hood
/// from a vertical black gradient over it.
private struct GlassPanelSurface: View {
    /// The notch silhouette the glass is drawn in. Passing the *actual* rounded shape
    /// (rather than a plain rectangle that's clipped afterwards) makes the system's
    /// edge lensing follow the rounded bottom curve — so the desktop visibly *bends*
    /// along the bottom lip, the native version of the Dynamic-Island refraction.
    var shape: AnyShape

    var body: some View {
        // Real Liquid Glass: `.glassEffect(.regular)` refracts + lenses the desktop
        // behind the transparent panel window, so the translucent lower region reads
        // as true glass (the iPhone Siri-overlay look), not a flat frost. The "back
        // panel" that looked like it came from here was actually the panel's separate
        // drop shadow (a wide `.shadow`) — that's removed at the call site, so the
        // real glass can stay without any stray plate behind it.
        Color.clear
            // Real Liquid Glass under the hood: `.glassEffect(.regular)` frosts,
            // blurs and lenses (refracts) the desktop behind the transparent window —
            // the native distortion of the iPhone Siri overlay. Drawn *in the notch
            // shape* so the lensing bends the wallpaper along the rounded bottom edge.
            .glassEffect(.regular, in: shape)
            // Lighten the glass *frost* over the lower panel. `.regular` glass carries
            // its own grey frost (~10% dim over a bright wallpaper); fading it toward the
            // bottom keeps that region reading as transparent glass — without the full
            // washout the `.clear` variant caused. Full glass is kept up top where the
            // black cap sits. But we hold a **gentle frost floor (~0.7) through the clear
            // bottom** rather than dropping to half: that residual glass is a small,
            // smooth backdrop blur that softens the busy wallpaper behind the panel's
            // content, so white text over the transparent region stays legible.
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .white,               location: 0.00),
                        .init(color: .white,               location: 0.58),
                        .init(color: .white.opacity(0.72), location: 0.82),
                        .init(color: .white.opacity(0.70), location: 1.00),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            // The Siri hood: a solid opaque black cap welded at the notch, held through
            // the top, then ramped down so the wallpaper shows through the glass toward
            // the bottom — "black at the top, transparent the further down you go".
            // (Kept substantial through the middle so the dark glass identity reads and
            // the player content stays legible; the `.clear` variant washed the whole
            // panel out and lost the theme, so we're back on `.regular` + this hood.)
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: Color.black,               location: 0.00),
                        .init(color: Color.black,               location: 0.30),
                        .init(color: Color.black.opacity(0.72), location: 0.54),
                        .init(color: Color.black.opacity(0.32), location: 0.78),
                        .init(color: Color.black.opacity(0.00), location: 1.00),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)
            }
            // (The faint drifting "Siri rainbow" prism at the top edge was removed on
            // request — no rainbow / chromatic dispersion anywhere on the glass.)
    }
}

/// The light fill for the whole expanded panel — a soft near-white top-to-bottom
/// wash matching the reference sheet, so dark-on-light content reads cleanly. Like
/// `GlassPanelSurface`, it fills its frame and is clipped to the notch silhouette
/// by the caller.
private struct LightPanelSurface: View {
    var body: some View {
        // Analogue-white: a flat, clean off-white gallery surface — monochrome,
        // with only the faintest fall-off for depth. Dark content reads on top; the
        // chrome stays pure black-and-white, mirroring the Noir treatment.
        LinearGradient(colors: [Color(white: 0.975), Color(white: 0.955)],
                       startPoint: .top, endPoint: .bottom)
    }
}

/// The deep near-black fill for the Noir theme's expanded panel. A flat, matte
/// near-black — no sheen, no accent wash, only the faintest top-to-bottom fall-off
/// for depth. The restraint is the point: an Analogue-minimal surface that stays
/// pure black-and-white, with no coloured accent competing with a
/// tinted background. Fills its frame; clipped to the notch silhouette by the
/// caller, exactly like the glass and light surfaces.
private struct NoirPanelSurface: View {
    var body: some View {
        ZStack {
            Color.black
            LinearGradient(
                colors: [Color(white: 0.055), Color(white: 0.028)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

/// A collapsed-state hover target: the pill's rect inset horizontally so the
/// panel only opens when the pointer is over the central notch region, not out
/// near the pill's edges. Height is left full so the thin strip stays easy to hit.
///
/// The active strip's reach from the notch center is then halved, so the panel
/// only arms when the pointer is genuinely over the central core of the notch
/// rather than anywhere within the (already inset) zone.
private struct CenteredHoverShape: Shape {
    var horizontalInset: CGFloat

    func path(in rect: CGRect) -> Path {
        let baseInset = min(horizontalInset, rect.width / 2 - 1)
        // Reach from center each side once inset, then tightened for a smaller,
        // more central trigger core.
        let reach = max(1, (rect.width / 2 - baseInset) * 0.35)
        let dx = rect.width / 2 - reach
        let r = rect.insetBy(dx: dx, dy: 0)
        return Path(roundedRect: r, cornerRadius: min(r.height / 2, 12), style: .continuous)
    }
}

/// The notch body silhouette, with animatable corner radii so it morphs smoothly
/// as the panel grows and shrinks.
///
/// - `weld` (notch present): the top edge stays full width and each top corner
///   *flares* down into the body with a curve that is tangent to the top edge —
///   so it meets the screen bezel seamlessly, with no visible corner at all.
///   (Same silhouette DynamicNotchKit uses.)
/// - otherwise (floating): a plain rounded card with all four corners rounded.
///
/// Either way there is never a hard 90° corner at the top.
struct NotchShape: InsettableShape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var weld: Bool
    var insetAmount: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func inset(by amount: CGFloat) -> some InsettableShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        var p = Path()

        if weld {
            // Full-width flat top; each top corner flares (tangent) into the body,
            // which is inset from the sides by `t`.
            let t = max(0, min(topRadius, r.width / 2))
            let b = max(0, min(bottomRadius, r.width / 2 - t, r.height - t))
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t),
                           control: CGPoint(x: r.minX + t, y: r.minY))
            p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
            p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY),
                           control: CGPoint(x: r.minX + t, y: r.maxY))
            p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
            p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b),
                           control: CGPoint(x: r.maxX - t, y: r.maxY))
            p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY),
                           control: CGPoint(x: r.maxX - t, y: r.minY))
            p.closeSubpath()
        } else {
            // Plain rounded card.
            let t = max(0, min(topRadius, r.width / 2, r.height / 2))
            let b = max(0, min(bottomRadius, r.width / 2, r.height / 2))
            p.move(to: CGPoint(x: r.minX, y: r.minY + t))
            p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY),
                           control: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + t),
                           control: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - b))
            p.addQuadCurve(to: CGPoint(x: r.maxX - b, y: r.maxY),
                           control: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX + b, y: r.maxY))
            p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - b),
                           control: CGPoint(x: r.minX, y: r.maxY))
            p.closeSubpath()
        }

        return p
    }
}

/// Reveals the panel content as the notch body expands: a top-anchored vertical
/// grow with a fade and a touch of blur that clears as it settles — so the content
/// appears to unfold out of the notch instead of popping in at full size.
private struct NotchUnfoldModifier: ViewModifier {
    /// 0 = folded into the notch, 1 = fully shown.
    let progress: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: 0.98 + 0.02 * progress,
                         y: 0.6 + 0.4 * progress,
                         anchor: .top)
            .opacity(progress)
            // Clamp: a bouncy spring can drive progress past 1, and a negative
            // blur radius is undefined.
            .blur(radius: max(0, (1 - progress) * 8))
    }
}
