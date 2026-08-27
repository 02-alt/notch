import Foundation

/// Reads the `claudeAiOauth` credential blob that Claude Code stores — the macOS
/// Keychain generic-password item (or `~/.claude/.credentials.json` on older /
/// Linux installs) — so the Fuel tab shares the CLI's login and can call the
/// usage endpoint with the same OAuth access token (no API key).
///
/// Read-only: unlike the standalone Token Fuel app we never mint or write tokens
/// back, so there's no keychain-write / OAuth-refresh surface here.
struct Credentials {
    var accessToken: String
    var expiresAt: Int?            // epoch milliseconds, as Claude Code stores it

    private static let service = "Claude Code-credentials"
    private static var filePath: String { ("~/.claude/.credentials.json" as NSString).expandingTildeInPath }

    /// True when the access token is expired (or within a minute of it). We can't
    /// refresh, so callers just try anyway and surface a sign-in prompt on 401.
    var isExpired: Bool {
        guard let ms = expiresAt else { return false }
        return Date().timeIntervalSince1970 * 1000 >= Double(ms) - 60_000
    }

    static func load() -> Credentials? {
        if let data = FileManager.default.contents(atPath: filePath), let c = parse(data) { return c }
        if let data = keychainRead(), let c = parse(data) { return c }
        return nil
    }

    private static func parse(_ data: Data) -> Credentials? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = o["claudeAiOauth"] as? [String: Any],
              let tok = oauth["accessToken"] as? String, !tok.isEmpty else { return nil }
        let exp = (oauth["expiresAt"] as? Int) ?? (oauth["expiresAt"] as? NSNumber)?.intValue
        return Credentials(accessToken: tok, expiresAt: exp)
    }

    // Read the CLI's keychain item via /usr/bin/security — no extra entitlements,
    // and it matches the exact item Claude Code created.
    private static func keychainRead() -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-w"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return data.isEmpty ? nil : data
    }
}
