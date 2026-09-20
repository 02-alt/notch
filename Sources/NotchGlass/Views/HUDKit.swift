import SwiftUI

/// The shared design-system layer for the notch panel — the pieces every tab draws
/// from so the whole app reads as one system (Apple HIG: consistency, hierarchy,
/// craft). Colours stay in ``Theme``/`settings.accent`; this is layout, typography,
/// components and motion only.
///
/// Adopt these instead of hand-rolling a card/label/meter per tab:
/// - `.hudCard()` — the one borderless translucent surface.
/// - `HUDSectionHeader` — the kerned section caption at the top of a tab.
/// - `GlowBar` — the one continuous progress/level indicator.
/// - `HUDIconButton` — a round icon button with a proper 28pt+ target and hover.
enum HUD {
    /// Corner radii — a small, consistent set instead of ad-hoc per view.
    static let cardRadius: CGFloat = 16
    static let heroRadius: CGFloat = 20
    static let chipRadius: CGFloat = 10

    /// The standard card surface fill — a soft translucent white, borderless. One value
    /// so every card sits at the same depth on the dark stage. Kept high enough that the
    /// card reads clearly against the near-black immersive stage (0.06 was too faint).
    static let cardFill = Color.white.opacity(0.11)
}

extension View {
    /// The one borderless card surface used across the app: a soft translucent fill with
    /// consistent rounding and padding, no hairline stroke. Pass `hero: true` for the
    /// larger radius used by a tab's primary/featured block.
    func hudCard(hero: Bool = false, padding: CGFloat = Spacing.lg) -> some View {
        let radius = hero ? HUD.heroRadius : HUD.cardRadius
        return self
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(HUD.cardFill)
            }
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// The kerned, high-contrast caption that heads a tab (e.g. "SESSION FUEL"), optionally
/// with a trailing accessory (a count, a control). HIG: clear hierarchy, direct labels.
struct HUDSectionHeader<Accessory: View>: View {
    let title: String
    var trailingText: String?
    @ViewBuilder var accessory: () -> Accessory

    init(_ title: String, trailingText: String? = nil,
         @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.title = title
        self.trailingText = trailingText
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .kerning(0.6)
                .foregroundStyle(Theme.secondaryText)
            if let trailingText {
                Text(trailingText)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            accessory()
        }
    }
}

/// A round icon button with a comfortable ≥28pt target, instant press feedback and the
/// app's hover reaction — the single control for a tab's header actions.
struct HUDIconButton: View {
    let symbol: String
    var help: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.primaryText)
                .frame(width: 28, height: 28)
                .background { Circle().fill(Theme.line(0.10)) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .notchHover(scale: 1.08)
        .help(help)
    }
}

/// A continuous, glowing progress bar — the unified fuel/level/progress indicator across
/// the app. A rounded track holds a rounded fill that blooms a soft coloured glow, so
/// every metric reads with one borderless language. `fill` can be a solid colour or a
/// gradient; `glow` colours the bloom.
struct GlowBar: View {
    var fraction: Double
    var fill: AnyShapeStyle
    var glow: Color
    var height: CGFloat = 8

    /// Convenience for the common solid-colour case (fill and glow the same colour).
    init(fraction: Double, color: Color, height: CGFloat = 8) {
        self.fraction = fraction
        self.fill = AnyShapeStyle(color)
        self.glow = color
        self.height = height
    }

    init(fraction: Double, fill: AnyShapeStyle, glow: Color, height: CGFloat = 8) {
        self.fraction = fraction
        self.fill = fill
        self.glow = glow
        self.height = height
    }

    var body: some View {
        GeometryReader { geo in
            let f = min(1, max(0, fraction))
            let width = f <= 0 ? 0 : max(height, geo.size.width * f)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(fill)
                    .frame(width: width)
                    .shadow(color: glow.opacity(0.65), radius: height * 0.8)
                    .shadow(color: glow.opacity(0.30), radius: height * 1.8)
            }
            .animation(.snappy(duration: 0.45), value: f)
        }
        .frame(height: height)
    }
}
