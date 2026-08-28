import SwiftUI
import Darwin

/// The "System" tab — a live pulse of the machine: CPU load, memory pressure and
/// network throughput, each shown as a hero readout over a sparkline of the last
/// minute. All samples come from local kernel APIs (`host_processor_info`,
/// `host_statistics64`, `getifaddrs`) polled once a second by ``SystemMonitor`` —
/// nothing leaves the Mac. Built panel-native (``Theme`` colours + `settings.accent`)
/// so it reads correctly on Liquid Glass, Noir and Light without a dark stage.
struct NowTabView: View {
    @EnvironmentObject private var settings: SettingsStore
    @StateObject private var monitor = SystemMonitor()

    var body: some View {
        VStack(spacing: Spacing.base) {
            VitalRow(title: "CPU",
                     symbol: "cpu",
                     accent: settings.accent,
                     value: monitor.cpuPercentText,
                     detail: monitor.cpuDetail,
                     fraction: monitor.cpuFraction,
                     history: monitor.cpuHistory)
            VitalRow(title: "Memory",
                     symbol: "memorychip",
                     accent: settings.accent,
                     value: monitor.memPercentText,
                     detail: monitor.memDetail,
                     fraction: monitor.memFraction,
                     history: monitor.memHistory)
            VitalRow(title: "Network",
                     symbol: "network",
                     accent: settings.accent,
                     value: monitor.netRateText,
                     detail: monitor.netDetail,
                     fraction: monitor.netFraction,
                     history: monitor.netHistory)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }
}

// MARK: - One vital block

/// A single vital: an icon + label + hero value on the left, a sparkline of recent
/// history filling the right, and a thin baseline meter of the current fraction.
private struct VitalRow: View {
    let title: String
    let symbol: String
    let accent: Color
    let value: String
    let detail: String
    /// Current level, 0…1, for the baseline meter.
    let fraction: Double
    /// Recent samples, each 0…1, oldest first — drives the sparkline.
    let history: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accent)
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.secondaryText)
                    .kerning(0.5)
                Spacer(minLength: Spacing.sm)
                Text(value)
                    .font(.system(size: 22, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }

            Sparkline(samples: history, accent: accent)
                .frame(height: 34)

            HStack(spacing: Spacing.sm) {
                Capsule()
                    .fill(Theme.line(0.12))
                    .frame(height: 3)
                    .overlay(alignment: .leading) {
                        GeometryReader { geo in
                            Capsule()
                                .fill(accent)
                                .frame(width: geo.size.width * min(max(fraction, 0), 1))
                        }
                    }
                Text(detail)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, Spacing.base)
        .padding(.vertical, Spacing.sm)
        .innerCard(cornerRadius: 14)
    }
}

// MARK: - Sparkline

/// A filled area sparkline of `samples` (each 0…1, oldest first), normalised to its
/// own visible range so small movements still read. A dot marks the latest point.
private struct Sparkline: View {
    let samples: [Double]
    let accent: Color

    var body: some View {
        GeometryReader { geo in
            let pts = points(in: geo.size)
            ZStack {
                if pts.count > 1 {
                    // Soft area fill under the line.
                    Path { p in
                        p.move(to: CGPoint(x: pts[0].x, y: geo.size.height))
                        for pt in pts { p.addLine(to: pt) }
                        p.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: geo.size.height))
                        p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [accent.opacity(0.28), accent.opacity(0.02)],
                                         startPoint: .top, endPoint: .bottom))
                    Path { p in
                        p.move(to: pts[0])
                        for pt in pts.dropFirst() { p.addLine(to: pt) }
                    }
                    .stroke(accent, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    if let last = pts.last {
                        Circle().fill(accent)
                            .frame(width: 4, height: 4)
                            .position(last)
                    }
                } else {
                    Capsule().fill(Theme.line(0.10)).frame(height: 2)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
    }

    /// Map samples to points, scaling to the sample window's own min…max so a flat-
    /// but-nonzero series (e.g. steady CPU) still shows texture rather than a line
    /// pinned to the floor.
    private func points(in size: CGSize) -> [CGPoint] {
        guard samples.count > 1 else { return [] }
        let lo = samples.min() ?? 0
        let hi = samples.max() ?? 1
        let span = max(hi - lo, 0.001)
        let stepX = size.width / CGFloat(samples.count - 1)
        // Leave a little headroom so the top of a peak isn't clipped by the frame.
        let usable = size.height - 3
        return samples.enumerated().map { i, v in
            let norm = (v - lo) / span
            let y = size.height - 1 - CGFloat(norm) * usable
            return CGPoint(x: CGFloat(i) * stepX, y: y)
        }
    }
}

// MARK: - Monitor

/// Samples CPU / memory / network once a second and keeps a rolling minute of
/// history for the sparklines. All reads are local kernel calls. The timer only
/// runs while the tab is on screen (`start`/`stop` from the view's lifecycle).
@MainActor
final class SystemMonitor: ObservableObject {
    /// Rolling window length (seconds ≈ samples, one per tick).
    private let capacity = 60

