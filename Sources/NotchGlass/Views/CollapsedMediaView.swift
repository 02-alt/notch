import SwiftUI
import AppKit

/// The content shown *inside the collapsed pill* while the panel is closed.
///
/// It hugs the two edges of the notch — album art flush left, a live indicator
/// flush right — so the camera cutout in the middle stays clear. When an AirDrop
/// transfer lands it takes over the peek with a transfer spinner; otherwise, when
/// nothing is playing, it fades out entirely and the pill goes back to plain black.
struct CollapsedMediaView: View {
    @EnvironmentObject private var np: NowPlayingManager
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var vm: NotchViewModel
    @EnvironmentObject private var lyrics: LyricsService
    @EnvironmentObject private var fuel: FuelEventMonitor
    @EnvironmentObject private var battery: BatteryMonitor
    @EnvironmentObject private var cpu: CPUMonitor
    /// The shared weather store, observed so the pill's temperature updates as the
    /// background glance refreshes it (see `WeatherGlanceMonitor`).
    @ObservedObject private var weather = WeatherManager.shared

    /// A running kitchen timer takes over the peek so you can watch the countdown
    /// without opening the panel.
    @ObservedObject private var timer = CountdownTimer.shared

    /// An in-progress screen recording surfaces a REC dot + elapsed time, so it's
    /// obvious the screen is being captured even with the panel collapsed.
    @ObservedObject private var recorder = ScreenRecorder.shared

    /// The size of the collapsed pill (matches the physical notch when welded).
    let size: CGSize

    /// Breathing room so content never touches the pill's edges. Horizontal margin
    /// is larger than vertical so the art/indicator clear the rounded corners and
    /// don't hug the sides.
    private var vInset: CGFloat { max(4, size.height * 0.15) }
    private var hInset: CGFloat { max(12, size.height * 0.42) }
    private var art: CGFloat { max(0, size.height - vInset * 2) }

    /// Whether the now-playing media peek may show (gated by the setting).
    private var mediaVisible: Bool { settings.collapsedShowsMedia && np.hasTrack }

    /// Whether the pinned-lyrics ticker should take the pill: the pin is on and the
    /// track has synced lyrics. Independent of `collapsedShowsMedia` — pinning is an
    /// explicit request to keep the words in the notch.
    private var lyricPinned: Bool { lyrics.tickerActive(pinned: settings.pinLyrics, hasTrack: np.hasTrack) }

    /// The current line under the playhead; falls back to the track title during an
    /// intro or an instrumental gap so the ticker never blanks mid-song.
    private var lyricText: String { lyrics.currentLine(at: np.position) ?? np.title }

    /// Whether the peek should be visible at all — a transient event, an AirDrop
    /// transfer and a running timer all take priority over (and can appear without)
    /// media, and a chosen resting stat fills the otherwise-idle pill.
    private var visible: Bool {
        recorder.isRecording || vm.islandActivity != nil || vm.collapsedEvent != nil || vm.transferActive || timer.isActive || mediaVisible || lyricPinned || restingReady || settings.dynamicIsland
    }

    /// Whether the chosen resting stat has a value to show yet (a live-source stat
    /// only reads once its background poll lands).
    private var restingHasData: Bool {
        switch settings.collapsedResting {
        case .none:      return false
        case .clock:     return true
        case .fuel:      return fuel.sessionUsed != nil
        case .battery:   return battery.charge != nil
        case .date:      return true
        case .storage:   return true
        case .countdown: return Self.soonestCountdown() != nil
        case .weather:   return weather.current != nil
        case .system:    return cpu.load != nil
        }
    }

    /// Whether the resting stat surfaces *on its own* (an idle pill). Media, events,
    /// transfers and timers all outrank it — but when media is playing the stat
    /// rides alongside it instead of hiding (see `mediaCompanion`).
    private var restingReady: Bool {
        guard !recorder.isRecording, vm.collapsedEvent == nil, !vm.transferActive, !timer.isActive, !mediaVisible else { return false }
        return restingHasData
    }

    /// When media is playing, the resting stat (if set + ready) takes the right edge
    /// in place of the EQ, so you see *both* the track and your fuel/battery at once
    /// — rather than the stat being suppressed for the whole song.
    private var mediaCompanion: Bool { mediaVisible && restingHasData }

    /// The left-edge glyph for the resting stat — a category marker mirroring the
    /// media peek's album art. Battery swaps to a bolt while charging.
    private var restingSymbol: String {
        if settings.collapsedResting == .battery, battery.charge?.charging == true { return "bolt.fill" }
        // Weather's left glyph is the live condition (sun/cloud/rain…), not a fixed icon.
        if settings.collapsedResting == .weather, let c = weather.current {
            return WeatherCode.symbol(c.code, isDay: c.isDay)
        }
        return settings.collapsedResting.symbol
    }

    private func eventTint(_ event: NotchViewModel.CollapsedEvent) -> Color {
        event.tintHex.flatMap { Color(hex: $0) } ?? .white
    }

