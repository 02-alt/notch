import Foundation

/// One timed line of a synced lyric: the second it begins, and its text (which may
/// be empty for an instrumental gap between verses).
struct LyricLine: Equatable {
    let time: Double
    let text: String
}

/// Fetches time-synced lyrics for the current track from **LRCLIB** (lrclib.net) — a
/// free, key-less, community lyrics database — parses the LRC timestamps into
/// `LyricLine`s, and caches each result on disk so a repeat play is instant and works
/// offline. It carries no player state of its own: `LyricsTabView` feeds it the track
/// metadata from `NowPlayingManager` and reads back `state`.
///
/// LRCLIB is the right source here because it needs no API key and returns real
/// `[mm:ss.xx]` synced lyrics; we set a descriptive `User-Agent` as their docs ask.
@MainActor
final class LyricsService: ObservableObject {
    /// Where a lookup currently stands, so the tab can distinguish "still loading"
    /// from "this track genuinely has no synced lyrics" from "we're offline".
    enum State: Equatable {
        case idle                    // nothing requested yet (nothing playing)
        case loading
        case synced([LyricLine])     // timed lyrics — the good case
        case plain(String)           // lyrics exist but aren't timed; shown static
        case instrumental            // LRCLIB flagged the track as instrumental
        case notFound                // no match in the database
        case offline                 // network failed and nothing was cached
    }

    @Published private(set) var state: State = .idle

    /// Identity of the track the current `state` belongs to, so a stale in-flight
    /// fetch that resolves after the song changed is ignored.
    private var currentKey = ""
    private var task: Task<Void, Never>?

    private static let session = URLSession.shared
    // LRCLIB asks clients to identify themselves; include the app + a contact link.
    private static let userAgent = "AllInANotch (macOS notch app; https://github.com/)"

    /// Request synced lyrics for a track. Cheap to call on every metadata change: it
    /// no-ops when the track hasn't changed, and dedupes overlapping fetches.
    func load(title: String, artist: String, album: String, duration: Double) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        // Callers gate on `NowPlayingManager.hasTrack`; an empty title is the only
        // secondary guard we need (and we avoid hard-coding its "nothing" sentinel).
        guard !cleanTitle.isEmpty else {
            clear()
            return
        }
        let key = Self.cacheKey(title: cleanTitle, artist: cleanArtist, duration: duration)
        guard key != currentKey else { return }   // same track — keep what we have
        currentKey = key
        task?.cancel()
        state = .loading

