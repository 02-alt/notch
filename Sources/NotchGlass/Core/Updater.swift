import AppKit
import SwiftUI

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

    /// Retains each live alert's window controller until its window closes. A set
    /// (not a single shared reference) so two dialogs — e.g. a background check and a
    /// manual one — can't step on each other: closing one must not close or orphan the
    /// other's window.
    private static var controllers: Set<NSWindowController> = []

    /// Presents a small dialog *above* the notch panel.
    ///
    /// We deliberately don't use `NSAlert.runModal()`: the notch panel is a borderless,
    /// full-width `.nonactivatingPanel` at `.statusBar + 1`, and `runModal()` forces its
    /// window down to `.modalPanel` (8) — below the panel — where the panel not only hides
    /// it but, being transparent over that whole region, also swallows the clicks meant for
    /// the OK button, so the modal can never be dismissed and the Mac appears frozen.
    /// Re-raising the level from a `DispatchQueue.main.async` block doesn't help either:
    /// the modal loop runs in `NSModalPanelRunLoopMode`, which isn't a common run-loop mode,
    /// so that block only fires *after* the alert is already gone.
    ///
    /// A plain `NSWindow` at `.statusBar + 2` (as the crash reporter uses) genuinely sits
    /// above the panel in the window server's hit-testing, so it both renders on top and
    /// receives the button clicks.
    @MainActor
    private static func present(title: String,
                               message: String,
                               actionTitle: String? = nil,
                               actionURL: URL? = nil) {
        NSApp.activate(ignoringOtherApps: true)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        let view = UpdaterAlertView(
            title: title,
            message: message,
            actionTitle: (actionTitle != nil && actionURL != nil) ? actionTitle : nil,
            onAction: { [weak window] in
                if let actionURL { NSWorkspace.shared.open(actionURL) }
                window?.close()
            },
            onClose: { [weak window] in window?.close() }
        )

        window.title = "NotchGlass"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.appearance = NSAppearance(named: Theme.isLight ? .aqua : .darkAqua)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.level = .statusBar + 2
        window.center()

        let controller = NSWindowController(window: window)
        controllers.insert(controller)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        // Drop *this* controller (and this observer) once its own window closes, so a
        // second dialog opened meanwhile is untouched and no observer leaks. The token is
        // held in a box so the @Sendable close handler can read it back to deregister.
        let box = ObserverBox()
        box.token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                controllers.remove(controller)
                if let token = box.token { NotificationCenter.default.removeObserver(token) }
            }
        }
    }

    /// Holds a NotificationCenter observer token so a `@Sendable` close handler can read
    /// it back to deregister itself. Touched only on the main queue.
    private final class ObserverBox: @unchecked Sendable {
        var token: NSObjectProtocol?
    }
}

/// The updater dialog's content: a title, a message, an optional link action
/// (e.g. "View Release"), and a default OK button.
private struct UpdaterAlertView: View {
    let title: String
    let message: String
    let actionTitle: String?
    let onAction: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.primaryText)
            Text(message)
                .font(.callout)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                if let actionTitle {
                    Button(actionTitle, action: onAction)
                }
                Button("OK", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 360, minHeight: 160)
        .background(Theme.isLight ? Color(white: 0.96) : Color(white: 0.12))
        .environment(\.colorScheme, Theme.colorScheme)
    }
}
