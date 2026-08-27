import SwiftUI

/// Token-management ("fuel") dashboard for Claude usage. Mirrors the reference
/// instrument-panel layout: a big segmented level meter for the current session's
/// remaining fuel, then a grid of stat readouts (weekly, resets, token counts).
///
/// Live utilization comes from Claude Code's OAuth usage endpoint (`FuelManager`);
/// the token counts are read from the local CLI transcripts.
struct FuelTabView: View {
    @EnvironmentObject private var fuel: FuelManager
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var vm: NotchViewModel
    @EnvironmentObject private var glassMenu: GlassMenuController

    /// Window-space frames of the header picker and the "+" add-block tile, so their
    /// menus drop from just below them.
    @State private var providerFrame: CGRect = .zero
    @State private var addBlockFrame: CGRect = .zero

    // MARK: Drag-to-reorder state
    /// The block the user is currently dragging (nil when idle).
    @State private var draggingBlock: FuelBlock?
    /// Live finger position in the "fuelGrid" coordinate space, for the drag avatar.
    @State private var dragLocation: CGPoint = .zero
    /// Frame of each visible block's card in the "fuelGrid" space — used to hit-test
    /// the drop target as the finger moves over the heterogeneous (big + grid) layout.
    @State private var slotFrames: [FuelBlock: CGRect] = [:]
    /// The block the drop is currently hovering over, highlighted as the landing spot.
    @State private var dropTarget: FuelBlock?

    private var s: FuelState { fuel.state }
    private var accent: Color { settings.accent }

    /// Remaining session fuel (0…1). The meter and headline read from this.
    private var remaining: Double { max(0, 1 - s.sessionUsed) }
    /// A fresh, connected reading. Drives the green status dot.
    private var hasLive: Bool { s.connected && s.sessionResetsAt != nil }
    /// We have a real reading to draw — even if it's a stale one held through a
    /// transient rate-limit. The gauge stays visible in that case.
    private var showsGauge: Bool { s.hasReading }
    /// A held reading during a recoverable outage (rate-limit / brief offline).
    private var isStale: Bool { s.hasReading && s.status != .live }

    /// Fill color for the level: white normally, warming as the tank runs low.
    private var levelColor: Color {
        guard showsGauge else { return .white.opacity(0.5) }
        if remaining < 0.15 { return Color(red: 0.98, green: 0.36, blue: 0.40) }
        if remaining < 0.35 { return Color(red: 0.98, green: 0.72, blue: 0.32) }
        return .white
    }

