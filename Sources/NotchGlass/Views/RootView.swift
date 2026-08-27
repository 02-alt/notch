import SwiftUI
import UniformTypeIdentifiers

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
        guard vm.isOpen else { return vm.collapsedSize }
        if isMoodBig {
            return CGSize(width: Metrics.moodExpandedWidth, height: Metrics.moodExpandedHeight)
        }
        return CGSize(width: openWidth, height: Metrics.bodyHeight(for: vm.selectedTab, showingSettings: vm.showSettings, settingsCategory: vm.settingsCategory))
    }

    /// Bottom corner radius grows with the body so the pill's tight curve opens
    /// out into the panel's softer corners.
    private var bottomRadius: CGFloat {
        vm.isOpen ? Metrics.panelCornerRadius : min(vm.collapsedSize.height / 2, 12)
    }

    /// Top corner radius: the *flare* radius. Kept small (12pt) even on a non-notch
    /// screen so the expanded panel keeps a near-flat top and still reads as a notch
    /// panel — not a fully-rounded card. Within the panel's 14pt padding so it never
    /// clips content.
    private var topRadius: CGFloat {
        vm.isOpen ? 12 : min(vm.collapsedSize.height / 2, 8)
    }

    /// The notch body outline.
    ///
    /// The **collapsed pill always welds** (flat full-width top) so it reads as a
    /// notch on every display, notch or not — that's the app's signature.
    ///
    /// The **expanded panel only welds on a real notch**. Welding gives a flat
    /// full-width top; on a display *without* a notch the wide panel floats below
    /// the screen edge, so that full-width top juts out past the (slightly inset)
    /// body as black bars on the sides. There we float a plain rounded card instead
    /// — no bars — while a real notch still hangs the panel from the top.
    private var bodyShape: NotchShape {
        let weld = vm.isOpen ? vm.hasNotch : true
        return NotchShape(topRadius: topRadius, bottomRadius: bottomRadius, weld: weld)
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
            GlassPanelSurface()
                .opacity(glassActive ? 1 : 0)
            LightPanelSurface()
                .opacity(lightActive ? 1 : 0)
            NoirPanelSurface()
                .opacity(noirActive ? 1 : 0)
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
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
                CollapsedMediaView(size: vm.collapsedSize)
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
                    // outside and read as a faint second outline at the corners.
                    bodyShape
                        .strokeBorder(
                            LinearGradient(
                                colors: [.clear, .clear, Color.white.opacity(0.38)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1.5
                        )
                        .allowsHitTesting(false)
                }
            }
            // Accent outline + glow while a document is being dragged over the
            // notch, so the whole panel visibly "arms" for the drop.
            .overlay {
                bodyShape.strokeBorder(settings.accent.opacity(vm.dragActive ? 0.9 : 0), lineWidth: 2)
            }
            .shadow(color: .black.opacity(vm.isOpen ? 0.5 : 0),
                    radius: vm.isOpen ? 18 : 0,
                    y: vm.isOpen ? 8 : 0)
            .shadow(color: settings.accent.opacity(vm.dragActive ? 0.45 : 0),
                    radius: vm.dragActive ? 16 : 0)
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
               height: Metrics.windowContentHeight + Metrics.openTopGap,
               alignment: .top)
        // One animation drives the whole morph — frame, corner radius, surface,
        // stroke, shadow and the content reveal all move together.
        .animation(vm.isOpen ? Metrics.openSpring : Metrics.closeSpring, value: vm.isOpen)
        .animation(Metrics.openSpring, value: settings.panelTheme)
        .animation(Metrics.openSpring, value: vm.showSettings)
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
/// Why a black→clear gradient over real glass, not a flat glass tint: a glass tint
/// is one flat colour and the system drops it on tall surfaces anyway (see
/// `blackGlass`), so it can't give the opaque-top / clear-bottom ramp that defines
/// this look. We keep a plain `.regular` glass for the frost + bottom-edge
/// refraction and take the hood from a vertical black gradient over it.
private struct GlassPanelSurface: View {
    var body: some View {
        Color.clear
            // Real glass under the hood: frosts + refracts the desktop in the
            // translucent lower region and lenses the rounded bottom edge.
            .glassEffect(.regular, in: Rectangle())
            // The hood: solid opaque black at the notch, held through the top third,
            // then ramped to fully clear so the wallpaper shows through the bottom.
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
            // A whisper of chromatic dispersion on the black glass near the notch —
            // the Siri rainbow, kept faint and drifting so slowly it never catches
            // the eye; you notice it only if you look for it.
            .overlay(alignment: .top) {
                PrismStreak()
                    .padding(.top, 8)   // pinned to the top edge of the black glass
                    .allowsHitTesting(false)
            }
    }
}

/// The chromatic-dispersion highlight: a soft, low-opacity spectrum that drifts
/// sideways on a very slow, gentle oscillation (~1-minute round trip) so it reads
/// as a living glint on the glass rather than an animation demanding attention.
private struct PrismStreak: View {
    // Starts offset a touch to one side; the repeating ease drifts it to the other
    // and back. Kept small so it always reads centered — just barely alive.
    @State private var drift: CGFloat = -9

    var body: some View {
        LinearGradient(
            colors: [
                .clear,
                Color(red: 1.00, green: 0.30, blue: 0.34),   // red
                Color(red: 1.00, green: 0.74, blue: 0.24),   // amber
                Color(red: 0.55, green: 1.00, blue: 0.48),   // green
                Color(red: 0.32, green: 0.72, blue: 1.00),   // cyan-blue
                Color(red: 0.70, green: 0.40, blue: 1.00),   // violet
                .clear,
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: 300, height: 6)
        .blur(radius: 4)
        .opacity(0.38)             // faint, but actually visible on the black glass
        .blendMode(.plusLighter)
        .offset(x: drift)
        .onAppear {
            withAnimation(.easeInOut(duration: 30).repeatForever(autoreverses: true)) {
                drift = 9
            }
        }
    }
}

/// The light fill for the whole expanded panel — a soft near-white top-to-bottom
/// wash matching the reference sheet, so dark-on-light content reads cleanly. Like
/// `GlassPanelSurface`, it fills its frame and is clipped to the notch silhouette
/// by the caller.
private struct LightPanelSurface: View {
    var body: some View {
        // Analogue-white: a flat, clean off-white gallery surface — near-monochrome,
        // with only the faintest fall-off for depth. Dark content reads on top; the
        // ember stays a rare deliberate accent, mirroring the Noir treatment.
        LinearGradient(colors: [Color(white: 0.975), Color(white: 0.955)],
                       startPoint: .top, endPoint: .bottom)
    }
}

/// The deep near-black fill for the Noir theme's expanded panel. A flat, matte
/// near-black — no sheen, no accent wash, only the faintest top-to-bottom fall-off
/// for depth. The restraint is the point: an Analogue-minimal surface where the
/// (muted) ember accent is the single deliberate colour, not competing with a
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