    var body: some View {
        HStack(spacing: 0) {
            if recorder.isRecording {
                recordingPeek
            } else if let activity = vm.islandActivity {
                islandPeek(activity)
            } else if let event = vm.collapsedEvent {
                // A transient notice (e.g. "Tokens refilled"): the notch briefly
                // widens (see RootView.collapsedBodySize) into a small banner. A refill
                // ("tokens back") gets the dot-matrix charge display; every other notice
                // gets the plain tinted glyph + label + pulse.
                if event.kind == .refill {
                    RefillPeek(text: event.text, art: art, hInset: hInset)
                        // Fresh identity per flash so the charge sweep replays every refill.
                        .id(vm.collapsedEventSeq)
                } else {
                    Image(systemName: event.symbol)
                        .font(.system(size: art * 0.58, weight: .semibold))
                        .foregroundStyle(eventTint(event))
                        .frame(width: art, height: art)
                    Text(event.text)
                        .font(.system(size: art * 0.44, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.leading, Spacing.sm)
                    Spacer(minLength: hInset)
                    PulseDot(color: eventTint(event), diameter: art * 0.5)
                }
            } else if vm.transferActive {
                Image(systemName: "dot.radiowaves.up.forward")
                    .font(.system(size: art * 0.55, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: art, height: art)
                Spacer(minLength: hInset)
                AirDropSpinner(diameter: art)
            } else if timer.isActive {
                timerPeek
            } else if lyricPinned {
                // Pinned lyrics ticker: the album art on the left, the live line filling
                // the rest of the pill — which is sized to fit the line (see
                // RootView.collapsedBodySize / lyricTickerWidth).
                artwork
                Text(lyricText)
                    .font(.system(size: art * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)
                    .padding(.leading, hInset)
                    .animation(.easeInOut(duration: 0.25), value: lyricText)
            } else if mediaVisible {
                artwork
                Spacer(minLength: hInset)
                if mediaCompanion {
                    // Both at once: the track's art on the left, your fuel/battery
                    // gauge on the right where the EQ would be.
                    restingValue.frame(height: art)
                } else {
                    SimpleEQ(animating: np.isPlaying, height: art * 0.78)
                }
            } else if settings.dynamicIsland {
                // Persistent Dynamic Island: with nothing else happening the notch
                // still reads as an always-on island — the time on the leading wing,
                // battery (or the date) on the trailing, camera kept clear between.
                islandResting
            } else if restingReady {
                restingPeek
            }
        }
        .padding(.horizontal, hInset)
        .padding(.vertical, vInset)
        .frame(width: size.width, height: size.height)
        .opacity(visible ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: visible)
        .animation(.easeInOut(duration: 0.25), value: vm.transferActive)
        .animation(.easeInOut(duration: 0.25), value: vm.collapsedEvent)
        .animation(.easeInOut(duration: 0.25), value: vm.islandActivity)
        .animation(.easeInOut(duration: 0.25), value: recorder.isRecording)
        .animation(.easeInOut(duration: 0.25), value: settings.dynamicIsland)
    }

    /// The Dynamic Island's self-driven presentation. For a track change: album art
    /// and the title/artist on the *leading* wing, a live EQ on the *trailing* wing,
    /// with the camera cutout kept clear between them — the signature two-sided split.
    /// The pill has already morphed wider (see `RootView.collapsedBodySize`) to give
    /// the title room without ever crossing the camera.
    @ViewBuilder private func islandPeek(_ activity: NotchViewModel.IslandActivity) -> some View {
        switch activity.kind {
        case .nowPlaying:
            artwork
            islandLabel(np.title, sub: np.artist)
            Spacer(minLength: hInset)
            SimpleEQ(animating: np.isPlaying, height: art * 0.78)

        case .timerDone(let label):
            ZStack {
                Circle().fill(Color.green.opacity(0.16))
                Image(systemName: "bell.fill")
                    .font(.system(size: art * 0.5, weight: .bold))
                    .foregroundStyle(Color.green)
            }
            .frame(width: art, height: art)
            islandLabel(label.isEmpty ? "Timer" : label, sub: "Time's up")
            Spacer(minLength: hInset)
            PulseDot(color: Color(hex: "34C759") ?? .green, diameter: art * 0.5)

        case .airDrop:
            Image(systemName: "dot.radiowaves.up.forward")
                .font(.system(size: art * 0.55, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: art, height: art)
            islandLabel("AirDrop", sub: "Receiving…")
            Spacer(minLength: hInset)
            AirDropSpinner(diameter: art)
        }
    }

    /// The always-on Dynamic Island at rest: the time hugging the leading edge and
    /// the battery (or, until the battery poll lands, the weekday + date) hugging the
    /// trailing edge — the persistent two-sided glance that makes the notch *read* as
    /// an island the moment the mode is switched on, before any activity fires.
    @ViewBuilder private var islandResting: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            Text(ctx.date, format: .dateTime.hour().minute())
                .font(.system(size: art * 0.62, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
        }
        Spacer(minLength: hInset)
        if let charge = battery.charge {
            HStack(spacing: Spacing.s) {
                Text("\(Int((charge.fraction * 100).rounded()))%")
                    .font(.system(size: art * 0.42, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                Image(systemName: charge.charging ? "bolt.fill" : "battery.100")
                    .font(.system(size: art * 0.4, weight: .semibold))
                    .foregroundStyle(charge.charging ? (Color(hex: "34C759") ?? .green) : .white.opacity(0.85))
            }
            .fixedSize()
        } else {
            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                Text(ctx.date, format: .dateTime.weekday(.abbreviated).day())
                    .font(.system(size: art * 0.42, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    /// A two-line leading label for the island — a bright title over a dimmer
    /// subtitle, bounded to the leading wing so it can never reach across the camera.
    @ViewBuilder private func islandLabel(_ title: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.hair) {
            Text(title)
                .font(.system(size: art * 0.34, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            if !sub.isEmpty {
                Text(sub)
                    .font(.system(size: art * 0.28, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: max(90, art * 3.2), alignment: .leading)
        .padding(.leading, Spacing.sm)
    }

    /// A live recording's peek: a red REC glyph hugging the left edge and the
    /// running MM:SS on the right, camera cutout kept clear between them.
    private var recordingPeek: some View {
        let red = Color(hex: "FF453A") ?? .red
        return Group {
            Image(systemName: "record.circle.fill")
                .font(.system(size: art * 0.55, weight: .semibold))
                .foregroundStyle(red)
                .frame(width: art, height: art)
            Spacer(minLength: hInset)
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                let elapsed = recorder.startDate.map { ctx.date.timeIntervalSince($0) } ?? 0
                let s = max(0, Int(elapsed))
                Text(String(format: "%02d:%02d", s / 60, s % 60))
                    .font(.system(size: art * 0.52, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(height: art)
        }
    }

    /// The resting glance: a category glyph hugging the left edge and a compact
    /// gauge/readout on the right, camera cutout kept clear between them — the same
    /// two-edge shape as the media and timer peeks.
    @ViewBuilder private var restingPeek: some View {
        if settings.collapsedResting == .fuel, fuel.sessionUsed != nil {
            // Fuel mirrors ClaudeFuel's menu-bar item: a round "tank" gauge hugging the
            // left edge and a rotating readout on the right — the session refill
            // countdown anchored, with % left, credits and the weekly reset cycling in.
            fuelGlance(compact: false)
                .frame(height: art)
        } else {
            Image(systemName: restingSymbol)
                .font(.system(size: art * 0.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: art, height: art)
            Spacer(minLength: hInset)
            restingValue
                .frame(height: art)
        }
    }

    @ViewBuilder private var restingValue: some View {
        switch settings.collapsedResting {
        case .fuel:
            // Compact glance alongside now-playing media (right edge only): the same
            // rotating readout the idle pill uses — so the session refill countdown
            // still cycles in while a track plays, not a pinned static "% left".
            if fuel.sessionUsed != nil {
                fuelGlance(compact: true)
            }
        case .battery:
            if let charge = battery.charge {
                MiniGauge(fraction: charge.fraction, label: "\(Int((charge.fraction * 100).rounded()))",
                          color: batteryHealth(charge), size: art)
            }
        case .clock:
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                Text(ctx.date, format: .dateTime.hour().minute())
                    .font(.system(size: art * 0.6, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
            }
        case .date:
            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                Text(ctx.date, format: .dateTime.weekday(.abbreviated).day())
                    .font(.system(size: art * 0.46, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
            }
        case .countdown:
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                if let next = Self.soonestCountdown() {
                    Text(next.short)
                        .font(.system(size: art * 0.52, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        case .storage:
            if let disk = Self.storageFree() {
                MiniGauge(fraction: disk.freeFraction, label: "\(disk.freePercent)",
                          color: storageHealth(disk.freeFraction), size: art)
            }
        case .weather:
            if let c = weather.current {
                Text("\(c.temp)°")
                    .font(.system(size: art * 0.55, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
            }
        case .system:
            if let load = cpu.load {
                MiniGauge(fraction: load, label: "\(Int((load * 100).rounded()))",
                          color: cpuHealth(load), size: art)
            }
        case .none:
            EmptyView()
        }
    }

    /// Green under light load, amber when busy, red when pegged — matching the
    /// battery/fuel/storage gauge language (here more load is "worse", so the bands
    /// run the other way).
    private func cpuHealth(_ load: Double) -> Color {
        if load > 0.85 { return Color(hex: "FF453A") ?? .red }
        if load > 0.60 { return Color(hex: "FFD60A") ?? .yellow }
        return Color(hex: "30D158") ?? .green
    }

    /// Green while there's plenty of room, amber getting tight, red nearly full —
    /// the same three-band language the battery/fuel gauges use.
    private func storageHealth(_ free: Double) -> Color {
        if free < 0.10 { return Color(hex: "FF453A") ?? .red }
        if free < 0.20 { return Color(hex: "FFD60A") ?? .yellow }
        return Color(hex: "30D158") ?? .green
    }

    /// The nearest upcoming Countdown-tab date, read straight from that tab's
    /// persisted store — so the idle glance mirrors the Countdown tab with no extra
    /// shared reader. `short` is the compact time left ("12d" / "5h" / "20m").
    static func soonestCountdown() -> (short: String, title: String)? {
        guard let json = UserDefaults.standard.string(forKey: "countdown.events"),
              let data = json.data(using: .utf8),
              let events = try? JSONDecoder().decode([CountdownEvent].self, from: data) else { return nil }
        let now = Date()
        guard let next = events.filter({ $0.date > now }).min(by: { $0.date < $1.date }) else { return nil }
        let secs = Int(next.date.timeIntervalSince(now))
        let days = secs / 86_400, hours = (secs % 86_400) / 3600, mins = (secs % 3600) / 60
        let short = days >= 1 ? "\(days)d" : (hours >= 1 ? "\(hours)h" : "\(mins)m")
        return (short, next.title)
    }

    /// Free space on the boot volume as a fraction and whole-percent — a cheap
    /// one-off `URLResourceValues` read (no polling); the glance's TimelineView
    /// refreshes it.
    static func storageFree() -> (freeFraction: Double, freePercent: Int)? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let vals = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                           .volumeTotalCapacityKey]),
              let free = vals.volumeAvailableCapacityForImportantUsage,
              let total = vals.volumeTotalCapacity, total > 0 else { return nil }
        let fraction = min(1, max(0, Double(free) / Double(total)))
        return (fraction, Int((fraction * 100).rounded()))
    }

    /// The resting fuel glance — the notch's take on ClaudeFuel's menu-bar item: a
    /// round "tank" on the left and a rotating readout that cycles the **session refill
    /// countdown** (the anchor, shown every other slot), **% left**, the live
    /// **credits** spend (only while on credits) and the **weekly reset** (only once the
    /// week maxes out). One `TimelineView` drives both so `remaining` and the card/text
    /// are computed once per tick. `compact` clusters the pair on the right (beside
    /// playing media); otherwise they hug opposite pill edges, camera cutout between.
    @ViewBuilder private func fuelGlance(compact: Bool) -> some View {
        // Tick every second: the countdown text needs it, and the ~3s card rotation is
        // derived from absolute time so it never jumps when the view redraws.
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let left = fuel.remaining(now: ctx.date) ?? 0
            let card = currentFuelCard(now: ctx.date, remaining: left)
            let text = fuelText(card, now: ctx.date)
            let tank = FuelTank(fraction: left, color: fuelHealth(left), size: art * 0.62)
            let base = Text(text)
                .font(.system(size: art * 0.38, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(compact ? 0.5 : 0.4)
                .contentTransition(.numericText())   // digits tick in place within a card
            let readout = Group {
                if Self.isLuckyNumber(text) {
                    // 22% / 2:22 — the celebratory gold shine (see LuckyShine).
                    base.modifier(LuckyShine(art: art))
                } else {
                    base.foregroundStyle(fuelTint(card))
                }
            }
            .id(card.stateID)                     // a card switch is a fresh view →
            .transition(.blurReplace)             // …that blurs the old out, the new in
            .animation(.easeInOut(duration: 0.25), value: text)        // countdown tick
            Group {
                if compact {
                    // Beside album art: cluster the tank and readout and size to content so
                    // the tank hugs the number — no reserved-width gap when the readout is
                    // short (e.g. a bare "62%" after the combined "↻ · %" is turned off).
                    HStack(spacing: art * 0.24) { tank; readout }
                        .fixedSize()
                } else {
                    // Idle pill: tank on the left edge, readout hugging the right edge, with
                    // a width cap so wide readouts (credits, weekly Nd Hh, combined "↻ · %")
                    // shrink to fit rather than cross the camera cutout.
                    HStack(spacing: 0) {
                        tank
                        Spacer(minLength: hInset)
                        readout.frame(maxWidth: art * 3.4, alignment: .trailing)
                    }
                }
            }
            // The card-to-card switch (↻ countdown → % → credits) morphs subtly: this
            // transaction on the *parent* is what lets the readout's `.transition` fire
            // and eases the readout's width change — without it a TimelineView tick isn't
            // an animated transaction, so the swap snaps. Keyed on `card.stateID` so only
            // a real card change animates, never the per-second countdown tick.
            .animation(.easeInOut(duration: 0.35), value: card.stateID)
        }
    }

    /// One readout the fuel peek can rotate to.
    private enum FuelCard: Equatable {
        case reset(Date)            // session refill countdown (↻) — the anchor
        case percent(Double)        // fuel left, 0…1
        case credits                // extra-usage spend (⚡)
        case weekly(Date)           // weekly reset countdown, only once the week maxes out
        case combined(Date, Double) // "↻ 3:45 · 88%" — countdown and % left together

        /// Identity by *state*, ignoring the ticking value — so digits tick in place
        /// (numericText) within a card, but switching cards is a fresh view that can
        /// cross-fade (blurReplace) instead of morphing "↻ 3:45" into "88%".
        var stateID: Int {
            switch self {
            case .reset:    return 0
            case .percent:  return 1
            case .credits:  return 2
            case .weekly:   return 3
            case .combined: return 4
            }
        }
    }

    /// How long each fuel card holds before the readout rotates to the next.
    private static let fuelCardDwell: TimeInterval = 5

    /// The card to show at `now`: the cards interleave the refill countdown between
    /// every other stat, and the slot advances every `fuelCardDwell` seconds off
    /// absolute time so it never jumps when the view redraws. `remaining` is passed in
    /// so it's computed once.
    private func currentFuelCard(now: Date, remaining: Double) -> FuelCard {
        let cards = fuelCards(now: now, remaining: remaining)
        guard !cards.isEmpty else { return .percent(remaining) }
        return cards[Int(now.timeIntervalSinceReferenceDate / Self.fuelCardDwell) % cards.count]
    }

    /// The cards to cycle through, given what data we have. The reset countdown is
    /// interleaved between every other card so it stays the dominant readout — and both
    /// countdowns drop out once their reset has passed (window refilled), leaving just
    /// "% left", so a stale reading pinned by rate-limited polls never shows "↻ 0:00".
    private func fuelCards(now: Date, remaining: Double) -> [FuelCard] {
        let reset = fuel.upcomingReset(now: now)

        // Cards that rotate through regardless of mode: credits (while on credits) and
        // the weekly reset (only once the week maxes out and its reset still lies ahead).
        var secondary: [FuelCard] = []
        if fuel.creditsUsed != nil { secondary.append(.credits) }
        if let week = fuel.weekUsed, week >= 0.99,
           let weekReset = fuel.weekResetsAt, weekReset > now {
            secondary.append(.weekly(weekReset))
        }

        // Combined mode (opt-in): one "↻ 3:45 · 88%" anchor showing both at once — or
        // just "% left" once refilled — with any secondary cards rotating in beside it.
        if settings.collapsedFuelCombined {
            let anchor: FuelCard = reset.map { .combined($0, remaining) } ?? .percent(remaining)
            return Self.interleaving(anchor, through: secondary)
        }

        // Default: rotate % and the secondary cards, with the refill countdown
        // interleaved between each so it stays the dominant readout — and it drops out
        // once the reset has passed, so a stale reading never shows "↻ 0:00". With no
        // upcoming reset there's no anchor to interleave, so show % and secondaries flat.
        let base: [FuelCard] = [.percent(remaining)] + secondary
        guard let reset else { return base }
        return Self.interleaving(.reset(reset), through: base)
    }

    /// `[anchor, a, anchor, b, …]` — the anchor card shown before each of `others` so
    /// it stays the dominant readout. Just `[anchor]` when there's nothing to rotate.
    private static func interleaving(_ anchor: FuelCard, through others: [FuelCard]) -> [FuelCard] {
        others.isEmpty ? [anchor] : others.flatMap { [anchor, $0] }
    }

    private func fuelText(_ card: FuelCard, now: Date) -> String {
        switch card {
        case .reset(let at):
            return Self.resetLabel(at, now: now)
        case .percent(let left):
            return Self.percentLabel(left)
        case .combined(let at, let left):
            return "\(Self.resetLabel(at, now: now)) · \(Self.percentLabel(left))"
        case .credits:
            let amount = fuel.creditsUsed ?? 0
            return "⚡\(fuel.creditsSymbol)\(String(format: "%.2f", amount))"
        case .weekly(let at):
            return "7d ↻ " + Self.weekClock(max(0, at.timeIntervalSince(now)))
        }
    }

    /// "↻ 3:45" — the session refill countdown, clamped so a passed reset shows 0.
    private static func resetLabel(_ at: Date, now: Date) -> String {
        "↻ " + shortClock(max(0, at.timeIntervalSince(now)))
    }

    /// "88%" — whole-percent fuel left.
    private static func percentLabel(_ left: Double) -> String {
        "\(Int((left * 100).rounded()))%"
    }

    /// The readout colour for ordinary cards. The two lucky readouts (22%, 2:22) get their
    /// own celebratory `LuckyShine` treatment instead (see the fuel glance).
    private func fuelTint(_ card: FuelCard) -> Color {
        switch card {
        case .credits: return Color(hex: "0A84FF") ?? .blue
        case .weekly:  return Color(hex: "FF453A") ?? .red
        default:       return .white
        }
    }

    /// True only for the two readouts the easter egg celebrates: "22%" (safe as a bare
    /// substring — percentages never exceed 100, so "22%" is always exactly 22) and a
    /// standalone "2:22" countdown (rejecting the tail of 12:22, 32:22, … by requiring the
    /// char before it isn't a digit).
    private static func isLuckyNumber(_ text: String) -> Bool {
        if text.contains("22%") { return true }
        if let r = text.range(of: "2:22") {
            let before = r.lowerBound == text.startIndex
                ? nil : text[text.index(before: r.lowerBound)]
            if before?.isNumber != true { return true }
        }
        return false
    }

    /// A short session countdown: `h:mm` past an hour, else `m:ss`.
    private static func shortClock(_ secs: TimeInterval) -> String {
        let s = Int(secs), h = s / 3600, m = (s % 3600) / 60
        if h > 0 { return "\(h):\(String(format: "%02d", m))" }
        return "\(m):\(String(format: "%02d", s % 60))"
    }

    /// A weekly countdown: `Nd Hh` past a day, else the short `h:mm`.
    private static func weekClock(_ secs: TimeInterval) -> String {
        let s = Int(secs), d = s / 86400, h = (s % 86400) / 3600
        if d > 0 { return "\(d)d \(h)h" }
        return shortClock(secs)
    }

    /// Fuel "% left" gauge color: green with headroom, amber as it tightens, red
    /// near empty — the same thresholds the fuel events use.
    private func fuelHealth(_ remaining: Double) -> Color {
        if remaining <= 0.10 { return Color(hex: "FF453A") ?? .red }
        if remaining <= 0.40 { return Color(hex: "FF9F0A") ?? .orange }
        return Color(hex: "34C759") ?? .green
    }

    /// Battery gauge color: accent-green while charging, red when low, white otherwise.
    private func batteryHealth(_ charge: BatteryMonitor.Charge) -> Color {
        if charge.charging { return Color(hex: "34C759") ?? .green }
        if charge.fraction <= 0.20 { return Color(hex: "FF453A") ?? .red }
        return .white
    }

    /// A running timer's peek: a small progress ring hugging the left edge and the
    /// live remaining time on the right, camera cutout kept clear between them.
    private var timerPeek: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            HStack(spacing: 0) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.15), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: max(0.0001, timer.progress))
                        .stroke(timer.finished ? Color.green : settings.accent,
                                style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: timer.finished ? "bell.fill"
                                        : (timer.paused ? "pause.fill" : "timer"))
                        .font(.system(size: art * 0.42, weight: .bold))
                        .foregroundStyle(timer.finished ? Color.green : .white)
                }
                .frame(width: art, height: art)
                Spacer(minLength: hInset)
                Text(timer.finished ? "Done" : ClockTabView.clockString(timer.remaining))
                    .font(.system(size: art * 0.5, weight: .bold).monospacedDigit())
                    .foregroundStyle(timer.finished ? settings.accent : .white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        }
    }

    private var artwork: some View {
        Group {
            if let image = np.artwork {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: "music.note")
                        .font(.system(size: art * 0.5, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .frame(width: art, height: art)
        .clipShape(RoundedRectangle(cornerRadius: art * 0.28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: art * 0.28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        }
    }
}

/// The refill banner — shown in the collapsed pill only when tokens come *back* (the
/// 5-hour session or weekly window resets). The banner is an **LED dot-matrix display**
/// (à la a charging-station sign): a grid of dots lights up column by column, left→right,
/// as the meter "charges" to full, with a gentle greyscale shimmer through the lit dots
/// and a softly brighter leading edge sweeping the fill front — while a percentage counts
/// 0→100 in step. Reads unmistakably as *refilling*, not a static glyph. Honors Reduce
/// Motion (all dots lit, still, no sweep). One-shot: it plays once on appear, then the
/// pill settles back after the event's dwell (see `NotchViewModel.flash`).
private struct RefillPeek: View {
    let text: String
    /// The pill's inner content height — sizes the glyph/label to match the other peeks.
    let art: CGFloat
    /// Horizontal breathing room at the edges, matching the sibling peeks.
    let hInset: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// When the charge started, stamped on first appearance so the fill + shimmer are
    /// driven off elapsed time (smooth and redraw-proof) rather than a state animation.
    @State private var start: Date?

    /// How long the dot matrix takes to charge from empty to full before it holds.
    private let fillDuration: TimeInterval = 1.3

    var body: some View {
        Group {
            if reduceMotion {
                frame(level: 1, t: 0, pct: 100)
            } else {
                TimelineView(.animation) { ctx in
                    let t = start.map { ctx.date.timeIntervalSince($0) } ?? 0
                    let level = fillLevel(t)
                    frame(level: level, t: t, pct: Int((level * 100).rounded()))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: art)
        .onAppear { if start == nil { start = Date() } }
    }

    /// Charge fraction 0…1 over `fillDuration` (ease-out), then holds full.
    private func fillLevel(_ t: TimeInterval) -> CGFloat {
        guard t > 0 else { return 0 }
        let x = min(1, t / fillDuration)
        return 1 - pow(1 - x, 3)
    }

    /// One rendered frame: the dot-matrix behind the label layer. The banner height is
    /// exactly `art`, so the clip is a plain capsule.
    @ViewBuilder private func frame(level: CGFloat, t: TimeInterval, pct: Int) -> some View {
        ZStack {
            Canvas { ctx, size in drawMatrix(ctx, size, level: level, t: t) }
                .clipShape(Capsule())
            content(pct: pct)
        }
    }

    /// The lit-dot palette: a restrained monochrome wash — bright off-white easing to a
    /// soft grey across the display — rather than a saturated colour, so the charge reads
    /// as a calm greyscale LED sign on the black notch.
    private static let dotColors: [Color] = [Color(white: 0.92), Color(white: 0.5)]

    /// Paints the LED grid: dots left of the charge front are lit (with a gentle
    /// travelling shimmer + a softly brighter column at the front), dots ahead of it stay
    /// dim so the matrix reads as a display even before it fills. The lit dots are shaded
    /// by a subtle left→right gradient; brightness is applied per-dot via layer opacity.
    private func drawMatrix(_ ctx: GraphicsContext, _ size: CGSize, level: CGFloat, t: TimeInterval) {
        let pitch = max(4, art * 0.20)                       // dot-to-dot spacing
        let radius = pitch * 0.34
        let cols = max(1, Int(size.width / pitch))
        let rows = max(1, Int(size.height / pitch))
        let ox = (size.width - CGFloat(cols) * pitch) / 2 + pitch / 2
        let oy = (size.height - CGFloat(rows) * pitch) / 2 + pitch / 2

        // One coherent gradient spanning the whole banner; every dot samples its own
        // position, so the grid shows a single subtle off-white→grey wash.
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: Self.dotColors),
            startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: size.width, y: 0))

        var g = ctx
        for c in 0..<cols {
            let cx = cols == 1 ? 0 : CGFloat(c) / CGFloat(cols - 1)   // 0…1 across width
            let lit = cx <= level + 0.0001
            let atFront = abs(cx - level) < (1.2 / CGFloat(cols))
            let x = ox + CGFloat(c) * pitch                          // column-invariant
            for r in 0..<rows {
                let y = oy + CGFloat(r) * pitch
                var b: Double
                if lit {
                    // Gentle drift: a low-contrast brightness wave rolling up the columns.
                    // Kept in a mid-grey range so the white label stays crisp over the dots.
                    let wave = 0.5 + 0.5 * sin(Double(r) * 0.8 - t * 3 + Double(c) * 0.14)
                    b = 0.48 + 0.16 * wave                   // ~0.48…0.64, calm grey
                    if atFront { b = 0.75 }                  // softly brighter leading edge
                } else {
                    b = atFront ? 0.26 : 0.1                 // faint pre-glow at the front
                }
                let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                g.opacity = b
                g.fill(Path(ellipseIn: rect), with: shading)
            }
        }
    }

    /// The label layer riding on top of the matrix: a leading bolt (energy back), the
    /// message, and the climbing percentage — kept legible over the LEDs with a soft
    /// shadow. The counter is the clearest "refilling" signal.
    @ViewBuilder private func content(pct: Int) -> some View {
        HStack(spacing: 0) {
            Image(systemName: "bolt.fill")
                .font(.system(size: art * 0.5, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: art, height: art)
            Text(text)
                .font(.system(size: art * 0.44, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, Spacing.xs)
            Spacer(minLength: hInset)
            Text("\(pct)%")
                .font(.system(size: art * 0.46, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .fixedSize()
        }
        .padding(.horizontal, art * 0.1)
        .shadow(color: .black.opacity(0.6), radius: 2, y: 0.5)
    }
}

/// A small round "fuel tank" — a circle filled from the bottom to `fraction`, mirroring
/// ClaudeFuel's menu-bar gauge. The fill is a **dot texture**: chunky dots below the fill
/// line shaded top→bottom in the health colour (green/amber/red), with a slow shimmer
/// drifting through them so the tank quietly breathes. The number lives *beside* it (in the
/// rotating readout). Honors Reduce Motion (static dots).
private struct FuelTank: View {
    /// Fuel remaining, 0…1.
    let fraction: Double
    /// The health colour (green/amber/red) the dots are shaded in.
    let color: Color
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let f = max(0, min(1, fraction))
        Circle()
            .fill(Color.white.opacity(0.14))
            .overlay(fill(f).clipShape(Circle()))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.6), lineWidth: max(1, size * 0.08)))
            .frame(width: size, height: size)
    }

    @ViewBuilder private func fill(_ f: CGFloat) -> some View {
        if reduceMotion {
            Canvas { ctx, sz in drawDots(ctx, sz, fill: f, t: nil) }
        } else {
            // ~12fps is plenty for a gentle drift and far lighter than a 60fps redraw of
            // this always-on glance.
            TimelineView(.animation(minimumInterval: 0.08, paused: false)) { ctx in
                Canvas { g, sz in
                    drawDots(g, sz, fill: f, t: ctx.date.timeIntervalSinceReferenceDate)
                }
            }
        }
    }

    /// Fills the region below the surface line with a chunky dot grid, shaded by a vertical
    /// health-colour gradient and modulated by a slow per-dot brightness wave. `t == nil`
    /// (Reduce Motion) freezes the shimmer.
    private func drawDots(_ ctx: GraphicsContext, _ sz: CGSize, fill: CGFloat, t: Double?) {
        let pitch = max(2.4, sz.height * 0.24)               // ~4 chunky rows
        let radius = pitch * 0.4
        let cols = max(1, Int(sz.width / pitch))
        let rows = max(1, Int(sz.height / pitch))
        let ox = (sz.width - CGFloat(cols) * pitch) / 2 + pitch / 2
        let oy = (sz.height - CGFloat(rows) * pitch) / 2 + pitch / 2
        let surfaceY = sz.height * (1 - fill)                // top of the fluid
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [color.opacity(0.95), color.opacity(0.5)]),
            startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: sz.height))

        var g = ctx
        for r in 0..<rows {
            let y = oy + CGFloat(r) * pitch
            if y < surfaceY - radius { continue }            // above the fill → empty
            for c in 0..<cols {
                let x = ox + CGFloat(c) * pitch
                let dot = Path(ellipseIn: CGRect(x: x - radius, y: y - radius,
                                                 width: radius * 2, height: radius * 2))
                var wave = 1.0                               // full brightness when static
                if let t {
                    let angle = Double(r) * 0.9 - t * 2 + Double(c) * 0.6
                    wave = 0.5 + 0.5 * sin(angle)            // gentle shimmer
                }
                g.opacity = 0.58 + 0.42 * wave
                g.fill(dot, with: shading)
            }
        }
    }
}

/// The celebratory treatment for a "lucky" fuel readout (22%, 2:22): gold gradient text
/// with a soft glow, a slow highlight sweeping across it, and a gentle pulse — so the
/// number reads as *special*, not merely yellow. Layout-neutral (glow/shine/scale don't
/// change the text's size), so the glance's clustering + morph logic is unaffected. Honors
/// Reduce Motion (static gold + glow, no sweep or pulse).
private struct LuckyShine: ViewModifier {
    /// The pill's inner content height — scales the glow radius to notch size.
    let art: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let gold = Gradient(colors: [Color(hex: "FFE79A") ?? .yellow,
                                                Color(hex: "E4A72A") ?? .orange])
    private var glow: Color { Color(hex: "FFC93C") ?? .yellow }

    func body(content: Content) -> some View {
        let gilded = content
            .foregroundStyle(LinearGradient(gradient: Self.gold, startPoint: .top, endPoint: .bottom))
            .shadow(color: glow.opacity(0.75), radius: art * 0.3)
        if reduceMotion {
            gilded
        } else {
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                gilded
                    .overlay { shine(t: t).mask(content) }   // highlight, clipped to the glyphs
                    .scaleEffect(1 + 0.035 * sin(t * 3))     // gentle breathe
            }
        }
    }

    /// A soft white highlight band sweeping left→right across the glyphs, ~once every 2.6s.
    @ViewBuilder private func shine(t: Double) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let band = max(6, w * 0.5)
            let period = 2.6
            let p = t.truncatingRemainder(dividingBy: period) / period   // 0…1
            LinearGradient(colors: [.clear, .white.opacity(0.85), .clear],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: band)
                .offset(x: -band + p * (w + band))                       // sweep L→R
                .blendMode(.plusLighter)
        }
        .allowsHitTesting(false)
    }
}

/// A tiny ring gauge with a centered percentage, used for the collapsed pill's
/// resting fuel / battery glance. The ring depletes clockwise from the top and the
/// number reads the same value, so it's legible at notch scale without a label.
private struct MiniGauge: View {
    /// The filled fraction of the ring (0…1) — e.g. fuel *remaining* or battery charge.
    let fraction: Double
    let label: String
    let color: Color
    let size: CGFloat

    private var lineWidth: CGFloat { max(1.5, size * 0.09) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.0001, min(1, fraction)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(label)
                .font(.system(size: size * 0.34, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
        }
        .frame(width: size, height: size)
        .animation(.easeInOut(duration: 0.4), value: fraction)
    }
}

/// The now-playing indicator: a simple, monochrome row of thin bars — the classic
/// sound-bars glyph, animated to look like it's reacting to the track. Each bar
/// mixes two out-of-phase wobbles with a shared sharp "beat" punch, so the row
/// jumps and flickers like a real spectrum rather than breathing in lockstep. When
/// paused it settles to a still, short silhouette.
///
/// When the Core Audio tap is live (`AudioLevels.active`) the bars are driven by the
/// *real* per-band spectrum of the system audio; otherwise they fall back to a
/// simulated motion. Driven by `TimelineView(.animation(paused:))` so pausing is a
/// true freeze.
private struct SimpleEQ: View {
    @EnvironmentObject private var audio: AudioLevels

    let animating: Bool
    /// Height of the tallest bar, in points.
    let height: CGFloat

    var body: some View {
        // Use the real spectrum only when the tap is live AND actually hearing audio;
        // if it's stranded on silence (output routed elsewhere, denied capture) fall
        // back to the simulated motion so the bars never sit dead mid-track.
        if audio.active && audio.receivingAudio {
            reactiveBars
        } else {
            simulatedBars
        }
    }

    /// Real spectrum: one bar per frequency band, heights straight from the FFT.
    private var reactiveBars: some View {
        HStack(alignment: .center, spacing: Spacing.hair) {
            ForEach(audio.bands.indices, id: \.self) { i in
                Capsule()
                    .fill(.white.opacity(0.9))
                    // A small floor so quiet bands still read as bars, not gaps.
                    .frame(width: 2, height: max(2, height * (0.08 + 0.92 * audio.bands[i])))
            }
        }
        .frame(height: height, alignment: .center)
        // No implicit `.animation` here: `bands` publishes at 60 Hz and is already
        // smoothed by the FFT's attack/decay envelope, so animating each publish just
        // stacked overlapping transactions on the always-visible pill every frame.
    }

    /// Per-bar resting height, plus a phase and speed so no two bars move together.
    private let bars: [(base: CGFloat, phase: Double, speed: Double)] = [
        (0.55, 0.0, 6.1),
        (0.80, 0.8, 7.7),
        (0.95, 1.6, 6.9),
        (1.00, 0.4, 8.3),
        (0.90, 2.2, 7.2),
        (0.70, 1.2, 7.9),
        (0.50, 2.8, 6.5),
    ]

    /// Fallback when there's no live audio tap: procedural, music-like motion.
    private var simulatedBars: some View {
        TimelineView(.animation(paused: !animating)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            // A sharp, periodic pulse (raised sine) that punches all bars together
            // like a kick drum, on top of each bar's own flicker.
            let beat = pow(max(0, sin(t * 2.6)), 8)
            HStack(alignment: .center, spacing: Spacing.hair) {
                ForEach(bars.indices, id: \.self) { i in
                    Capsule()
                        .fill(.white.opacity(0.9))
                        .frame(width: 2, height: max(2, height * level(bars[i], t: t, beat: beat)))
                }
            }
            .frame(height: height, alignment: .center)
        }
        .frame(height: height)
        .opacity(animating ? 1 : 0.5)
        .animation(.easeInOut(duration: 0.3), value: animating)
    }

    /// The live height fraction (0…1) for one bar: two out-of-phase wobbles plus the
    /// shared beat punch, clamped so bars never vanish or overshoot.
    private func level(_ b: (base: CGFloat, phase: Double, speed: Double), t: Double, beat: Double) -> CGFloat {
        guard animating else { return b.base * 0.35 }
        let slow = 0.5 + 0.5 * sin(t * b.speed + b.phase)
        let fast = 0.5 + 0.5 * sin(t * b.speed * 2.3 + b.phase * 1.7)
        let energy = 0.30 + 0.55 * slow * fast + 0.45 * beat
        return min(1, max(0.15, b.base * energy))
    }
}

/// A soft pulsing dot, used as the right-edge companion to a collapsed-notch event
/// glyph — a gentle "something just happened" beacon in the event's tint.
struct PulseDot: View {
    let color: Color
    let diameter: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            // Reduce Motion: a steady beacon — present, but no breathing pulse.
            Circle()
                .fill(color)
                .frame(width: diameter, height: diameter)
                .shadow(color: color.opacity(0.5), radius: diameter * 0.35)
        } else {
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let pulse = 0.5 + 0.5 * sin(t * 3.2)
                Circle()
                    .fill(color)
                    .frame(width: diameter, height: diameter)
                    .scaleEffect(0.7 + 0.3 * pulse)
                    .opacity(0.55 + 0.45 * pulse)
                    .shadow(color: color.opacity(0.6 * pulse), radius: diameter * 0.4)
            }
            .frame(width: diameter, height: diameter)
        }
    }
}

/// The transfer indicator shown while an AirDrop file is arriving: a dotted
/// "thinking orb" (particles running on tilted 3D orbits), sized for the notch.
/// A native port of the orbs.jakubantalik.com `working` state.
struct AirDropSpinner: View {
    let diameter: CGFloat

    var body: some View {
        ThinkingOrb(size: diameter)
    }
}