    var body: some View {
        VStack(spacing: Spacing.base) {
            header
            // The block board scrolls: the count is user-driven (a big card plus up to
            // nine small ones), so it can outgrow the fixed panel. A click-drag on a card
            // reorders it (macOS scrolls on wheel/trackpad, so the two don't fight).
            ScrollView(.vertical) {
                blocksLayout
                    .padding(.bottom, Spacing.hair)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .coordinateSpace(name: "fuelGrid")
        .overlay { dragAvatar }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        // Poll only while this tab is showing and the panel is actually open.
        .onAppear { fuel.refresh(); fuel.setActive(vm.isOpen) }
        .onDisappear { fuel.setActive(false) }
        .onChange(of: vm.isOpen) { _, open in fuel.setActive(open) }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.hair) {
                providerPicker
                HStack(spacing: Spacing.s) {
                    Circle()
                        .fill(hasLive ? Color(red: 0.36, green: 0.86, blue: 0.52) : Color.white.opacity(0.35))
                        .frame(width: 6, height: 6)
                    Text("Status : \(s.statusLabel)")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            Spacer()
            Button {
                fuel.refresh(force: true)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(fuel.isRefreshing ? 360 : 0))
                    .animation(fuel.isRefreshing
                               ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                               : .default, value: fuel.isRefreshing)
                    .frame(width: 30, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .blackGlass(in: Capsule(), interactive: true)
            .linkCursor()
            .accessibilityLabel("Refresh")
        }
    }

    /// The header title, tappable to switch which AI's fuel we're reading.
    private var providerPicker: some View {
        Button {
            presentProviderMenu()
        } label: {
            HStack(spacing: Spacing.s) {
                Text(settings.fuelProvider.headerTitle)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .kerning(1.5)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.secondaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .linkCursor()
        .accessibilityLabel("Choose AI")
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { providerFrame = geo.frame(in: .global) }
                    .onChange(of: geo.frame(in: .global)) { _, f in providerFrame = f }
            }
        }
    }

    private func presentProviderMenu() {
        let items = AIProvider.allCases.map { p in
            GlassMenuItem.item(p.title, systemImage: p.symbol) {
                settings.fuelProvider = p
                fuel.select(p)
            }
        }
        glassMenu.show(items, at: CGPoint(x: providerFrame.minX, y: providerFrame.maxY + 6))
    }

    // MARK: - Big level meter (session gauge)

    private var sessionMeterCard: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Session fuel")
                        .font(.system(size: 14, weight: .semibold))
                    Text(riskLabel)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(levelColor.opacity(hasLive ? 0.95 : 0.6))
                }
                Spacer()
                if showsGauge {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                        Text("\(Int((remaining * 100).rounded()))")
                            .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                        Text("% left")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .opacity(isStale ? 0.85 : 1)
                }
            }

            VStack(spacing: Spacing.sm) {
                HStack {
                    Text("0%")
                    Spacer()
                    Text("50%")
                    Spacer()
                    Text("100%")
                }
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.tertiaryText)

                BarMeter(fraction: remaining, barCount: 54, fill: levelColor, showMarker: showsGauge)
                    .frame(height: 52)
                    .opacity(isStale ? 0.9 : 1)
            }
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.55))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
        .overlay {
            // Only veil the whole gauge when there's nothing to show. If we're
            // holding a stale reading through a rate-limit, keep the gauge and
            // surface a compact banner instead.
            if let hint = s.hint, !isStale {
                notConnectedOverlay(hint)
            }
        }
        .overlay(alignment: .top) {
            if isStale { staleBanner }
        }
    }

    /// A slim top-of-meter banner shown while we hold a stale reading through a
    /// recoverable outage — names the reason and counts down to the next attempt.
    private var staleBanner: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: Spacing.s) {
                Image(systemName: s.status == .rateLimited ? "hourglass" : "wifi.slash")
                    .font(.system(size: 9, weight: .bold))
                Text(staleBannerText(now: context.date))
                    .font(.system(size: 9.5, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(Color(red: 0.98, green: 0.72, blue: 0.32))
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.s)
            .background {
                Capsule().fill(Color.black.opacity(0.55))
            }
            .overlay { Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 1) }
            .padding(.top, Spacing.sm)
        }
    }

    /// e.g. "Rate limited · reading 2m old · retry 41s".
    private func staleBannerText(now: Date) -> String {
        var parts: [String] = [s.statusLabel]
        if let updated = s.lastUpdated {
            parts.append("reading \(fmtAgo(now.timeIntervalSince(updated))) old")
        }
        if let retry = s.retryAt {
            let secs = max(0, Int(retry.timeIntervalSince(now)))
            parts.append(secs > 0 ? "retry \(fmtCountdown(retry, now: now))" : "retrying…")
        }
        return parts.joined(separator: " · ")
    }

    private func fmtAgo(_ secs: TimeInterval) -> String {
        let n = max(0, Int(secs))
        if n >= 3600 { return "\(n / 3600)h" }
        if n >= 60 { return "\(n / 60)m" }
        return "\(n)s"
    }

    private var riskLabel: String {
        guard showsGauge else { return s.connected ? "No session data" : "Live data unavailable" }
        if remaining < 0.15 { return "ALMOST EMPTY" }
        if remaining < 0.35 { return "RUNNING LOW" }
        if remaining < 0.7  { return "HALF A TANK" }
        return "PLENTY LEFT"
    }

    /// Dim veil + one-line explanation shown over the meter when we can't read
    /// live usage (not signed in, offline, …).
    private func notConnectedOverlay(_ hint: String) -> some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.black.opacity(0.5))
            .overlay {
                VStack(spacing: Spacing.s) {
                    Image(systemName: "bolt.slash.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                    Text(hint)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Spacing.xl)
                }
            }
    }

    // MARK: - Stat grid

    /// The token counts share a comparative scale so their mini-meters read against
    /// each other rather than an arbitrary cap.
    private var tokenMax: Double {
        Double(max(1, max(s.blockTokens, s.todayTokens)))
    }

    /// The whole reorderable board: the featured block drawn large, then the rest in a
    /// three-column grid with the "+" tile. A live 1-second clock keeps countdowns
    /// ticking, and a floating avatar (added as an overlay in `body`) tracks a drag.
    private var blocksLayout: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let blocks = settings.enabledFuelBlocks
            VStack(spacing: Spacing.md) {
                if let featured = blocks.first {
                    bigSlot(featured, now: now)
                }
                smallGridView(Array(blocks.dropFirst()), now: now)
            }
        }
    }

    // MARK: Featured (big) slot

    @ViewBuilder
    private func bigSlot(_ block: FuelBlock, now: Date) -> some View {
        Group {
            // The session gauge keeps its rich rendering (risk label, stale banner,
            // not-connected veil); any other featured block gets the generic big card.
            if block == .sessionFuel {
                sessionMeterCard
            } else {
                genericBigCard(block, now: now)
            }
        }
        .opacity(draggingBlock == block ? 0.4 : 1)
        .scaleEffect(isDropTarget(block) ? 1.03 : 1)
        .overlay { dropHighlight(block, cornerRadius: block == .sessionFuel ? 16 : 18) }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("fuelGrid")) } action: { slotFrames[block] = $0 }
        .glassContextMenu { blockMenu(block) }
        .gesture(dragGesture(for: block))
    }

    /// A large featured "instrument cluster" for any non-session block: a light widget
    /// holding a black identity tile, a tick-dial gauge with a needle, and a wide accent
    /// strip carrying the headline value in bold digits.
    private func genericBigCard(_ block: FuelBlock, now: Date) -> some View {
        let r = readout(for: block, now: now)
        let cream = Color(red: 0.91, green: 0.90, blue: 0.87)
        let coral = Color(red: 0.93, green: 0.44, blue: 0.34)
        return VStack(spacing: Spacing.md) {
            HStack(spacing: Spacing.md) {
                // Identity tile — icon over the block's name, "Sat 09" style.
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Image(systemName: block.symbol)
                        .font(.system(size: 18, weight: .bold))
                    Spacer(minLength: 0)
                    Text(block.title)
                        .font(.system(size: 15, weight: .heavy))
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(Spacing.base)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black))

                // Instrument dial — ticks around the rim, a needle at the current level.
                DialGauge(fraction: r.fraction)
                    .frame(maxHeight: .infinity)
                    .padding(Spacing.base)
                    .frame(width: 104)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black))
            }
            .frame(height: 80)

            // Headline strip — the big value, black digits on the accent.
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Text(r.bigNumber)
                    .font(.system(size: 30, weight: .heavy, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                if !r.bigUnit.isEmpty {
                    Text(r.bigUnit)
                        .font(.system(size: 13, weight: .bold))
                        .opacity(0.7)
                }
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(coral))
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(cream))
    }

    // MARK: Small grid

    private func smallGridView(_ blocks: [FuelBlock], now: Date) -> some View {
        let rows = gridRows(blocks)
        return VStack(spacing: Spacing.md) {
            ForEach(rows.indices, id: \.self) { row in
                HStack(spacing: Spacing.md) {
                    ForEach(rows[row]) { slot in
                        smallSlotView(slot, now: now)
                    }
                }
            }
        }
    }

    /// One cell in the grid: a stat block, the "add" tile, or an invisible filler that
    /// keeps the last row aligned to three columns.
    private enum Slot: Identifiable {
        case block(FuelBlock)
        case add
        case filler(Int)

        var id: String {
            switch self {
            case .block(let b): return "b-\(b.rawValue)"
            case .add:          return "add"
            case .filler(let i): return "f-\(i)"
            }
        }
    }

    /// The small blocks + the add tile, chunked into rows of three and padded with
    /// fillers so each card keeps the same width as its neighbours.
    private func gridRows(_ blocks: [FuelBlock]) -> [[Slot]] {
        var slots: [Slot] = blocks.map { .block($0) }
        if !settings.addableFuelBlocks.isEmpty { slots.append(.add) }
        guard !slots.isEmpty else { return [] }

        var rows: [[Slot]] = []
        var fillerID = 0
        for start in stride(from: 0, to: slots.count, by: 3) {
            var row = Array(slots[start..<min(start + 3, slots.count)])
            while row.count < 3 { row.append(.filler(fillerID)); fillerID += 1 }
            rows.append(row)
        }
        return rows
    }

    @ViewBuilder
    private func smallSlotView(_ slot: Slot, now: Date) -> some View {
        switch slot {
        case .block(let block):
            smallCard(block, now: now)
                .opacity(draggingBlock == block ? 0.4 : 1)
                .scaleEffect(isDropTarget(block) ? 1.05 : 1)
                .overlay { dropHighlight(block, cornerRadius: 12) }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("fuelGrid")) } action: { slotFrames[block] = $0 }
                .glassContextMenu { blockMenu(block) }
                .gesture(dragGesture(for: block))
        case .add:
            AddBlockCard { presentAddBlockMenu() }
                .background {
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { addBlockFrame = geo.frame(in: .global) }
                            .onChange(of: geo.frame(in: .global)) { _, f in addBlockFrame = f }
                    }
                }
        case .filler:
            Color.clear.frame(maxWidth: .infinity)
        }
    }

    /// One small block. Every block whose headline is a number or a timer gets the same
    /// hero treatment — a small label up top, then the value drawn as large as the card
    /// allows so it reads at a glance (mirroring the reference "7,166 steps" card). Only
    /// the model chip, which shows a name rather than a number, keeps its own shape.
    @ViewBuilder
    private func smallCard(_ block: FuelBlock, now: Date) -> some View {
        let r = readout(for: block, now: now)
        Group {
            switch visual(of: block) {
            case .model:
                ModelStat(name: r.value, label: block.title, symbol: block.symbol, fill: r.fill)
            case .timer:
                // The countdown is the headline; there's no separate unit, and a slim
                // meter reads the depleting window beneath it.
                HeroStat(number: r.available ? r.value : "—", unit: "",
                         label: block.title, symbol: block.symbol, fill: r.fill,
                         fraction: r.fraction, showMeter: r.available)
            case .count:
                HeroStat(number: r.bigNumber, unit: r.bigUnit,
                         label: block.title, symbol: block.symbol, fill: r.fill,
                         fraction: r.fraction, showMeter: r.available)
            case .ring, .tokens, .money:
                HeroStat(number: r.bigNumber, unit: r.bigUnit,
                         label: block.title, symbol: block.symbol, fill: r.fill,
                         fraction: r.fraction, showMeter: r.available && r.hasMeter)
            }
        }
        .fuelCardChrome()
    }

    /// The right-click menu shared by every block: promote it to the big slot and/or
    /// remove it (never removing the last remaining block).
    private func blockMenu(_ block: FuelBlock) -> [GlassMenuItem] {
        var items: [GlassMenuItem] = []
        if settings.enabledFuelBlocks.first != block {
            items.append(.item("Make \(block.title) big", systemImage: "arrow.up.backward.and.arrow.down.forward") {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    settings.featureFuelBlock(block)
                }
            })
        }
        if settings.enabledFuelBlocks.count > 1 {
            items.append(.item("Remove \(block.title)", systemImage: "minus.circle", destructive: true) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    settings.removeFuelBlock(block)
                }
            })
        }
        return items
    }

    // MARK: - Block readouts

    /// Everything the block's bespoke card (small or big) needs to draw itself.
    private struct Readout {
        var value: String       // compact value: ring/timer centre, badge text
        var fraction: Double     // ring / meter fill, 0…1
        var hasMeter: Bool       // whether the big card draws a bar
        var fill: Color
        var bigNumber: String    // headline number on the big card
        var bigUnit: String      // headline unit ("% left", "tokens", …)
        var caption: String      // sub-label under the big card title
        var showsAxis: Bool      // draw the 0/50/100% scale (percentage meters only)
        var count: Int = 0       // for the pip archetype (sessions today)
        var countMax: Int = 8    // pip capacity
        var available: Bool = true // false → data missing / feature off ("—")
    }

    private func readout(for block: FuelBlock, now: Date) -> Readout {
        switch block {
        case .sessionFuel:
            let pct = Int((remaining * 100).rounded())
            return Readout(value: hasLive ? "\(pct)%" : "—",
                           fraction: hasLive ? remaining : 0, hasMeter: true, fill: levelColor,
                           bigNumber: showsGauge ? "\(pct)" : "—", bigUnit: "% left",
                           caption: riskLabel, showsAxis: true)
        case .weeklyLeft:
            let f = s.weekUsed.map { 1 - $0 }
            return Readout(value: f.map { "\(Int(($0 * 100).rounded()))%" } ?? "—",
                           fraction: f ?? 0, hasMeter: true, fill: .white,
                           bigNumber: f.map { "\(Int(($0 * 100).rounded()))" } ?? "—", bigUnit: "% left",
                           caption: "Weekly allowance", showsAxis: true, available: f != nil)
        case .resetsIn:
            return Readout(value: fmtCountdown(s.sessionResetsAt, now: now),
                           fraction: windowFraction(s.sessionResetsAt, now: now), hasMeter: true, fill: accent,
                           bigNumber: fmtCountdown(s.sessionResetsAt, now: now), bigUnit: "",
                           caption: "Until session resets", showsAxis: false, available: s.sessionResetsAt != nil)
        case .thisBlock:
            return Readout(value: fmtTokens(s.blockTokens),
                           fraction: Double(s.blockTokens) / tokenMax, hasMeter: true, fill: .white,
                           bigNumber: fmtTokens(s.blockTokens), bigUnit: "tokens",
                           caption: "This 5-hour block", showsAxis: false)
        case .today:
            return Readout(value: fmtTokens(s.todayTokens),
                           fraction: Double(s.todayTokens) / tokenMax, hasMeter: true, fill: .white,
                           bigNumber: fmtTokens(s.todayTokens), bigUnit: "tokens",
                           caption: "Today's usage", showsAxis: false)
        case .topModel:
            return Readout(value: s.topModel ?? "—", fraction: 0, hasMeter: false, fill: accent,
                           bigNumber: s.topModel ?? "—", bigUnit: "", caption: "Most-used model",
                           showsAxis: false, available: s.topModel != nil)
        case .weeklyReset:
            let has = s.weekResetsAt != nil
            return Readout(value: has ? fmtCountdown(s.weekResetsAt, now: now) : "—",
                           fraction: weekWindowFraction(s.weekResetsAt, now: now), hasMeter: true, fill: accent,
                           bigNumber: has ? fmtCountdown(s.weekResetsAt, now: now) : "—", bigUnit: "",
                           caption: "Until weekly reset", showsAxis: false, available: has)
        case .sessionsToday:
            return Readout(value: hasLive ? "\(s.sessionsToday)" : "—",
                           fraction: hasLive ? min(1, Double(s.sessionsToday) / 8) : 0, hasMeter: true, fill: accent,
                           bigNumber: hasLive ? "\(s.sessionsToday)" : "—", bigUnit: "sessions",
                           caption: "Started today", showsAxis: false,
                           count: s.sessionsToday, countMax: 8, available: hasLive)
        case .credits:
            let warn = Color(red: 0.98, green: 0.36, blue: 0.40)
            if !s.creditsEverEnabled {
                return Readout(value: hasLive ? "Off" : "—", fraction: 0, hasMeter: false, fill: Theme.secondaryText,
                               bigNumber: hasLive ? "Off" : "—", bigUnit: "", caption: "Credits disabled",
                               showsAxis: false, available: false)
            }
            // Meter reads remaining headroom under the cap; with no cap set there's
            // nothing to run down, so show a full bar rather than an alarming empty one.
            let rem = s.creditsLimit > 0 ? max(0, 1 - s.creditsUsed / s.creditsLimit) : 1
            return Readout(value: fmtMoney(s.creditsUsed, s.creditsSymbol), fraction: rem, hasMeter: true,
                           fill: s.creditsCritical ? warn : accent,
                           bigNumber: fmtMoney(s.creditsUsed, s.creditsSymbol), bigUnit: "used",
                           caption: "Credit balance", showsAxis: false)
        }
    }

    /// Which bespoke visual a block uses — the shape that fits its data.
    private enum BlockVisual { case ring, timer, tokens, count, model, money }

    private func visual(of block: FuelBlock) -> BlockVisual {
        switch block {
        case .sessionFuel, .weeklyLeft:     return .ring
        case .resetsIn, .weeklyReset:       return .timer
        case .thisBlock, .today:            return .tokens
        case .sessionsToday:                return .count
        case .topModel:                     return .model
        case .credits:                      return .money
        }
    }

    // MARK: - Drag to reorder

    /// Drag any block to reorder it: past a few points of travel it lifts off, tracks the
    /// finger over the board (dropping onto the top slot makes it the big one) and commits
    /// on release. A plain `DragGesture` — the sequenced long-press variant doesn't fire
    /// reliably in the panel's non-activating window.
    private func dragGesture(for block: FuelBlock) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("fuelGrid"))
            .onChanged { value in
                if draggingBlock != block {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.8)) {
                        draggingBlock = block
                    }
                }
                dragLocation = value.location
                // Only preview the landing spot here — the list is committed on release
                // so the dragged card is never torn down mid-gesture (which cancels it).
                let target = dropDestination(for: block, at: value.location)
                if target != dropTarget {
                    withAnimation(.easeOut(duration: 0.12)) { dropTarget = target }
                }
            }
            .onEnded { _ in
                commitDrop(of: block)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                    draggingBlock = nil
                    dropTarget = nil
                }
            }
    }

    /// The block the finger is hovering over — the one we'll swap the dragged block with.
    /// Only a real card counts (empty gaps / the "+" tile clear the target).
    private func dropDestination(for dragging: FuelBlock, at finger: CGPoint) -> FuelBlock? {
        settings.enabledFuelBlocks.first { $0 != dragging && (slotFrames[$0]?.contains(finger) == true) }
    }

    /// Commit on release: the dragged block and the hovered block trade places. Swapping a
    /// grid block with the big one is how you feature it — simple and reversible.
    private func commitDrop(of dragging: FuelBlock) {
        guard let target = dropTarget, target != dragging else { return }
        var next = settings.enabledFuelBlocks
        guard let from = next.firstIndex(of: dragging), let to = next.firstIndex(of: target) else { return }
        next.swapAt(from, to)
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            settings.reorderFuelBlocks(next)
        }
    }

    /// Whether `block` is the highlighted landing spot for the in-flight drag.
    private func isDropTarget(_ block: FuelBlock) -> Bool {
        draggingBlock != nil && draggingBlock != block && dropTarget == block
    }

    /// The drag's two-sided hover cue: the card being swapped *into* gets a solid accent
    /// ring, a soft fill and a swap badge; the picked-up card gets a dashed outline so its
    /// resting slot stays legible.
    @ViewBuilder
    private func dropHighlight(_ block: FuelBlock, cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if isDropTarget(block) {
            shape
                .fill(accent.opacity(0.14))
                .overlay { shape.strokeBorder(accent, lineWidth: 2) }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(Theme.isNoir ? Color.black : Color.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(accent))
                        .padding(Spacing.s)
                }
        } else if draggingBlock == block {
            shape.strokeBorder(accent.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        }
    }

    /// The pill that follows the cursor while dragging. Once you're over a target it reads
    /// "dragged ⇄ target", spelling out the swap that will happen on release.
    @ViewBuilder
    private var dragAvatar: some View {
        if let block = draggingBlock {
            HStack(spacing: Spacing.sm) {
                dragChip(block)
                if let target = dropTarget, target != block {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(accent)
                    dragChip(target)
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background { Capsule().fill(Color.black.opacity(0.82)) }
            .overlay { Capsule().strokeBorder(accent.opacity(0.6), lineWidth: 1) }
            .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
            .position(dragLocation)
            .allowsHitTesting(false)
        }
    }

    private func dragChip(_ block: FuelBlock) -> some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: block.symbol)
                .font(.system(size: 10, weight: .bold))
            Text(block.title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
    }

    private func presentAddBlockMenu() {
        let items = settings.addableFuelBlocks.map { block in
            GlassMenuItem.item(block.title, systemImage: block.symbol) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    settings.addFuelBlock(block)
                }
            }
        }
        glassMenu.show(items, at: CGPoint(x: addBlockFrame.minX, y: addBlockFrame.maxY + 6))
    }

    /// Fraction of the rolling 5-hour window still remaining, for the resets meter.
    private func windowFraction(_ resets: Date?, now: Date) -> Double {
        guard let resets else { return 0 }
        return min(1, max(0, resets.timeIntervalSince(now) / (5 * 3600)))
    }

    /// Fraction of the rolling 7-day window still remaining, for the weekly-reset meter.
    private func weekWindowFraction(_ resets: Date?, now: Date) -> Double {
        guard let resets else { return 0 }
        return min(1, max(0, resets.timeIntervalSince(now) / (7 * 24 * 3600)))
    }

    // MARK: - Formatting

    private func fmtMoney(_ amount: Double, _ symbol: String) -> String {
        symbol + String(format: "%.2f", amount)
    }

    private func fmtTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1_000) }
        return "\(n)"
    }

    private func fmtCountdown(_ date: Date?, now: Date) -> String {
        guard let date else { return "—" }
        let sec = max(0, Int(date.timeIntervalSince(now)))
        if sec >= 3600 { return "\(sec / 3600)h \(sec % 3600 / 60)m" }
        if sec >= 60 { return "\(sec / 60)m \(sec % 60)s" }
        return "\(sec)s"
    }
}

