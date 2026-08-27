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

    /// The last session utilization we saw (0…1), to detect the drop on refill and
    /// the climb into the "low" zone.
    private var lastSessionUsed: Double?
    private var timer: Timer?

    /// How often to poll while enabled. Refills are not time-critical, so keep this
    /// gentle to stay off the network / keychain most of the time.
    private let interval: TimeInterval = 120

    // Thresholds: a refill is a big drop back toward empty; "low" is crossing 90%.
    private let refillWasAbove = 0.40
    private let refillNowBelow = 0.15
    private let lowThreshold = 0.90

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
    }

    private func poll() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = LiveUsageClient.fetchDetailed()
            DispatchQueue.main.async { self?.handle(result) }
        }
    }

    private func handle(_ result: LiveFetchResult) {
        guard case .ok(let usage) = result, let session = usage.session else { return }
        let current = min(1, max(0, session.utilization / 100))
        sessionUsed = current
        defer { lastSessionUsed = current }

        guard let last = lastSessionUsed else { return } // first sample: just seed

        if last >= refillWasAbove && current <= refillNowBelow {
            onEvent?(.init(symbol: "fuelpump.fill", text: "Fuel refilled", tintHex: "34C759"))
        } else if last < lowThreshold && current >= lowThreshold {
            onEvent?(.init(symbol: "exclamationmark.triangle.fill", text: "Fuel running low", tintHex: "FF9F0A"))
        }
    }
}
