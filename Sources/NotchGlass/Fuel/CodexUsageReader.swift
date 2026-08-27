import Foundation

/// A ChatGPT (Codex) usage snapshot, mirroring what `FuelState` needs: the live 5-hour
/// and weekly utilization plus local token counts. Everything is read-only and
/// entirely local — we never call OpenAI, we just reuse the Codex CLI's login and its
/// session transcripts the same way the Claude side reuses Claude Code's.
struct CodexSnapshot {
    enum Status { case live, noAuth, noData }

    var status: Status = .noAuth

    var sessionUsed: Double?               // 0…1 of the 5-hour window used
    var sessionResetsAt: Date?
    var weekUsed: Double?                   // 0…1 of the weekly window used
    var weekResetsAt: Date?

    var blockTokens: Int = 0
    var todayTokens: Int = 0
    var topModel: String?
}

/// Reads ChatGPT usage from the local **Codex CLI** state — its OAuth login
/// (`~/.codex/auth.json`) and its rollout transcripts (`~/.codex/sessions/**/*.jsonl`).
///
/// Codex records a `token_count` event on every turn carrying both cumulative token
/// usage and a `rate_limits` snapshot (`primary` = 5-hour window, `secondary` = weekly),
/// so we can show the same live gauges as Claude without any network call — we simply
/// trust the most recent snapshot and re-anchor its `resets_in_seconds` to the line's
/// own timestamp. Best-effort and version-tolerant: if Codex isn't installed or signed
/// in, we degrade to a "not signed in" state exactly like the Claude side does.
enum CodexUsageReader {
    private static let sessionsPath = ("~/.codex/sessions" as NSString).expandingTildeInPath
    private static let authPath = ("~/.codex/auth.json" as NSString).expandingTildeInPath

    /// True when a Codex/ChatGPT login exists on this Mac.
    static func hasAuth() -> Bool {
        guard let data = FileManager.default.contents(atPath: authPath),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        // Either an API key or an OAuth token blob counts as signed in.
        if let key = o["OPENAI_API_KEY"] as? String, !key.isEmpty { return true }
        if let tokens = o["tokens"] as? [String: Any],
           let tok = tokens["access_token"] as? String, !tok.isEmpty { return true }
        return false
    }

    /// Blocking read — call on a background queue. `since` prunes old transcript files
    /// by mtime (the sessions folder grows without bound).
    static func load(windowHours: Double, since: Date) -> CodexSnapshot {
        var snap = CodexSnapshot()
        snap.status = hasAuth() ? .noData : .noAuth

        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: sessionsPath) else { return snap }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]
        func parseDate(_ s: String) -> Date? { iso.date(from: s) ?? isoPlain.date(from: s) }

        var entries: [UsageEntry] = []
        // The most recent rate-limit snapshot we've seen, with the line time it was
        // written at so we can turn `resets_in_seconds` into an absolute date.
        var latest: (at: Date, rl: [String: Any])?

        for case let rel as String in en where rel.hasSuffix(".jsonl") {
            let full = (sessionsPath as NSString).appendingPathComponent(rel)
            let mod = (try? fm.attributesOfItem(atPath: full)[.modificationDate]) as? Date
            if let mod, mod < since { continue }
            guard let data = fm.contents(atPath: full),
                  let text = String(data: data, encoding: .utf8) else { continue }

            // Model in effect for the current turn — Codex writes it in a turn/session
            // context line ahead of the token_count events it applies to.
            var currentModel = "gpt"

            text.enumerateLines { line, _ in
                guard line.contains("\"model\"") || line.contains("token") || line.contains("rate_limit") else { return }
                guard let ld = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: ld) as? [String: Any] else { return }

                let lineDate = (obj["timestamp"] as? String).flatMap(parseDate) ?? mod ?? Date()

                // Payload is where Codex nests everything; fall back to the top level for
                // older formats that stored fields flat.
                let payload = (obj["payload"] as? [String: Any]) ?? obj

                if let model = (payload["model"] as? String) ?? (obj["model"] as? String), !model.isEmpty {
                    currentModel = model
                }

                // A token_count event: cumulative + per-turn usage, plus rate limits.
                let info = (payload["info"] as? [String: Any]) ?? payload
                if let last = info["last_token_usage"] as? [String: Any],
                   let total = intVal(last["total_tokens"]), total > 0 {
                    entries.append(UsageEntry(date: lineDate, tokens: total, model: currentModel))
                }

                if let rl = (payload["rate_limits"] as? [String: Any]) ?? (info["rate_limits"] as? [String: Any]) {
                    if latest == nil || lineDate > latest!.at { latest = (lineDate, rl) }
                }
            }
        }

        // Live gauges from the freshest rate-limit snapshot.
        if let latest {
            func window(_ key: String) -> (Double, Date?)? {
                guard let w = latest.rl[key] as? [String: Any],
                      let pct = dblVal(w["used_percent"]) else { return nil }
                let resets = intVal(w["resets_in_seconds"]).map { latest.at.addingTimeInterval(Double($0)) }
                return (min(1, max(0, pct / 100)), resets)
            }
            if let p = window("primary") { snap.sessionUsed = p.0; snap.sessionResetsAt = p.1 }
            if let s = window("secondary") { snap.weekUsed = s.0; snap.weekResetsAt = s.1 }
            if snap.sessionUsed != nil { snap.status = .live }
        }

        // Local token counts (this block / today), reusing the Claude block logic.
        if !entries.isEmpty {
            entries.sort { $0.date < $1.date }
            let cal = Calendar.current
            snap.todayTokens = entries.filter { cal.isDateInToday($0.date) }.reduce(0) { $0 + $1.tokens }
            if let block = UsageReader.currentBlock(entries: entries, windowHours: windowHours), block.isActive {
                snap.blockTokens = block.used
                snap.topModel = block.perModel.max { $0.value < $1.value }.map { shortModel($0.key) }
            }
            if snap.status == .noData { snap.status = .live } // have data even if no rate limits
        }

        return snap
    }

    private static func intVal(_ any: Any?) -> Int? {
        (any as? Int) ?? (any as? NSNumber)?.intValue
    }
    private static func dblVal(_ any: Any?) -> Double? {
        (any as? Double) ?? (any as? NSNumber)?.doubleValue ?? (any as? Int).map(Double.init)
    }

    /// Pretty short name for an OpenAI model id ("gpt-5-codex" → "GPT-5", "o3" → "o3").
    private static func shortModel(_ m: String) -> String {
        let x = m.lowercased()
        if x.contains("gpt-5") || x.contains("gpt5") { return "GPT-5" }
        if x.contains("gpt-4.1") { return "GPT-4.1" }
        if x.contains("gpt-4o") { return "GPT-4o" }
        if x.contains("gpt-4") { return "GPT-4" }
        if x.hasPrefix("o4") { return "o4" }
        if x.hasPrefix("o3") { return "o3" }
        if x.hasPrefix("o1") { return "o1" }
        return String(m.prefix(8))
    }
}