// MARK: - Components

private extension View {
    /// Shared chrome for a small fuel block: a fixed height so the grid stays even
    /// whatever each block draws inside, plus the translucent card + hairline border.
    func fuelCardChrome() -> some View {
        self
            .frame(maxWidth: .infinity)
            .frame(height: 90)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            }
    }
}

/// The caption every small block shares, under its bespoke visual.
private struct BlockLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Theme.secondaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

/// An instrument dial: tick marks around the rim (every 6th longer) with an arrow
/// needle pointing to `fraction` of a full turn. Purely presentational.
private struct DialGauge: View {
    let fraction: Double
    var tint: Color = .white

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let radius = side / 2
            ZStack {
                ForEach(0..<24, id: \.self) { i in
                    Capsule()
                        .fill(tint.opacity(i % 6 == 0 ? 1 : 0.5))
                        .frame(width: 1.6, height: i % 6 == 0 ? 8 : 5)
                        .offset(y: -(radius - 5))
                        .rotationEffect(.degrees(Double(i) / 24 * 360))
                }
                Image(systemName: "arrow.up")
                    .font(.system(size: side * 0.42, weight: .bold))
                    .foregroundStyle(tint)
                    .offset(y: -side * 0.12)
                    .rotationEffect(.degrees(min(1, max(0, fraction)) * 360))
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// The shared big-number card for every block whose headline is a number or a timer.
///
/// A small labelled header sits at the top; the value fills the rest of the card as large
/// as it can (shrinking to fit rather than truncating), so the most important thing — the
/// number — is legible at a glance. This mirrors the reference "7,166 steps" widget: tiny
/// caption, hero digits, quiet unit. A hairline meter under the number keeps the fill
/// indicator the old ring/pip visuals provided.
private struct HeroStat: View {
    let number: String
    let unit: String
    let label: String
    let symbol: String
    let fill: Color
    let fraction: Double
    var showMeter: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.secondaryText)
                BlockLabel(text: label)
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                Text(number)
                    .font(.system(size: 38, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.35)
                    .layoutPriority(1)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(fill.opacity(0.9))
                        .lineLimit(1)
                }
            }
            if showMeter {
                BarMeter(fraction: fraction, barCount: 22, fill: fill, showMarker: fraction > 0)
                    .frame(height: 5)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.base)
        .padding(.vertical, Spacing.base)
    }
}

