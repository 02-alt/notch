import Foundation
import Darwin

/// Publishes overall CPU load for the collapsed pill's resting System gauge
/// (`CollapsedResting.system`). Like `BatteryMonitor` it does nothing until
/// `start()` is called (gated by the setting) and polls gently — a couple of
/// seconds is plenty for a glance, and each read is a single cheap
/// `host_processor_info` snapshot. Shares no state with the System tab's
/// `SystemMonitor`; this is the minimal always-can-run reader the pill needs.
@MainActor
final class CPUMonitor: ObservableObject {
    /// Busy fraction across all cores, 0…1. `nil` until the first delta lands.
    @Published private(set) var load: Double?

    private var timer: Timer?
    private var lastTicks: (busy: UInt64, total: UInt64)?
    private let interval: TimeInterval = 2

    func start() {
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        load = nil
        lastTicks = nil
    }

    private func sample() {
        var count = mach_msg_type_number_t()
        var info: processor_info_array_t?
        var cpuCount = natural_t()
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &cpuCount, &info, &count) == KERN_SUCCESS, let info else { return }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.stride))
        }

        var busy: UInt64 = 0, total: UInt64 = 0
        let states = Int(CPU_STATE_MAX)
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * states
            let u = UInt64(info[base + Int(CPU_STATE_USER)])
            let s = UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            let n = UInt64(info[base + Int(CPU_STATE_NICE)])
            let idle = UInt64(info[base + Int(CPU_STATE_IDLE)])
            busy += u + s + n
            total += u + s + n + idle
        }

        if let last = lastTicks {
            let dBusy = busy &- last.busy
            let dTotal = total &- last.total
            load = dTotal > 0 ? Double(dBusy) / Double(dTotal) : 0
        }
        lastTicks = (busy, total)
    }
}
