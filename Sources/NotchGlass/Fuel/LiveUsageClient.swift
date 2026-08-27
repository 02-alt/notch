import Foundation

/// One usage window (session or weekly) as reported by Anthropic's server.
struct LiveWindow {
    let utilization: Double   // 0…100 percent used
    let resetsAt: Date
}

/// Extra-usage ("credits") spend, straight from the endpoint's `spend` block. Once a
/// token window runs dry, Claude keeps you going on pay-as-you-go credits; this is the
/// server's already-computed running spend (no local pricing table involved).
struct LiveCredits {
    let usedMinor: Int
    let limitMinor: Int      // 0 = no cap set
    let currency: String     // ISO code, e.g. "EUR"
    let exponent: Int        // minor-unit exponent, e.g. 2 → /100
    let enabled: Bool        // extra usage is currently switched on (spend.enabled)
    let critical: Bool       // spend.severity == "critical" (at/over the cap)
    let everEnabled: Bool    // credits have ever been enabled on this account

    var used: Double  { Double(usedMinor)  / pow(10, Double(exponent)) }
    var limit: Double { Double(limitMinor) / pow(10, Double(exponent)) }
}

struct LiveUsage {
    let session: LiveWindow?
    let week: LiveWindow?
    let credits: LiveCredits?
}

/// Why a live fetch did (or didn't) work — so the Fuel tab can say "not signed in"
/// or "offline" instead of silently showing nothing.
enum LiveFetchResult {
    case ok(LiveUsage)
    case noToken            // no OAuth credentials on this Mac (not signed in to Claude Code)
    case unauthorized       // 401/403 — token expired or revoked; sign in again
    case rateLimited(retryAfter: TimeInterval?)  // 429 — too many requests; server-suggested wait if any
    case http(Int)          // some other HTTP status
    case offline(String)    // network error / timeout
    case badData            // 200 but the body didn't parse
}

/// Reads the real, authoritative usage from Anthropic's undocumented OAuth usage
/// endpoint (the same data behind Claude Code's `/usage`), using the CLI's local
/// OAuth token. This endpoint is unofficial and may change.
enum LiveUsageClient {

    // Must start with `claude-code/` or the endpoint 429s.
    private static let ua = "claude-code/2.1.201"
    static let endpoint = "https://api.anthropic.com/api/oauth/usage"

    /// Blocking fetch — call on a background queue. Reports why it succeeded/failed.
    static func fetchDetailed(timeout: TimeInterval = 12) -> LiveFetchResult {
        guard let creds = Credentials.load() else { return .noToken }
        return fetchOnce(token: creds.accessToken, timeout: timeout)
    }

    private static func fetchOnce(token tok: String, timeout: TimeInterval) -> LiveFetchResult {
        guard let url = URL(string: endpoint) else { return .offline("bad endpoint URL") }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let sem = DispatchSemaphore(value: 0)
        var result: LiveFetchResult = .offline("no response")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err { result = .offline(err.localizedDescription); return }
            guard let http = resp as? HTTPURLResponse else { result = .offline("no response"); return }
            switch http.statusCode {
            case 200:
                guard let data, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    result = .badData; return
                }
                func window(_ key: String) -> LiveWindow? {
                    guard let w = o[key] as? [String: Any] else { return nil }
                    let u = (w["utilization"] as? Double) ?? (w["utilization"] as? NSNumber)?.doubleValue ?? 0
                    guard let rs = w["resets_at"] as? String, let d = parseISO(rs) else { return nil }
                    return LiveWindow(utilization: u, resetsAt: d)
                }
                func int(_ v: Any?) -> Int? { (v as? Int) ?? (v as? NSNumber)?.intValue }
                func credits() -> LiveCredits? {
                    guard let sp = o["spend"] as? [String: Any],
                          let used = sp["used"] as? [String: Any],
                          let um = int(used["amount_minor"]) else { return nil }
                    let lim = sp["limit"] as? [String: Any]
                    let everEnabled = ((o["extra_usage"] as? [String: Any])?["credits_ever_enabled"] as? Bool) ?? (um > 0)
                    return LiveCredits(usedMinor: um,
                                       limitMinor: int(lim?["amount_minor"]) ?? 0,
                                       currency: (used["currency"] as? String) ?? "USD",
                                       exponent: int(used["exponent"]) ?? 2,
                                       enabled: (sp["enabled"] as? Bool) ?? false,
                                       critical: (sp["severity"] as? String) == "critical",
                                       everEnabled: everEnabled)
                }
                result = .ok(LiveUsage(session: window("five_hour"), week: window("seven_day"), credits: credits()))
            case 401, 403: result = .unauthorized
            case 429:      result = .rateLimited(retryAfter: retryAfter(from: http))
            default:       result = .http(http.statusCode)
            }
        }.resume()
        if sem.wait(timeout: .now() + timeout + 2) == .timedOut { return .offline("request timed out") }
        return result
    }

    /// The server's suggested cool-off from a 429, from the `Retry-After` header.
    /// Supports both the delta-seconds form ("30") and the HTTP-date form.
    private static func retryAfter(from http: HTTPURLResponse) -> TimeInterval? {
        guard let raw = (http.value(forHTTPHeaderField: "Retry-After")
                         ?? http.value(forHTTPHeaderField: "retry-after"))?
                .trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let secs = TimeInterval(raw) { return max(0, secs) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        if let d = f.date(from: raw) { return max(0, d.timeIntervalSinceNow) }
        return nil
    }

    // Handles microsecond fractional seconds like "2026-07-29T22:59:59.065724+00:00".
    static func parseISO(_ s: String) -> Date? {
        var str = s
        if let dot = str.firstIndex(of: "."),
           let end = str[dot...].firstIndex(where: { $0 == "+" || $0 == "Z" || $0 == "-" }) {
            str.removeSubrange(dot..<end)
        }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        return f.date(from: str)
    }
}
