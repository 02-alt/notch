import SwiftUI

/// Settings rendered *inside* the notch panel (the panel grows taller to fit).
///
/// Layout follows the spacing-first reference sheet: related controls collected
/// under a plain, letter-spaced section label, and then **one setting per card** —
/// each row is its own softly-filled rounded rectangle floating on the dark panel
/// with a generous, uniform internal margin, rather than a run of rows crammed into
/// a single pane and split by hairline dividers. The result reads as a calm,
/// evenly-spaced grid: label leading, control trailing on a comfortable baseline,
/// secondary captions tucked inside the same card where a control needs explaining.
struct NotchSettingsView: View {
    @EnvironmentObject private var vm: NotchViewModel
    @EnvironmentObject private var settings: SettingsStore

    /// The single spacing unit the whole sheet is built on — gaps between cards,
    /// header-to-content, and column gutters are all multiples of it, so nothing
    /// sits on an ad-hoc margin.
    private let unit: CGFloat = 8

    var body: some View {
        VStack(spacing: 16) {
            header
            categorySelector
            categoryContent
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.primaryText)
        .tint(settings.accent)
        // Pin the settings subtree to the theme's appearance so materials and glass
        // controls render legibly (dark-on-light for the Light theme) regardless of
        // the user's system appearance.
        .environment(\.colorScheme, Theme.colorScheme)
    }

    // MARK: - Category content