    @Published private(set) var cpuFraction: Double = 0
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memFraction: Double = 0
    @Published private(set) var memHistory: [Double] = []
    @Published private(set) var memUsedBytes: UInt64 = 0
    @Published private(set) var memTotalBytes: UInt64 = 0
    /// Current throughput, bytes/sec.
    @Published private(set) var netDownRate: Double = 0
    @Published private(set) var netUpRate: Double = 0
    @Published private(set) var netHistory: [Double] = []
    /// Peak combined throughput seen this session, so the sparkline/meter have a
    /// stable ceiling to normalise against.
    private var netPeak: Double = 1

    private var timer: Timer?
    private var lastCPUTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?
    private var lastNet: (down: UInt64, up: UInt64, time: Date)?

    func start() {
        guard timer == nil else { return }
        sample()
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Derived text

    var cpuPercentText: String { "\(Int((cpuFraction * 100).rounded()))%" }
    var cpuDetail: String { "\(ProcessInfo.processInfo.activeProcessorCount) cores" }

    var memPercentText: String {
        guard memTotalBytes > 0 else { return "–" }
        return "\(Int((memFraction * 100).rounded()))%"
    }
    var memDetail: String {
        guard memTotalBytes > 0 else { return "" }
        return "\(Self.gb(memUsedBytes)) / \(Self.gb(memTotalBytes))"
    }

    var netRateText: String { Self.rate(netDownRate + netUpRate) }
    var netDetail: String { "↓\(Self.rate(netDownRate))  ↑\(Self.rate(netUpRate))" }
    var netFraction: Double { min(1, (netDownRate + netUpRate) / netPeak) }

    // MARK: Sampling

    private func sample() {
        sampleCPU()
        sampleMemory()
        sampleNetwork()
    }

    private func push(_ value: Double, into history: inout [Double]) {
        history.append(value)
        if history.count > capacity { history.removeFirst(history.count - capacity) }
    }

    private func sampleCPU() {
        var count = mach_msg_type_number_t()
        var info: processor_info_array_t?
        var cpuCount = natural_t()
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                         &cpuCount, &info, &count)
        guard result == KERN_SUCCESS, let info else { return }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.stride))
        }

        var user: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0, nice: UInt64 = 0
        let states = Int(CPU_STATE_MAX)
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * states
            user   += UInt64(info[base + Int(CPU_STATE_USER)])
            system += UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            idle   += UInt64(info[base + Int(CPU_STATE_IDLE)])
            nice   += UInt64(info[base + Int(CPU_STATE_NICE)])
        }

        if let last = lastCPUTicks {
            let dUser = user &- last.user
            let dSystem = system &- last.system
            let dIdle = idle &- last.idle
            let dNice = nice &- last.nice
            let busy = dUser + dSystem + dNice
            let total = busy + dIdle
            let frac = total > 0 ? Double(busy) / Double(total) : 0
            cpuFraction = frac
            push(frac, into: &cpuHistory)
        }
        lastCPUTicks = (user, system, idle, nice)
    }

    private func sampleMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let host = mach_host_self()
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        let page = UInt64(vm_kernel_page_size)
        // "Used" the way Activity Monitor frames memory pressure: everything that
        // isn't free/purgeable — active + wired + compressed.
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count)
                    + UInt64(stats.compressor_page_count)) * page
        let total = ProcessInfo.processInfo.physicalMemory
        memUsedBytes = used
        memTotalBytes = total
        let frac = total > 0 ? min(1, Double(used) / Double(total)) : 0
        memFraction = frac
        push(frac, into: &memHistory)
    }

    private func sampleNetwork() {
        var down: UInt64 = 0, up: UInt64 = 0
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            guard let addr = cur.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_LINK) else { continue }
            let name = String(cString: cur.pointee.ifa_name)
            // Skip loopback and virtual/bridge interfaces so the reading reflects
            // real off-machine traffic.
            guard name != "lo0", !name.hasPrefix("bridge"), !name.hasPrefix("utun"),
                  !name.hasPrefix("llw"), !name.hasPrefix("awdl") else { continue }
            guard let data = cur.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            down += UInt64(data.pointee.ifi_ibytes)
            up += UInt64(data.pointee.ifi_obytes)
        }

        let now = Date()
        if let last = lastNet {
            let dt = max(0.001, now.timeIntervalSince(last.time))
            // Counters are cumulative and can wrap/reset; clamp negatives to 0.
            let downRate = down >= last.down ? Double(down - last.down) / dt : 0
            let upRate = up >= last.up ? Double(up - last.up) / dt : 0
            netDownRate = downRate
            netUpRate = upRate
            let combined = downRate + upRate
            netPeak = max(netPeak * 0.98, combined, 1)   // slow decay so old spikes fade
            push(min(1, combined / netPeak), into: &netHistory)
        }
        lastNet = (down, up, now)
    }

    // MARK: Formatting

    private static func gb(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        return String(format: gb >= 10 ? "%.0f GB" : "%.1f GB", gb)
    }

    /// Bytes/sec → human rate (KB/s, MB/s).
    private static func rate(_ bytesPerSec: Double) -> String {
        let kb = bytesPerSec / 1024
        if kb < 1 { return "0 KB/s" }
        if kb < 1024 { return String(format: "%.0f KB/s", kb) }
        return String(format: "%.1f MB/s", kb / 1024)
    }
}
