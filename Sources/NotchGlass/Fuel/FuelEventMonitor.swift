import Foundation
import Combine

/// Watches your Claude usage in the background and emits transient "events" for the
/// collapsed notch — the main one being **fuel refilled** when the 5-hour session
/// window resets, plus a **running low** warning as it nears empty.
///
/// It's deliberately decoupled from `FuelManager` (which only polls while the Fuel
/// tab is on screen): this runs its own slow, opt-in poll of the same OAuth usage
/// endpoint so refills can surface even when the panel is closed. It does nothing —
/// no keychain, no network — unless `start()` is called (gated by the
/// `collapsedShowsFuelEvents` setting).
@MainActor
final class FuelEventMonitor: ObservableObject {
    /// Emits an event to show in the collapsed pill.
    var onEvent: ((NotchViewModel.CollapsedEvent) -> Void)?

    /// The latest session utilization from the background poll (0…1 used), or nil
    /// until the first successful reading. Drives the collapsed pill's resting fuel
    /// gauge (`CollapsedResting.fuel`) so a live "% left" can show while closed.
    @Published private(set) var sessionUsed: Double?

    /// When the 5-hour session window refills. The collapsed peek counts down to this
    /// locally (its "refund timer") between the slow background polls.
    @Published private(set) var sessionResetsAt: Date?

    /// The weekly window: fraction used (0…1) and when it rolls over. The peek surfaces
    /// the weekly reset countdown once the weekly limit is reached.
    @Published private(set) var weekUsed: Double?
    @Published private(set) var weekResetsAt: Date?

    /// Extra-usage ("credits") spend, in major units, and its currency symbol — shown
    /// in the peek only once you're actually on credits (spend > 0).
    @Published private(set) var creditsUsed: Double?
    @Published private(set) var creditsSymbol: String = "$"

    /// The last readings we saw, to detect the transitions that fire events: the
    /// session drop on refill / climb into "low", the weekly window maxing out or
    /// resetting, and the first dollar of extra-usage credits being spent.
    private var lastSessionUsed: Double?
    private var lastWeekUsed: Double?
    private var lastCreditsUsed: Double?
    private var timer: Timer?

    /// How often to poll while enabled. Refills are not time-critical, so keep this
    /// gentle to stay off the network / keychain most of the time.
    private let interval: TimeInterval = 120

    // Thresholds: a refill is a big drop back toward empty; "low" is crossing 90%;
    // a window is "maxed" once it's essentially at 100%.
    private let refillWasAbove = 0.40
    private let refillNowBelow = 0.15
    private let lowThreshold = 0.90
    private let maxedThreshold = 0.995

    func start() {
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastSessionUsed = nil
        lastWeekUsed = nil
        lastCreditsUsed = nil
        sessionResetsAt = nil
        weekUsed = nil
        weekResetsAt = nil
        creditsUsed = nil
    }

    private func poll() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = LiveUsageClient.fetchDetailed()
            DispatchQueue.main.async { self?.handle(result) }
        }
    }

    private func handle(_ result: LiveFetchResult) {
        guard case .ok(let usage) = result else { return }
        handleSession(usage.session)
        handleWeek(usage.week)
        handleCredits(usage.credits)
    }

    /// Session (5-hour) window: fires "refilled" on the reset drop and "running low"
    /// as it nears empty. Also feeds the collapsed pill's resting fuel gauge.
    private func handleSession(_ session: LiveWindow?) {
        guard let session else { return }
        let current = min(1, max(0, session.utilization / 100))
        sessionUsed = current
        sessionResetsAt = session.resetsAt
        defer { lastSessionUsed = current }
        guard let last = lastSessionUsed else { return } // first sample: just seed

        if last >= refillWasAbove && current <= refillNowBelow {
            onEvent?(.init(symbol: "fuelpump.fill", text: "Tokens refilled", tintHex: "34C759", kind: .refill))
        } else if last < lowThreshold && current >= lowThreshold {
            onEvent?(.init(symbol: "exclamationmark.triangle.fill", text: "Tokens running low", tintHex: "FF9F0A"))
        }
    }

    /// Weekly window: fires when it maxes out (the weekly limit is reached) and when
    /// it rolls over and resets back down.
    private func handleWeek(_ week: LiveWindow?) {
        guard let week else { return }
        let current = min(1, max(0, week.utilization / 100))
        weekUsed = current
        weekResetsAt = week.resetsAt
        defer { lastWeekUsed = current }
        guard let last = lastWeekUsed else { return }

        if last < maxedThreshold && current >= maxedThreshold {
            onEvent?(.init(symbol: "calendar.badge.exclamationmark", text: "Weekly limit reached", tintHex: "FF453A"))
        } else if last >= refillWasAbove && current <= refillNowBelow {
            onEvent?(.init(symbol: "calendar", text: "Weekly limit reset", tintHex: "34C759", kind: .refill))
        }
    }

    /// Extra-usage credits: fires once, when the first credit is spent — i.e. you've
    /// gone past the included limits and are now paying for overage.
    private func handleCredits(_ credits: LiveCredits?) {
        // Surface the live spend for the peek whenever we're actually on credits
        // (spend > 0), regardless of whether the transition event ever fires.
        if let credits, credits.used > 0 {
            creditsUsed = credits.used
            creditsSymbol = FuelManager.currencySymbol(credits.currency)
        } else {
            creditsUsed = nil
        }
        guard let credits, credits.everEnabled else { return }
        let used = credits.used
        defer { lastCreditsUsed = used }
        guard let last = lastCreditsUsed else { return }

        if last <= 0 && used > 0 {
            onEvent?(.init(symbol: "creditcard.fill", text: "Now using credits", tintHex: "0A84FF"))
        }
    }
}
