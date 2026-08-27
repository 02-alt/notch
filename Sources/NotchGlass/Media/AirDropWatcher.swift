import Foundation

/// Watches the Downloads folder and reports when a file arrives via AirDrop.
///
/// macOS exposes **no public API for live AirDrop transfer progress** — `sharingd`
/// owns that and doesn't publish it. The nearest real signal we can observe is the
/// finished file landing in Downloads (AirDrop's default destination), tagged with
/// a `com.apple.quarantine` xattr whose agent field is the AirDrop service. So this
/// fires on *arrival*, not mid-transfer, and only for genuinely AirDropped files —
/// ordinary browser downloads (a different quarantine agent) are ignored.
///
/// If it ever stops firing on a future macOS (the quarantine format changed), relax
/// `isAirDrop` to accept any newly added file.
@MainActor
final class AirDropWatcher {
    private let onArrival: () -> Void
    private let directory: URL
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    /// Files already present, so we only react to genuinely new arrivals.
    private var known: Set<String> = []

    init(onArrival: @escaping () -> Void) {
        self.onArrival = onArrival
        self.directory = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    func start() {
        known = currentEntries()

        fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write],
            queue: .main
        )
        src.setEventHandler { [weak self] in self?.scan() }
        src.setCancelHandler { [weak self] in
            if let fd = self?.fd, fd >= 0 { close(fd) }
            self?.fd = -1
        }
        source = src
        src.resume()
    }

    deinit {
        source?.cancel()
    }

    /// Diff the directory against what we last saw; any brand-new file that carries
    /// the AirDrop quarantine tag counts as an arrival.
    private func scan() {
        let entries = currentEntries()
        let added = entries.subtracting(known)
        known = entries

        for name in added {
            let url = directory.appendingPathComponent(name)
            // AirDrop first writes a temporary/partial file, then renames it into
            // place. Skip the in-flight temporaries; the final rename fires again.
            if name.hasPrefix(".") || url.pathExtension == "download" { continue }
            if Self.isAirDrop(url) {
                onArrival()
                break
            }
        }
    }

    private func currentEntries() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names)
    }

    /// True when a file's `com.apple.quarantine` xattr names AirDrop as the agent
    /// that placed it. The value is a `;`-separated record like
    /// `0081;<time>;com.apple.AirDrop;<uuid>`.
    private static func isAirDrop(_ url: URL) -> Bool {
        guard let value = quarantine(of: url.path) else { return false }
        return value.range(of: "AirDrop", options: .caseInsensitive) != nil
    }

    private static func quarantine(of path: String) -> String? {
        let name = "com.apple.quarantine"
        let length = getxattr(path, name, nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        let read = getxattr(path, name, &buffer, length, 0, 0)
        guard read > 0 else { return nil }
        return String(bytes: buffer[0..<read], encoding: .utf8)
    }
}
