import SwiftUI

extension View {
    /// The expanded panel body: a dark rounded card that hangs from the top of the
    /// screen (square top corners, rounded bottom) — matching the reference UI.
    /// Liquid Glass is reserved for the buttons, not this surface.
    func panelSurface() -> some View {
        // Square top corners so the panel sits flush against the top edge of the
        // screen (welded to the notch); only the bottom corners are rounded.
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: Metrics.panelCornerRadius,
            bottomTrailingRadius: Metrics.panelCornerRadius,
            topTrailingRadius: 0,
            style: .continuous
        )
        return self
            .background {
                shape.fill(
                    LinearGradient(
                        colors: [Color(white: 0.13), Color(white: 0.09)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
            .overlay {
                shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            }
            .clipShape(shape)
            .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
    }

    /// A softer inner "card" used for content blocks inside the panel.
    func innerCard(cornerRadius: CGFloat = Metrics.cardCornerRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background { shape.fill(Theme.cardFill) }
            .overlay { shape.strokeBorder(Theme.cardStroke, lineWidth: 1) }
            .clipShape(shape)
    }

    /// A Liquid Glass card whose colour comes from a **gradient scrim**, for surfaces
    /// that want to read as a colour (a weather tile's condition) rather than smoked
    /// black. Same `.regular` frosting + light-catching rim as `blackGlass`, and for
    /// the same reason it takes the colour from a scrim over the glass — a glass
    /// *tint* is silently dropped by the system above ~65pt (see `blackGlass`), which
    /// these tiles exceed. The scrim is opaque so white content stays legible over any
    /// desktop behind the panel; the glass shows as the frosted, refractive rim.
    func gradientGlass<S: Shape>(in shape: S, fill: LinearGradient, stroke: Double = 0.08) -> some View {
        self
            .background { shape.fill(fill) }   // colour — size-independent, unlike a glass tint
            .glassEffect(.regular, in: shape)  // frosting + refraction behind the scrim
            .overlay {
                shape.stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(stroke), Color.white.opacity(stroke * 0.35)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            }
    }

    /// A Liquid Glass content pane — a real translucent `.glassEffect` surface
    /// (not the flat `innerCard` fill) with a hairline edge, used to group
    /// settings rows into distinct frosted cards on the dark panel.
    ///
    /// The glass is **dark-tinted** so that, as a backdrop for white body text, it
    /// keeps well clear of the WCAG contrast floor — a plain `.regular` glass
    /// frosts too light and leaves the labels unreadable (see the panel's forced
    /// dark scheme in ``NotchSettingsView``).
    func glassCard(cornerRadius: CGFloat = Metrics.cardCornerRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .blackGlass(in: shape, stroke: 0.12)
    }

    /// A deep **"black Liquid Glass"** surface — the smoked, near-opaque black glass
    /// Apple uses for the iOS Siri overlay. The darkness lives in the glass *tint*
    /// (not a wash on top), so `.regular` keeps its signature refractive, light-
    /// catching rim that lenses the background through the edges. This is the single
    /// drop-in every glass surface in the app uses — buttons, cards, menus, the
    /// media player — so they all read as the same black glass.
    ///
    /// - `interactive`: the Liquid Glass press response (for buttons).
    /// - `tint`: overrides the black scrim for a *semantic* surface — a selected /
    ///   active state (pass the accent), a destructive control (`.red`), a coloured
    ///   mood note. `nil` gives the default smoked black.
    /// - `darkness`: opacity of the default black scrim (ignored when `tint` is set).
    /// - `stroke`: opacity of the light-catching rim (brightest at the top edge).
    /// - `glow`: a soft outer lift, for prominent cards like the player.
    ///
    /// Why a scrim instead of `.glassEffect(.regular.tint(.black))`: the system only
    /// honours a glass *tint* on surfaces under ~65pt tall — above that (or over a
    /// bright backdrop) it swaps to a heavier, *untintable* material, so tall bars
    /// and cards silently ignored the black tint. Instead we keep a plain `.regular`
    /// glass for the frosting / refraction / interactivity and take the darkness from
    /// a colour scrim layered *over* the glass but *behind* the content — which
    /// renders identically at any size. A manual gradient rim restores the light-
    /// catching edge the scrim would otherwise cover.
    func blackGlass<S: Shape>(
        in shape: S,
        interactive: Bool = false,
        tint: Color? = nil,
        darkness: Double = 0.55,
        stroke: Double = 0.18,
        glow: Bool = false
    ) -> some View {
        let glass: Glass = interactive ? .regular.interactive() : .regular
        let scrim: Color = tint ?? Color.black.opacity(darkness)
        return self
            .background { shape.fill(scrim) }   // darkness — size-independent, unlike a glass tint
            .glassEffect(glass, in: shape)      // frosting + refraction + press, behind the scrim
            .overlay {
                shape.stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(stroke), Color.white.opacity(stroke * 0.35)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            }
            .shadow(color: .black.opacity(glow ? 0.5 : 0), radius: glow ? 16 : 0, y: glow ? 8 : 0)
    }
}

/// A Liquid Glass button — real `.glassEffect` with an interactive press.
struct GlassButton<Label: View>: View {
    var shape: AnyShape = AnyShape(Capsule(style: .continuous))
    var tint: Color? = nil
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .blackGlass(in: shape, interactive: true, tint: tint)
        .linkCursor()
    }
}

// MARK: - Hover affordances

extension View {
    /// Pointer-hover feedback for *flat* (non-glass) interactive surfaces — the
    /// dark `innerCard` tiles, chips, swatches and small buttons that otherwise
    /// give no response at all. A subtle spring lift + brighten, plus the link
    /// cursor, so every clickable surface answers the pointer the way the Liquid
    /// Glass buttons already do with their `.interactive()` shimmer.
    func notchHover(scale: CGFloat = 1.04,
                    brighten: Double = 0.07,
                    cursor: PointerStyle = .link) -> some View {
        modifier(NotchHover(scale: scale, brighten: brighten, cursor: cursor))
    }

    /// Just the pointing-hand cursor — for Liquid Glass buttons, which already
    /// carry their own hover shimmer via `.interactive()` and only lack the
    /// "this is clickable" cursor.
    func linkCursor() -> some View {
        pointerStyle(.link)
    }
}

// MARK: - Drag support in the non-activating panel

extension View {
    /// Makes the host panel window *key* as soon as the pointer enters this view, so
    /// a `DragGesture` inside it actually tracks. The notch panel is a
    /// `.nonactivatingPanel` that only becomes key on demand — AppKit still delivers
    /// the initial mouse-down to a non-key panel (so `NSButton`s click, since they
    /// accept first-mouse), but it does *not* deliver the follow-up `mouseDragged`
    /// events a raw drag needs, so sliders/scrubbers wouldn't move. Grabbing key on
    /// enter (the pointer is always over the control before it presses) fixes that,
    /// scoped so the panel only takes key when you're about to drag, never while idle.
    /// Mirrors the Mood board's `PanelKeyGrabber`.
    func grabsWindowKeyForDrag() -> some View {
        background(WindowKeyGrabber().allowsHitTesting(false))
    }
}

private struct WindowKeyGrabber: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { KeyOnHoverView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class KeyOnHoverView: NSView {
        private var tracking: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self, userInfo: nil
            )
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) { window?.makeKey() }
    }
}

/// The lift/brighten half of ``notchHover``. Kept as a modifier so the hover
/// state (and its spring) is owned per-view rather than by every call site.
private struct NotchHover: ViewModifier {
    let scale: CGFloat
    let brighten: Double
    let cursor: PointerStyle
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .brightness(hovering ? brighten : 0)
            .scaleEffect(hovering ? scale : 1)
            .animation(.spring(response: 0.26, dampingFraction: 0.72), value: hovering)
            .onHover { hovering = $0 }
            .pointerStyle(cursor)
    }
}