/// Model block: a chip-like badge — a chip icon over the model name.
private struct ModelStat: View {
    let name: String
    let label: String
    let symbol: String
    let fill: Color

    var body: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(fill)
            Text(name)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.55)
            BlockLabel(text: label)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.base)
    }
}

/// The "+" tile that adds an optional stat block. Sized to match a `StatCard` so it
/// sits flush in the grid; a dashed outline marks it as an affordance, not data.
private struct AddBlockCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Spacing.s) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .bold))
                Text("Add block")
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.secondaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, Spacing.lg)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14),
                              style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        .linkCursor()
        .accessibilityLabel("Add block")
    }
}

/// A segmented level bar: `fraction` of the ticks are lit; a hairline marker sits
/// at the current level. Purely presentational.
private struct BarMeter: View {
    let fraction: Double
    var barCount: Int = 48
    var fill: Color = .white
    var showMarker: Bool = true

    /// The "off" segments read as visible dark-gray LEDs (like the reference matrix),
    /// not a near-black tint of the fill — a dim amber fill at low opacity would
    /// otherwise vanish against the black card.
    private var offColor: Color { Color.white.opacity(0.24) }

    var body: some View {
        GeometryReader { geo in
            let f = min(1, max(0, fraction))
            let lit = Int((Double(barCount) * f).rounded())
            ZStack(alignment: .leading) {
                HStack(spacing: max(1, geo.size.width / Double(barCount) * 0.35)) {
                    ForEach(0..<barCount, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(i < lit ? fill : offColor)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                if showMarker {
                    Rectangle()
                        .fill(fill)
                        .frame(width: 1.5)
                        .frame(maxHeight: .infinity)
                        .offset(x: max(0, min(geo.size.width - 1.5, geo.size.width * f - 0.75)))
                        .shadow(color: fill.opacity(0.6), radius: 3)
                }
            }
        }
    }
}
