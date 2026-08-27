import Foundation

/// A single token-usage record parsed from a Claude Code transcript line.
struct UsageEntry {
    let date: Date
    let tokens: Int
    let model: String
}

/// A rolling usage "block" (ccusage-style) — a 5-hour window of activity and the
/// tokens spent inside it.
struct UsageBlock {
    var start: Date
    var end: Date            // start + window
    var used: Int
    var lastActivity: Date
    var perModel: [String: Int]
    var isActive: Bool       // window still open and recently active
}

/// Reads local token usage from Claude Code's `~/.claude/projects/**/*.jsonl`
/// transcripts. Used to enrich the Fuel tab with real token counts (this block /
/// today / lifetime), independent of the live server utilization.
enum UsageReader {

    /// - Parameter since: when set, transcript files last modified before this date
    ///   are skipped. The projects folder can be gigabytes; for the current block /
    ///   today's totals we only need the last day or so, which prunes almost all of
    ///   the scan (a full read of ~1GB takes ~10s+).
    static func load(projectsPath: String, includeCacheReads: Bool, since: Date? = nil) -> [UsageEntry] {
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: projectsPath) else { return [] }
        var entries: [UsageEntry] = []

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]

        for case let rel as String in en where rel.hasSuffix(".jsonl") {
            let full = (projectsPath as NSString).appendingPathComponent(rel)
            // A file whose last line predates `since` can't hold entries we need.
            if let since,
               let mod = (try? fm.attributesOfItem(atPath: full)[.modificationDate]) as? Date,
               mod < since {
                continue
            }
            guard let data = fm.contents(atPath: full),
                  let text = String(data: data, encoding: .utf8) else { continue }

            text.enumerateLines { line, _ in
                // Cheap pre-filter: only assistant lines carry a usage object.
                guard line.contains("\"usage\"") else { return }
                guard let ld = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: ld) as? [String: Any]
                else { return }

                guard let ts = obj["timestamp"] as? String,
                      let msg = obj["message"] as? [String: Any],
                      let usage = msg["usage"] as? [String: Any] else { return }

                let date = iso.date(from: ts) ?? isoPlain.date(from: ts)
                guard let date else { return }

                let input  = usage["input_tokens"] as? Int ?? 0
                let output = usage["output_tokens"] as? Int ?? 0
                let cc     = usage["cache_creation_input_tokens"] as? Int ?? 0
                let cr     = usage["cache_read_input_tokens"] as? Int ?? 0
                var total = input + output + cc
                if includeCacheReads { total += cr }
                let model = (msg["model"] as? String) ?? "unknown"
                if total == 0 || model == "<synthetic>" { return }

                entries.append(UsageEntry(date: date, tokens: total, model: model))
            }
        }
        entries.sort { $0.date < $1.date }
        return entries
    }

    /// Group entries into rolling windows and return the one that's currently
    /// active — i.e. your live token "tank" for this session block.
    static func currentBlock(entries: [UsageEntry], windowHours: Double, now: Date = Date()) -> UsageBlock? {
        guard var block = blocks(entries: entries, windowHours: windowHours).last else { return nil }
        block.isActive = now < block.end && now.timeIntervalSince(block.lastActivity) < window(windowHours)
        return block
    }

    /// The number of distinct session blocks whose activity falls on `now`'s
    /// calendar day — i.e. how many separate 5-hour tanks you've drawn from today.
    static func sessionsToday(entries: [UsageEntry], windowHours: Double, now: Date = Date()) -> Int {
        let cal = Calendar.current
        return blocks(entries: entries, windowHours: windowHours)
            .filter { cal.isDate($0.lastActivity, inSameDayAs: now) }
            .count
    }

    private static func window(_ hours: Double) -> TimeInterval { hours * 3600 }

    /// Split entries into rolling 5-hour "blocks" (ccusage-style): a new block opens
    /// once the window since its start elapses, or after a gap of one window with no
    /// activity. Returned oldest-first; `isActive` is left false (see `currentBlock`).
    static func blocks(entries: [UsageEntry], windowHours: Double) -> [UsageBlock] {
        guard !entries.isEmpty else { return [] }
        let window = window(windowHours)

        func floorHour(_ d: Date) -> Date {
            let t = (d.timeIntervalSince1970 / 3600).rounded(.down) * 3600
            return Date(timeIntervalSince1970: t)
        }

        var blocks: [UsageBlock] = []
        var start = floorHour(entries[0].date)
        var used = 0
        var perModel: [String: Int] = [:]
        var last = entries[0].date

        func closeBlock() {
            blocks.append(UsageBlock(start: start, end: start.addingTimeInterval(window),
                                     used: used, lastActivity: last,
                                     perModel: perModel, isActive: false))
        }

        for e in entries {
            let sinceStart = e.date.timeIntervalSince(start)
            let sinceLast  = e.date.timeIntervalSince(last)
            if used > 0, sinceStart >= window || sinceLast >= window {
                closeBlock()
                start = floorHour(e.date)
                used = 0
                perModel = [:]
            }
            used += e.tokens
            perModel[e.model, default: 0] += e.tokens
            last = e.date
        }
        closeBlock()
        return blocks
    }
}