        task = Task { [key] in
            // Cache hit? Serve it. File I/O runs off the main actor so a slow disk
            // never stalls the notch's animation.
            if let cached = await Self.readCache(key: key) {
                guard !Task.isCancelled, key == currentKey else { return }
                state = Self.state(from: cached)
                return
            }
            switch await Self.fetch(title: cleanTitle, artist: cleanArtist,
                                    album: album, duration: duration) {
            case .answered(let payload):
                // A definitive server answer (lyrics, instrumental, or a real miss)
                // is safe to persist — an outage is not (see `.failed`).
                await Self.writeCache(key: key, payload)
                guard !Task.isCancelled, key == currentKey else { return }
                state = Self.state(from: payload)
            case .failed:
                guard !Task.isCancelled, key == currentKey else { return }
                state = .offline
                // Clear the key so the same track can be retried once the network
                // recovers (otherwise the dedupe guard would pin it to .offline).
                currentKey = ""
            }
        }
    }

    /// Fetch lyrics for whatever `NowPlayingManager` is currently playing. The single
    /// owner of "which track fields feed a lyric lookup", so the app-scope pin sink and
    /// the Media tab's lyrics view can't drift on the mapping.
    func load(for np: NowPlayingManager) {
        load(title: np.title, artist: np.artist, album: np.album, duration: np.duration)
    }

    /// Reset to the resting state when playback stops.
    func clear() {
        task?.cancel()
        currentKey = ""
        state = .idle
    }

    /// The index of the line that should be highlighted at `position` — the last line
    /// whose timestamp has passed. `nil` before the first line begins (intro).
    func activeIndex(at position: Double) -> Int? {
        guard case .synced(let lines) = state else { return nil }
        // `lastIndex` already returns nil when `position` precedes the first line.
        return lines.lastIndex { $0.time <= position }
    }

    /// True when the current track has timed lyrics — used to decide whether the
    /// collapsed notch should widen into a "lyrics ticker" for this song.
    var hasSyncedLyrics: Bool {
        if case .synced = state { return true }
        return false
    }

    /// The single gate for "show the pinned-lyrics ticker on the collapsed notch":
    /// the pin is on, something's playing, and it has synced lyrics. Shared by
    /// `RootView` (pill width) and `CollapsedMediaView` (content) so the two never drift.
    func tickerActive(pinned: Bool, hasTrack: Bool) -> Bool {
        pinned && hasTrack && hasSyncedLyrics
    }

    /// The lyric to show on the collapsed ticker at `position`: the most recent *sung*
    /// line whose time has passed. It deliberately skips the empty gap-marker lines, so
    /// during a long instrumental break the last line lingers instead of the ticker
    /// blanking (and falling back to the track title). Nil only before the first line.
    func currentLine(at position: Double) -> String? {
        guard case .synced(let lines) = state else { return nil }
        return lines.last { $0.time <= position && !$0.text.isEmpty }?.text
    }

    // MARK: - Networking

    /// The payload we cache: the raw strings LRCLIB returned, so we can re-derive the
    /// `State` (and re-parse the LRC) without another request.
    private struct Payload: Codable, Sendable {
        var synced: String? = nil
        var plain: String? = nil
        var instrumental: Bool = false
    }

    /// The outcome of a lookup. `.answered` is a definitive result from the server
    /// (safe to cache, even when it means "no lyrics"); `.failed` is a transport error
    /// or outage (never cached, so it's retried later).
    private enum Outcome: Sendable {
        case answered(Payload)
        case failed
    }

    /// One lookup: try the exact-match `/api/get` first, then fall back to `/api/search`
    /// (fuzzier) when the exact match 404s.
    private static func fetch(title: String, artist: String,
                              album: String, duration: Double) async -> Outcome {
        // Exact match: LRCLIB matches duration within a couple of seconds.
        var get = URLComponents(string: "https://lrclib.net/api/get")!
        get.queryItems = [
            .init(name: "track_name", value: title),
            .init(name: "artist_name", value: artist),
            album.isEmpty ? nil : .init(name: "album_name", value: album),
            duration > 0 ? .init(name: "duration", value: String(Int(duration.rounded()))) : nil,
        ].compactMap { $0 }

        switch await request(get.url!) {
        case .hit(let payload): return .answered(payload)
        case .failed:           return .failed
        case .miss:             break   // 404 → fall through to search
        }

        // Miss (404): a looser search on title + artist. Prefer a result whose
        // duration is close to the playing track's, so we don't sync to a different
        // edit/version; then prefer one that actually has synced lyrics.
        var search = URLComponents(string: "https://lrclib.net/api/search")!
        search.queryItems = [
            .init(name: "track_name", value: title),
            .init(name: "artist_name", value: artist),
        ]
        do {
            let (data, resp) = try await session.data(for: req(search.url!))
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else { return .answered(Payload()) }
            let candidates = duration > 0
                ? arr.filter { abs(($0["duration"] as? Double ?? 0) - duration) <= 3 }
                : arr
            let pool = candidates.isEmpty ? arr : candidates
            let best = pool.first { ($0["syncedLyrics"] as? String)?.isEmpty == false } ?? pool.first
            return .answered(best.map(payload(from:)) ?? Payload())
        } catch {
            return .failed
        }
    }

    private enum GetResult { case hit(Payload); case miss; case failed }

    /// A single `/api/get` request. `.hit` on 200, `.miss` on 404 (caller tries
    /// search), `.failed` on a transport error or any other status (an outage must
    /// not be cached as a permanent "no lyrics").
    private static func request(_ url: URL) async -> GetResult {
        do {
            let (data, resp) = try await session.data(for: req(url))
            guard let http = resp as? HTTPURLResponse else { return .failed }
            switch http.statusCode {
            case 200:
                guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .hit(Payload())
                }
                return .hit(payload(from: o))
            case 404:
                return .miss
            default:
                return .failed
            }
        } catch {
            return .failed
        }
    }

    private static func req(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url, timeoutInterval: 12)
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return r
    }

    private static func payload(from o: [String: Any]) -> Payload {
        Payload(synced: (o["syncedLyrics"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                plain: (o["plainLyrics"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                instrumental: (o["instrumental"] as? Bool) ?? false)
    }

    private static func state(from p: Payload) -> State {
        if let synced = p.synced {
            let lines = parseLRC(synced)
            if !lines.isEmpty { return .synced(lines) }
        }
        if let plain = p.plain { return .plain(plain) }
        if p.instrumental { return .instrumental }
        return .notFound
    }

    // MARK: - LRC parsing

    /// Turns an LRC blob into sorted `LyricLine`s. Handles multi-timestamp lines
    /// (`[00:12.34][00:15.00] text`) and skips metadata tags (`[ar:…]`, `[ti:…]`).
    static func parseLRC(_ raw: String) -> [LyricLine] {
        var out: [LyricLine] = []
        for rawLine in raw.split(whereSeparator: \.isNewline) {
            var rest = Substring(rawLine)
            var stamps: [Double] = []
            // Consume every leading `[...]` bracket group on the line.
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                if let t = parseStamp(tag) { stamps.append(t) }
                rest = rest[rest.index(after: close)...]
            }
            guard !stamps.isEmpty else { continue }   // metadata-only or untimed line
            let text = rest.trimmingCharacters(in: .whitespaces)
            for s in stamps { out.append(LyricLine(time: s, text: text)) }
        }
        return out.sorted { $0.time < $1.time }
    }

    /// Parses a `mm:ss.xx` or `hh:mm:ss.xx` timestamp into seconds. Returns nil for
    /// non-time tags like `ti:Song Name`, so those get skipped.
    private static func parseStamp(_ s: Substring) -> Double? {
        let parts = s.split(separator: ":")
        switch parts.count {
        case 2:
            guard let m = Double(parts[0]), let sec = Double(parts[1]) else { return nil }
            return m * 60 + sec
        case 3:
            guard let h = Double(parts[0]), let m = Double(parts[1]), let sec = Double(parts[2])
            else { return nil }
            return h * 3600 + m * 60 + sec
        default:
            return nil
        }
    }

    // MARK: - Disk cache
    //
    // The read/write helpers are `nonisolated` and hop to a detached task so file I/O
    // never runs on the main actor and stalls the UI.

    private static func cacheKey(title: String, artist: String, duration: Double) -> String {
        "\(artist.lowercased())|\(title.lowercased())|\(Int(duration.rounded()))"
    }

    nonisolated private static func cacheDir() -> URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("AllInANotch/Lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A stable filename for a cache key (its bytes, hex-encoded, so any characters in
    /// a title/artist are filesystem-safe).
    nonisolated private static func cacheFile(key: String) -> URL? {
        let name = Data(key.utf8).map { String(format: "%02x", $0) }.joined()
        return cacheDir()?.appendingPathComponent(name).appendingPathExtension("json")
    }

    nonisolated private static func readCache(key: String) async -> Payload? {
        await Task.detached {
            guard let file = cacheFile(key: key), let data = try? Data(contentsOf: file) else { return nil }
            return try? JSONDecoder().decode(Payload.self, from: data)
        }.value
    }

    nonisolated private static func writeCache(key: String, _ payload: Payload) async {
        await Task.detached {
            guard let file = cacheFile(key: key), let data = try? JSONEncoder().encode(payload) else { return }
            try? data.write(to: file, options: .atomic)
        }.value
    }
}
