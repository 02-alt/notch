import AppKit

/// Lightweight update check. Point `feedURL` at a GitHub "latest release" API
/// endpoint to enable real checks; until then it reports that you're up to date.
enum Updater {
    /// GitHub "latest release" API — used to compare the newest published tag
    /// against the running version.
    static let feedURL: URL? = URL(string: "https://api.github.com/repos/02-alt/notch/releases/latest")

    /// Where "View Release" sends the user when an update is found.
    static let releasesPage = URL(string: "https://github.com/02-alt/notch/releases/latest")

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    @MainActor
    static func checkForUpdates() {
        guard let feedURL else {
            present(title: "You're up to date",
                    message: "NotchGlass \(currentVersion) is the latest version.")
            return
        }

        Task { @MainActor in
            do {
                var request = URLRequest(url: feedURL)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, _) = try await URLSession.shared.data(for: request)
                let latest = try parseLatestVersion(from: data)

                if isNewer(latest, than: currentVersion) {
                    present(title: "Update available",
                            message: "Version \(latest) is available — you have \(currentVersion).",
                            actionTitle: "View Release",
                            actionURL: releasesPage)
                } else {
                    present(title: "You're up to date",
                            message: "NotchGlass \(currentVersion) is the latest version.")
                }
            } catch {
                present(title: "Couldn't check for updates",
                        message: error.localizedDescription)
            }
        }
    }

    // MARK: - Parsing / comparison

    private struct Release: Decodable { let tag_name: String }

    private static func parseLatestVersion(from data: Data) throws -> String {
        let release = try JSONDecoder().decode(Release.self, from: data)
        return release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
    }

    /// Numeric, component-wise semver comparison (e.g. "1.10" > "1.9").
    private static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        let a = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let b = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Alert

    @MainActor
    private static func present(title: String,
                               message: String,
                               actionTitle: String? = nil,
                               actionURL: URL? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if let actionTitle, actionURL != nil {
            alert.addButton(withTitle: actionTitle)
        }
        alert.addButton(withTitle: "OK")

        // The notch panel floats at `.statusBar + 1`. A default alert opens *below*
        // that, so it's hidden behind the notch — and since `runModal` blocks the run
        // loop, it can't be reached to dismiss, which reads as the whole Mac freezing.
        // Float the alert one level above the panel and center it clear of the notch.
        let window = alert.window
        window.level = .statusBar + 2
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.center()
        window.orderFrontRegardless()

        let response = alert.runModal()
        if actionTitle != nil, response == .alertFirstButtonReturn, let actionURL {
            NSWorkspace.shared.open(actionURL)
        }
    }
}