    /// Two balanced columns of groups for the selected category. A gentle
    /// fade/slide keeps the swap from snapping as the panel resizes to the new
    /// category's height.
    @ViewBuilder private var categoryContent: some View {
        HStack(alignment: .top, spacing: 16) {
            switch vm.settingsCategory {
            case .general:
                column { generalGroup; fuelGroup }
                column { aboutGroup }
            case .appearance:
                column { themeGroup }
                column { styleGroup }
            case .media:
                column { sourcesGroup }
                column { displayGroup }
            case .notch:
                column { idleGroup }
                column { peeksGroup }
            }
        }
        .id(vm.settingsCategory)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// One equal-width, top-aligned settings column.
    private func column<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 16) {
            content()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Groups

    private var generalGroup: some View {
        settingsGroup("General") {
            SettingRow("Launch at login") {
                NotchToggle(isOn: $settings.launchAtLogin, accent: settings.accent)
            }
            SettingRow("Default tab") {
                defaultTabPicker
            }
            sliderRow("Close delay", value: $settings.closeDelay,
                      range: 0...1, label: String(format: "%.2fs", settings.closeDelay),
                      caption: "Wait before the panel collapses on exit.")
        }
    }

    /// Fuel tab cadence. Faster = more live but likelier to hit the provider's rate
    /// limit, so it's opt-in and defaults to the safe Normal.
    private var fuelGroup: some View {
        settingsGroup("Fuel") {
            SettingRow("Update rate", caption: fuelRateCaption) {
                fuelRatePicker
            }
        }
    }

    private var fuelRateCaption: String {
        switch settings.fuelRefreshRate {
        case .live:    return "Refreshes every 5s while the Fuel tab is open — snappiest, but likelier to be rate-limited."
        case .normal:  return "Refreshes every 30s while the Fuel tab is open. Recommended."
        case .relaxed: return "Refreshes every 60s while the Fuel tab is open — lightest touch on the usage endpoint."
        }
    }

    /// White-text menu (the system `.menu` picker renders black-on-dark here) for the
    /// Fuel refresh cadence.
    private var fuelRatePicker: some View {
        Menu {
            ForEach(FuelRefreshRate.allCases) { option in
                Button {
                    settings.fuelRefreshRate = option
                } label: {
                    Label(option.title, systemImage: option.symbol)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: settings.fuelRefreshRate.symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                Text(settings.fuelRefreshRate.title)
                    .foregroundStyle(Theme.primaryText)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .blackGlass(in: Capsule(), interactive: true)
        .linkCursor()
    }

    private var aboutGroup: some View {
        settingsGroup("About") {
            SettingRow("Version") {
                Text(Updater.currentVersion)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
            }
            SettingRow("Release notes") {
                Button("What's New") {
                    withAnimation(Metrics.openSpring) { vm.showSettings = false }
                    vm.presentWhatsNew()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(settings.accent)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .blackGlass(in: Capsule(), interactive: true)
                .linkCursor()
            }
            HStack(spacing: unit) {
                glassAction("Check for Updates", systemImage: "arrow.triangle.2.circlepath") {
                    Updater.checkForUpdates()
                }
                glassAction("Quit", systemImage: "power", tint: .red) {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private var themeGroup: some View {
        settingsGroup("Theme") {
            themeSwatches
        }
    }

    private var styleGroup: some View {
        settingsGroup("Style") {
            SettingColumn("Accent color") {
                accentSwatches
            }
            sliderRow("Panel width", value: $settings.panelWidth,
                      range: 460...900, step: 10, label: "\(Int(settings.panelWidth))")
        }
    }

    /// Media tab, left column — where now-playing is read from. The heavier of the
    /// two media groups (segmented control + app chips), so it leads.
    private var sourcesGroup: some View {
        settingsGroup("Sources") {
            SettingColumn("Preferred source",
                          caption: "Which player wins when both are playing.") {
                segmented
            }
            SettingColumn("Read from",
                          caption: "Only enabled apps are accessed — each asks for permission once.") {
                sourcesPicker
            }
        }
    }

    /// Media tab, right column — how the current track is shown.
    private var displayGroup: some View {
        settingsGroup("Display") {
            SettingRow("Show artwork",
                       caption: "Show album art on the Media tab and the closed notch.") {
                NotchToggle(isOn: $settings.showArtwork, accent: settings.accent)
            }
        }
    }

    /// Notch tab, left column — the quiet resting glance shown when nothing else
    /// is happening. (Formerly buried in the Media tab as "Collapsed notch".)
    private var idleGroup: some View {
        settingsGroup("When idle") {
            SettingRow("Show", caption: restingCaption) {
                restingPicker
            }
        }
    }

    /// Notch tab, right column — things that momentarily appear on the closed
    /// notch: the now-playing peek and transient Fuel notices.
    private var peeksGroup: some View {
        settingsGroup("Live peeks") {
            SettingRow("Now playing") {
                NotchToggle(isOn: $settings.collapsedShowsMedia, accent: settings.accent)
            }
            SettingRow("Fuel events",
                       caption: "Flash a notice in the notch when your Claude fuel refills or runs low. Checks your usage periodically in the background.") {
                NotchToggle(isOn: $settings.collapsedShowsFuelEvents, accent: settings.accent)
            }
        }
    }

    /// Caption under the idle-glance picker — explains the plain default, and warns
    /// that the live stats (Fuel / Battery) read a source in the background.
    private var restingCaption: String {
        switch settings.collapsedResting {
        case .none:    return "What the closed notch shows when nothing’s playing."
        case .clock:   return "Shows the time on the closed notch when nothing’s playing."
        case .fuel:    return "Shows your Claude fuel left on the closed notch. Checks your usage periodically in the background."
        case .battery: return "Shows this Mac’s battery on the closed notch when nothing’s playing."
        }
    }

    /// White-text menu (the system `.menu` picker renders black-on-dark here) for the
    /// resting glance shown on the closed notch.
    private var restingPicker: some View {
        Menu {
            ForEach(CollapsedResting.allCases) { option in
                Button {
                    settings.collapsedResting = option
                } label: {
                    Label(option.title, systemImage: option.symbol)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: settings.collapsedResting.symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                Text(settings.collapsedResting.title)
                    .foregroundStyle(Theme.primaryText)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .blackGlass(in: Capsule(), interactive: true)
        .linkCursor()
    }

    // MARK: - Category selector

    /// The broad-category picker at the top of Settings — a full-width segmented
    /// pill bar. Switching a pill swaps the visible groups and springs the panel to
    /// that category's height, so the user never faces one giant scroll of settings.
    private var categorySelector: some View {
        HStack(spacing: 4) {
            ForEach(SettingsCategory.allCases) { category in
                categoryPill(category)
            }
        }
        .padding(3)
        .background(Capsule(style: .continuous).fill(Theme.line(0.07)))
        .overlay(Capsule(style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 1))
    }

    private func categoryPill(_ category: SettingsCategory) -> some View {
        let selected = vm.settingsCategory == category
        return Button {
            withAnimation(Metrics.openSpring) { vm.settingsCategory = category }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: category.symbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(category.title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(selected ? settings.accent.readableForeground : Theme.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background {
            if selected { Capsule(style: .continuous).fill(settings.accent) }
        }
        .notchHover(scale: 1.03)
        .accessibilityLabel("\(category.title) settings")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(Metrics.openSpring) { vm.showSettings = false }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                    .frame(width: 30, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .blackGlass(in: Capsule(), interactive: true)
            .linkCursor()
            .accessibilityLabel("Back")

            Text("Settings")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.primaryText)

            Spacer()

            Text("All in a notch")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.tertiaryText)
        }
    }

    // MARK: - Group + row scaffolding

    /// One section: a plain, letter-spaced label above its stack of setting cards.
    /// The label is quiet on purpose — the cards carry the visual weight — matching
    /// the reference sheet's calm "PATH" / "FONT STYLE" headers.
    private func settingsGroup<C: View>(_ title: String,
                                        @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.tertiaryText)
                .kerning(0.8)
                .padding(.leading, 4)

            VStack(spacing: unit) { content() }
        }
    }

    /// A secondary caption tucked inside a setting card, below its control.
    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(Theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A label + trailing control on one baseline — the standard settings row —
    /// wrapped in its own softly-filled card. An optional caption drops onto a
    /// second line inside the same card.
    private func SettingRow<Control: View>(_ title: String, caption captionText: String? = nil,
                                           @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 8)
                control()
            }
            .frame(minHeight: 24)
            if let captionText { caption(captionText) }
        }
        .settingsCard()
    }

    /// A label (with optional caption) above a full-width control — used where the
    /// control is too wide to sit trailing (swatches, the segmented picker). Also
    /// carded, so it sits on the same grid as the single-line rows.
    private func SettingColumn<Control: View>(_ title: String, caption captionText: String? = nil,
                                              @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
            control()
            if let captionText { caption(captionText) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsCard()
    }

    private func sliderRow(_ title: String, value: Binding<Double>,
                           range: ClosedRange<Double>, step: Double = 0.01,
                           label: String, caption captionText: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                NotchSlider(value: value, range: range, step: step, accent: settings.accent)
                Text(label)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 46, alignment: .trailing)
            }
            .frame(minHeight: 24)
            if let captionText { caption(captionText) }
        }
        .settingsCard()
    }

    // MARK: - Media source picker

    /// Media apps actually installed on this Mac — the only ones worth offering.
    private var installedSources: [MediaSource] {
        MediaSource.allCases.filter {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil
        }
    }

    /// Toggle chips for each installed player/browser. Tapping one enables or
    /// disables NotchGlass reading it — disabled apps are never contacted, so they
    /// never trigger a macOS Automation prompt.
    private var sourcesPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(installedSources, id: \.self) { src in
                    let on = settings.isSourceEnabled(src)
                    Button {
                        settings.setSource(src, enabled: !on)
                    } label: {
                        HStack(spacing: 5) {
                            if let icon = src.appIcon {
                                Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                            }
                            Text(src.displayName)
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(on ? settings.accent.readableForeground : Theme.secondaryText)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background {
                            Capsule(style: .continuous)
                                .fill(on ? settings.accent : Theme.line(0.08))
                        }
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(Theme.cardStroke, lineWidth: on ? 0 : 1)
                        }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .notchHover(scale: 1.04)
                }
            }
            .padding(.horizontal, 1)
        }
    }

    // MARK: - Default-tab picker

    /// White-text menu (the system `.menu` picker renders black text on this dark
    /// card — invisible). Only offers tabs actually in the bar, so the default
    /// can't point at a tab the user has removed.
    private var defaultTabPicker: some View {
        Menu {
            ForEach(settings.enabledTabs) { tab in
                Button(tab.title) { settings.defaultTab = tab }
            }
        } label: {
            HStack(spacing: 5) {
                Text(settings.defaultTab.title)
                    .foregroundStyle(Theme.primaryText)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .blackGlass(in: Capsule(), interactive: true)
        .linkCursor()
    }

    // MARK: - Visual theme picker

    /// Selectable *preview tiles*, one per theme, so the choice is made by eye
    /// rather than by reading a label: each tile renders a live miniature of the
    /// panel in that theme over a faux desktop, so the difference between the
    /// opaque Solid card and the see-through Liquid Glass surface is visible at a
    /// glance. Replaces the old text-only pop-up menu.
    private var themeSwatches: some View {
        HStack(spacing: 10) {
            ForEach(PanelTheme.allCases) { theme in
                themeTile(theme)
            }
        }
    }

    /// The accent each tile previews. The Analogue themes hint their rare ember
    /// (Noir) or their dark monochrome chrome (Light); the others show the user's
    /// configured accent.
    private func previewAccent(for theme: PanelTheme) -> Color {
        switch theme {
        case .noir:  return Theme.ember
        case .light: return Color(white: 0.16)
        default:     return settings.accent
        }
    }

    private func themeTile(_ theme: PanelTheme) -> some View {
        let selected = settings.panelTheme == theme
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                settings.panelTheme = theme
            }
        } label: {
            VStack(spacing: 8) {
                ThemePreview(theme: theme, accent: previewAccent(for: theme))
                    .frame(height: 52)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                HStack(spacing: 6) {
                    Image(systemName: theme.symbol)
                        .font(.system(size: 10, weight: .semibold))
                    Text(theme.title)
                        .font(.system(size: 11, weight: .semibold))
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 12))
                        .foregroundStyle(selected ? settings.accent : Theme.tertiaryText)
                }
                .foregroundStyle(selected ? Theme.primaryText : Theme.secondaryText)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(Theme.line(selected ? 0.07 : 0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(selected ? settings.accent : Theme.line(0.10),
                                  lineWidth: selected ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
        .notchHover(scale: 1.02, brighten: 0.05)
        .accessibilityLabel("\(theme.title) theme")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Media source segmented control

    /// A custom segmented control — the system `.segmented` picker renders dark
    /// text on a light track that's unreadable on this dark panel. The selected
    /// segment uses the accent with a luminance-matched text color for contrast.
    private var segmented: some View {
        HStack(spacing: 4) {
            segment("Spotify", .spotify)
            segment("Apple Music", .music)
        }
        .padding(3)
        .background(
            Capsule(style: .continuous).fill(Theme.line(0.07))
        )
        .overlay(
            Capsule(style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 1)
        )
    }

    private func segment(_ label: String, _ value: MediaSource) -> some View {
        let selected = settings.mediaPriority == value
        return Button {
            settings.mediaPriority = value
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? settings.accent.readableForeground : Theme.secondaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background {
            if selected {
                Capsule(style: .continuous).fill(settings.accent)
            }
        }
        .notchHover(scale: 1.04)
    }

    // MARK: - Actions

    private func glassAction(_ title: String, systemImage: String,
                             tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .blackGlass(
            in: Capsule(),
            interactive: true, tint: tint.map { $0.opacity(0.5) }
        )
        .linkCursor()
    }

    // MARK: - Accent swatches

    /// Preset accent choices. Tapping one writes the hex straight into the store,
    /// so it works reliably inside the auto-closing notch (unlike the system
    /// ColorPicker, whose separate window dies when the panel collapses).
    private static let accentChoices = [
        "4C84FA", // blue
        "7C5CFF", // purple
        "FF5C7A", // pink
        "FF8A3D", // orange
        "F5C518", // yellow
        "39C463", // green
        "22C1C3", // teal
        "E7E7EA"  // neutral
    ]

    private var accentSwatches: some View {
        HStack(spacing: 9) {
            ForEach(Self.accentChoices, id: \.self) { hex in
                let selected = settings.accentHex.uppercased() == hex
                Circle()
                    .fill(Color(hex: hex) ?? .white)
                    .frame(width: 20, height: 20)
                    .overlay(
                        Circle().strokeBorder(Theme.primaryText, lineWidth: selected ? 2 : 0)
                    )
                    .overlay(
                        Circle().strokeBorder(Theme.line(0.15), lineWidth: 1)
                    )
                    .scaleEffect(selected ? 1.12 : 1)
                    .contentShape(Circle())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                            settings.accentHex = hex
                        }
                    }
                    .notchHover(scale: 1.22)
                    .accessibilityLabel("Accent \(hex)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Setting card

private extension View {
    /// The soft, individually-floating card each setting sits in — a subtle fill
    /// with a hairline edge and a generous, uniform internal margin. This is the
    /// heart of the reference layout: one setting per card, evenly spaced, rather
    /// than a run of rows split by dividers inside a single pane.
    func settingsCard() -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return self
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(Theme.cardFill))
            .overlay(shape.strokeBorder(Theme.cardStroke, lineWidth: 1))
    }
}

/// A high-contrast switch for the dark panel. Off shows a clearly visible track
/// (not grey-on-grey); on uses the accent. The knob is always white.
private struct NotchToggle: View {
    @Binding var isOn: Bool
    let accent: Color

    private let w: CGFloat = 42
    private let h: CGFloat = 24
    private let knob: CGFloat = 18

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? accent : Theme.line(0.22))
                    .overlay(Capsule().strokeBorder(Theme.line(0.12), lineWidth: 1))
                    .frame(width: w, height: h)
                Circle()
                    .fill(.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                    .padding(3)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isOn)
        .linkCursor()
    }
}

/// A high-contrast slider for the dark panel: a visible track, an accent-filled
/// portion and a white knob — the system slider renders grey-on-grey here.
private struct NotchSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0
    let accent: Color

    private let knob: CGFloat = 14
    /// Grows the knob a touch while the pointer is over the track.
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let span = range.upperBound - range.lowerBound
            let frac = span > 0 ? (value - range.lowerBound) / span : 0
            let clamped = min(max(frac, 0), 1)
            let usable = max(0, geo.size.width - knob)

            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line(0.16))
                    .frame(height: 4)
                Capsule().fill(accent)
                    .frame(width: knob / 2 + usable * clamped, height: 4)
                Circle().fill(.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                    .scaleEffect(hovering ? 1.25 : 1)
                    .offset(x: usable * clamped)
            }
            .frame(height: knob)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: hovering)
            .onHover { hovering = $0 }
            .pointerStyle(.grabIdle)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard usable > 0 else { return }
                        let raw = min(max((g.location.x - knob / 2) / usable, 0), 1)
                        var v = range.lowerBound + raw * span
                        if step > 0 { v = (v / step).rounded() * step }
                        value = min(max(v, range.lowerBound), range.upperBound)
                    }
            )
        }
        .frame(height: 18)
    }
}

/// A miniature of the notch panel, rendered in a given theme over a faux colorful
/// desktop — the thumbnail inside each theme tile. The whole point is to make the
/// theme choice *visible*: in `.noir` the mini panel is a deep black card that
/// hides the wallpaper; in `.glass` it's a translucent frosted surface the
/// wallpaper bleeds through, exactly the distinction the real panel makes.
private struct ThemePreview: View {
    let theme: PanelTheme
    let accent: Color

    var body: some View {
        ZStack(alignment: .top) {
            // Faux desktop wallpaper — a saturated diagonal wash so the glass
            // theme's translucency (and the solid theme's opacity) read clearly.
            LinearGradient(
                colors: [
                    Color(hex: "3B6FF0") ?? .blue,
                    Color(hex: "8B5CF6") ?? .purple,
                    Color(hex: "F0518A") ?? .pink
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            miniPanel
                .padding(.horizontal, 12)
                .padding(.top, 9)
        }
    }

    /// The little panel hanging from the top: a mock tab strip plus a couple of
    /// content bars, filled per the theme (opaque gradient vs. frosted material).
    private var miniPanel: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        // The mock content is white on the dark themes, dark on the Light theme —
        // so each tile previews its own foreground contrast, not just its surface.
        let bar = theme == .light ? Color.black : Color.white
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Capsule().fill(accent).frame(width: 16, height: 5)
                Capsule().fill(bar.opacity(0.28)).frame(width: 10, height: 5)
                Capsule().fill(bar.opacity(0.28)).frame(width: 10, height: 5)
            }
            RoundedRectangle(cornerRadius: 2).fill(bar.opacity(0.24)).frame(height: 6)
            RoundedRectangle(cornerRadius: 2).fill(bar.opacity(0.16))
                .frame(width: 42, height: 6)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            switch theme {
            case .glass:
                // Mirror the panel's Siri hood: a solid black cap at the top that
                // ramps to fully clear over frosted glass, so the tile's backdrop
                // shows through the bottom, with a bright refractive bottom lip.
                shape.fill(.ultraThinMaterial)
                    .overlay {
                        shape.fill(
                            LinearGradient(
                                stops: [
                                    .init(color: Color.black,               location: 0.00),
                                    .init(color: Color.black,               location: 0.30),
                                    .init(color: Color.black.opacity(0.55), location: 0.62),
                                    .init(color: Color.black.opacity(0.00), location: 1.00),
                                ],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                    }
                    .overlay {
                        shape.stroke(
                            LinearGradient(colors: [.clear, .clear, Color.white.opacity(0.4)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 1
                        )
                    }
                    .overlay(alignment: .top) {
                        // The faint Siri rainbow, static in the miniature.
                        LinearGradient(
                            colors: [.clear,
                                     Color(red: 1.0, green: 0.34, blue: 0.38),
                                     Color(red: 0.55, green: 1.0, blue: 0.48),
                                     Color(red: 0.32, green: 0.72, blue: 1.0),
                                     .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(height: 2)
                        .blur(radius: 1.4)
                        .opacity(0.4)
                        .blendMode(.plusLighter)
                        .padding(.top, 4)
                    }
            case .light:
                shape.fill(
                    LinearGradient(colors: [Color(white: 0.99), Color(white: 0.95)],
                                   startPoint: .top, endPoint: .bottom)
                )
            case .noir:
                shape.fill(
                    LinearGradient(colors: [Color(white: 0.07), Color(white: 0.025)],
                                   startPoint: .top, endPoint: .bottom)
                )
            }
        }
        .overlay { shape.strokeBorder(bar.opacity(0.14), lineWidth: 1) }
        .clipShape(shape)
        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
    }
}
