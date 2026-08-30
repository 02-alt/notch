import SwiftUI
import AppKit

/// Captures uncaught Objective-C exceptions to a rolling log and, on the *next*
/// launch, surfaces the last crash in a small report window so a failure in this
/// borderless agent app doesn't just vanish silently.
///
/// Note: this only catches Obj-C `NSException`s (via
/// `NSSetUncaughtExceptionHandler`). Swift runtime traps — force-unwrap of nil,
/// out-of-bounds, `fatalError`, arithmetic overflow — raise `SIGTRAP`/`SIGILL`
/// and bypass this handler; those still land only in the system crash reporter.
@MainActor
enum CrashReporter {
    /// ~/Library/Logs/NotchGlass — the app's log home.
    private static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/NotchGlass", isDirectory: true)
    }

    /// The appended crash log. The uncaught-exception handler is a bare C
    /// function pointer that can't close over anything, so it re-derives this
    /// same path itself (see `installHandler`).
    static var logURL: URL {
        logDirectory.appendingPathComponent("crash.log")
    }

    /// UserDefaults key holding the mtime of the crash log the user has already
    /// seen, so we present each crash exactly once instead of on every launch.
    private static let seenKey = "CrashReporter.lastSeenLogDate"

    /// Retains the report window controller for the lifetime of the window.
    private static var windowController: NSWindowController?

    // MARK: - Install

    /// Registers the uncaught-exception handler. Call once at launch.
    static func installHandler() {
        NSSetUncaughtExceptionHandler { exception in
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/NotchGlass", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let logURL = dir.appendingPathComponent("crash.log")

            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
            let report = """
            [\(Date())] NotchGlass \(version) — \(exception.name.rawValue)
            \(exception.reason ?? "no reason")

            \(exception.callStackSymbols.joined(separator: "\n"))

            """
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(Data(report.utf8))
                try? handle.close()
            } else {
                try? report.write(to: logURL, atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: - Present pending report

    /// If the crash log has grown since the user last saw it, open the report
    /// window. Call once at launch, after the panel is up.
    static func presentPendingReportIfNeeded() {
        guard let mtime = logModifiedDate(),
              let contents = try? String(contentsOf: logURL, encoding: .utf8),
              !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        let seen = UserDefaults.standard.double(forKey: seenKey)
        // A tiny epsilon avoids re-showing on float round-trips of the same date.
        guard mtime.timeIntervalSinceReferenceDate > seen + 0.5 else { return }

        showWindow(report: lastEntry(in: contents), fullLog: contents)
    }

    /// Marks the current log as seen so it won't reappear next launch.
    private static func markSeen() {
        guard let mtime = logModifiedDate() else { return }
        UserDefaults.standard.set(mtime.timeIntervalSinceReferenceDate, forKey: seenKey)
    }

    private static func logModifiedDate() -> Date? {
        try? FileManager.default.attributesOfItem(atPath: logURL.path)[.modificationDate] as? Date
    }

    /// The most recent crash entry — everything from the last `[timestamp]`
    /// header onward. Entries are separated by those bracketed header lines.
    private static func lastEntry(in log: String) -> String {
        let trimmed = log.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: "\n[", options: .backwards) {
            return String(trimmed[trimmed.index(after: range.lowerBound)...])
        }
        return trimmed
    }

    // MARK: - Window

    private static func showWindow(report: String, fullLog: String) {
        // Front-most an accessory app, then build a standard titled window that
        // hosts the SwiftUI report and retain its controller.
        NSApp.activate(ignoringOtherApps: true)

        let view = CrashReportView(
            report: report,
            onReveal: { NSWorkspace.shared.activateFileViewerSelecting([logURL]) },
            onClear: { clearLog(); closeWindow() },
            onClose: { closeWindow() }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "NotchGlass — Crash Report"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.appearance = NSAppearance(named: Theme.isLight ? .aqua : .darkAqua)

        let controller = NSWindowController(window: window)
        windowController = controller
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)

        // Whether closed via our button or the traffic light, count it as seen.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                markSeen()
                windowController = nil
            }
        }
    }

    private static func closeWindow() {
        windowController?.window?.close()
    }

    private static func clearLog() {
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
    }
}

/// The report window's SwiftUI content — the last crash in a monospaced,
/// selectable scroll view with copy / reveal / clear / close actions.
private struct CrashReportView: View {
    let report: String
    let onReveal: () -> Void
    let onClear: () -> Void
    let onClose: () -> Void

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("NotchGlass quit unexpectedly")
                        .font(.headline)
                        .foregroundStyle(Theme.primaryText)
                    Text("The details below were saved from the last crash.")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
            }

            ScrollView {
                Text(report)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.primaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.cardFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Theme.cardStroke, lineWidth: 1)
                    }
            }

            HStack {
                Button(role: .destructive, action: onClear) {
                    Text("Clear Log")
                }
                Spacer()
                Button(action: copy) {
                    Text(copied ? "Copied" : "Copy")
                }
                Button("Reveal in Finder", action: onReveal)
                Button("Close", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(minWidth: 440, minHeight: 320)
        .background(Theme.isLight ? Color(white: 0.96) : Color(white: 0.12))
        .environment(\.colorScheme, Theme.colorScheme)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        copied = true
    }
}
