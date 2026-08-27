import Foundation
import IOKit.ps

/// Publishes the Mac's battery charge for the collapsed pill's resting battery
/// gauge (`CollapsedResting.battery`). Like `FuelEventMonitor` it does nothing
/// until `start()` is called (gated by the setting), and it polls gently — battery
/// level moves in single percents over many minutes, so a tight timer would be
/// wasted work. On a desktop Mac with no battery, `charge` stays nil and the pill
/// simply shows nothing for this option.
@MainActor
final class BatteryMonitor: ObservableObject {
    /// A snapshot of the internal battery, or nil when there's no battery to read.
    struct Charge: Equatable {
        var fraction: Double   // 0…1 of full
        var charging: Bool     // on AC / charging
    }

    @Published private(set) var charge: Charge?

    private var timer: Timer?
    private let interval: TimeInterval = 60

    func start() {
        guard timer == nil else { return }
        read()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.read() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        charge = nil
    }

    /// Reads the internal power source via IOKit. Cheap enough to run inline on the
    /// main actor — it's a snapshot copy, not a subscription.
    private func read() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            charge = nil
            return
        }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let capacity = desc[kIOPSMaxCapacityKey] as? Int, capacity > 0 else { continue }
            let charging = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            charge = Charge(fraction: min(1, Double(current) / Double(capacity)), charging: charging)
            return
        }
        charge = nil
    }
}
