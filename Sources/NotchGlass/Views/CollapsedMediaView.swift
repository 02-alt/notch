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
    @EnvironmentObject private var fuel: FuelEventMonitor
    @EnvironmentObject private var battery: BatteryMonitor

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

    /// Whether the peek should be visible at all — a transient event, an AirDrop
    /// transfer and a running timer all take priority over (and can appear without)
    /// media, and a chosen resting stat fills the otherwise-idle pill.
    private var visible: Bool {
        recorder.isRecording || vm.islandActivity != nil || vm.collapsedEvent != nil || vm.transferActive || timer.isActive || mediaVisible || restingReady || settings.dynamicIsland
    }

    /// Whether the chosen resting stat has a value to show yet (a live-source stat
    /// only reads once its background poll lands).
    private var restingHasData: Bool {
        switch settings.collapsedResting {
        case .none:    return false
        case .clock:   return true
        case .fuel:    return fuel.sessionUsed != nil
        case .battery: return battery.charge != nil
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
                // widens (see RootView.eventPeekSize) into a small banner — a tinted
                // glyph and the label on the left, a matching pulse on the right.
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
            } else if vm.transferActive {
                Image(systemName: "dot.radiowaves.up.forward")
                    .font(.system(size: art * 0.55, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: art, height: art)
                Spacer(minLength: hInset)
                AirDropSpinner(diameter: art)
            } else if timer.isActive {
                timerPeek
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
        if settings.collapsedResting == .fuel, let used = fuel.sessionUsed {
            // Fuel mirrors ClaudeFuel's menu-bar item: a round "tank" gauge hugging the
            // left edge, and a compact readout on the right that rotates through the
            // stats — anchored on the session refill countdown, with % left, credits
            // and the weekly reset cycling in (see `fuelReadout`).
            FuelTank(fraction: max(0, 1 - used), color: fuelHealth(max(0, 1 - used)), size: art * 0.62)
            Spacer(minLength: hInset)
            fuelReadout
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
            // Compact glance used alongside now-playing media (right edge only): the
            // tank gauge with the % left beside it, no rotation.
            if let used = fuel.sessionUsed {
                let remaining = max(0, 1 - used)
                HStack(spacing: art * 0.24) {
                    FuelTank(fraction: remaining, color: fuelHealth(remaining), size: art * 0.62)
                    Text("\(Int((remaining * 100).rounded()))%")
                        .font(.system(size: art * 0.38, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize()
                }
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
        case .none:
            EmptyView()
        }
    }

    /// The rotating right-edge readout for the resting fuel peek — the notch's take on
    /// ClaudeFuel's menu-bar text. There's only room for one short string beside the
    /// tank, so it cycles: the **session refill countdown** is the anchor (shown every
    /// other slot, so it's the thing you mostly see), with **% left**, the live
    /// **credits** spend (only once you're on credits), and the **weekly reset** (only
    /// once the weekly limit is reached) rotating through between its turns.
    private var fuelReadout: some View {
        // Tick every second: the countdown text needs it, and the ~3s card rotation is
        // derived from absolute time so it never jumps when the view redraws.
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let cards = fuelCards
            let idx = cards.isEmpty ? 0
                : Int(ctx.date.timeIntervalSinceReferenceDate / 3) % cards.count
            let card = cards.isEmpty ? FuelCard.percent(fuel.sessionUsed.map { 1 - $0 } ?? 0)
                                     : cards[idx]
            Text(fuelText(card, now: ctx.date))
                .font(.system(size: art * 0.38, weight: .semibold).monospacedDigit())
                .foregroundStyle(fuelTint(card))
                .lineLimit(1)
                // Wide readouts (credits, the weekly Nd Hh) shrink to fit the bare
                // notch rather than overflow toward the camera cutout; the frame keeps
                // the text hugging the right edge, mirroring the left-edge tank.
                .minimumScaleFactor(0.4)
                .frame(maxWidth: art * 3.4, alignment: .trailing)
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.25), value: fuelText(card, now: ctx.date))
        }
    }

    /// One readout the fuel peek can rotate to.
    private enum FuelCard: Equatable {
        case reset(Date)      // session refill countdown (↻) — the anchor
        case percent(Double)  // fuel left, 0…1
        case credits          // extra-usage spend (⚡)
        case weekly(Date)     // weekly reset countdown, only once the week maxes out
    }

    /// The cards to cycle through, given what data we have. The reset countdown is
    /// interleaved between every other card so it stays the dominant readout.
    private var fuelCards: [FuelCard] {
        var extras: [FuelCard] = []
        if let used = fuel.sessionUsed { extras.append(.percent(max(0, 1 - used))) }
        if fuel.creditsUsed != nil { extras.append(.credits) }
        // "Weekly limit reached": the weekly window is essentially maxed out.
        if let week = fuel.weekUsed, week >= 0.99, fuel.weekResetsAt != nil {
            extras.append(.weekly(fuel.weekResetsAt!))
        }
        guard let reset = fuel.sessionResetsAt else { return extras }
        // Interleave: [reset, percent, reset, credits, reset, weekly, …]
        return extras.flatMap { [FuelCard.reset(reset), $0] }
    }

    private func fuelText(_ card: FuelCard, now: Date) -> String {
        switch card {
        case .reset(let at):
            return "↻ " + Self.shortClock(max(0, at.timeIntervalSince(now)))
        case .percent(let left):
            return "\(Int((left * 100).rounded()))%"
        case .credits:
            let amount = fuel.creditsUsed ?? 0
            return "⚡\(fuel.creditsSymbol)\(String(format: "%.2f", amount))"
        case .weekly(let at):
            return "7d ↻ " + Self.weekClock(max(0, at.timeIntervalSince(now)))
        }
    }

    private func fuelTint(_ card: FuelCard) -> Color {
        switch card {
        case .credits: return Color(hex: "0A84FF") ?? .blue
        case .weekly:  return Color(hex: "FF453A") ?? .red
        default:       return .white
        }
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

/// A small round "fuel tank" — a circle filled from the bottom to `fraction` in the
/// health color, mirroring ClaudeFuel's menu-bar gauge. The number lives *beside* it
/// (in the rotating readout), so the tank itself stays a clean, label-free glance.
private struct FuelTank: View {
    /// Fuel remaining, 0…1.
    let fraction: Double
    let color: Color
    let size: CGFloat

    var body: some View {
        let f = max(0, min(1, fraction))
        Circle()
            .fill(Color.white.opacity(0.14))
            .overlay(
                GeometryReader { geo in
                    Rectangle()
                        .fill(color)
                        .frame(height: geo.size.height * CGFloat(f))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
                .clipShape(Circle())
            )
            .overlay(Circle().strokeBorder(Color.white.opacity(0.6), lineWidth: max(1, size * 0.08)))
            .frame(width: size, height: size)
            .animation(.easeInOut(duration: 0.4), value: f)
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
