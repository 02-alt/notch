import SwiftUI
import AppKit

/// Which player is currently driving playback. The `rawValue` must match the
/// scriptable application's name exactly (used in AppleScript `tell` blocks).
enum MediaSource: String, CaseIterable {
    case music = "Music"
    case spotify = "Spotify"
    case safari = "Safari"
    case chrome = "Google Chrome"
    case brave = "Brave Browser"
    case edge = "Microsoft Edge"
    case vivaldi = "Vivaldi"
    case arc = "Arc"

    var bundleID: String {
        switch self {
        case .music:   return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        case .safari:  return "com.apple.Safari"
        case .chrome:  return "com.google.Chrome"
        case .brave:   return "com.brave.Browser"
        case .edge:    return "com.microsoft.edgemac"
        case .vivaldi: return "com.vivaldi.Vivaldi"
        case .arc:     return "company.thebrowser.Browser"
        }
    }

    /// Browsers are read/controlled via injected JavaScript rather than the
    /// scriptable player commands the music apps expose.
    var isBrowser: Bool { self != .music && self != .spotify }

    /// Chromium browsers all share Chrome's `execute … javascript` AppleScript
    /// command; Safari uses its own `do JavaScript … in current tab`.
    var isChromium: Bool { isBrowser && self != .safari }

    var displayName: String {
        switch self {
        case .chrome:  return "Chrome"
        case .brave:   return "Brave"
        case .edge:    return "Edge"
        default:       return rawValue
        }
    }

    /// The live app icon, if the app is running.
    var appIcon: NSImage? {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == bundleID }?.icon
    }
}

/// One chapter of the current track: its start time (seconds) and title. Title is
/// empty when the source only exposes chapter boundaries but no names.
struct MediaChapter: Equatable, Sendable {
    var start: Double
    var title: String
}

/// Reads and controls now-playing state from Apple Music / Spotify via AppleScript,
/// and interpolates the playback position between polls for a smooth scrubber.
@MainActor
final class NowPlayingManager: ObservableObject {
    @Published var title: String = "Nothing Playing"
    @Published var artist: String = ""
    @Published var album: String = ""
    @Published var lyricLine: String = "No lyrics found"
    @Published var isPlaying: Bool = false
    @Published var duration: Double = 0        // seconds
    @Published var artwork: NSImage?
    @Published var hasTrack: Bool = false
    @Published var source: MediaSource?

    /// Identity used to decide when a *new* item should auto-expand the Dynamic Island.
    /// For a browser tab on YouTube we key on the video id, so the constant media-session
    /// metadata churn from hover-preview thumbnails (and a mere pause/resume/scrub of the
    /// same video) never re-fires the island; it only pops on a genuine video change.
    /// Everything else (native players, non-YouTube browser video) keys on the track's
    /// title/artist/album. Empty when nothing is playing.
    @Published var islandKey: String = ""

    /// Chapter start times (seconds, ascending, first is 0) when the current source
    /// exposes them — currently YouTube in a browser. Empty otherwise. Drives the
    /// segmented "chapter pill" scrubber.
    @Published var chapters: [MediaChapter] = []

    /// Apps that are currently running and can be selected (updated each poll).
    @Published var runningSources: [MediaSource] = []

    /// When set, playback tracking is pinned to this app instead of auto-detecting.
    @Published private(set) var manualSource: MediaSource?

    /// The source the UI should highlight as selected.
    var activeSource: MediaSource? { manualSource ?? source }

    /// A live stream (internet radio, live video) rather than a fixed-length track:
    /// there's no known duration, so there's nothing to scrub or count down to. Apple
    /// Music radio reports a `0` duration; a live browser `<video>` reports `Infinity`
    /// (normalised to `0` when read). Drives the simplified "live" player layout.
    var isLive: Bool { hasTrack && (!duration.isFinite || duration <= 0) }

    /// Live playhead position in seconds (interpolated).
    @Published var position: Double = 0

    /// Output volume of the active source, 0…1. Apple Music / Spotify expose their app
    /// `sound volume` (0–100, normalised here); a browser `<video>` exposes `.volume`.
    @Published var volume: Double = 0.5

    /// Whether the active source lets us read/set its volume (drives whether the
    /// volume slider is shown). Browsers and the native players do; nothing playing
    /// does not.
    @Published var supportsVolume: Bool = false

    /// Whether the active source can pop its video into Picture-in-Picture — i.e. it's
    /// a browser tab with a `<video>`. Native audio players cannot.
    var supportsPiP: Bool { hasTrack && (source?.isBrowser ?? false) }

    private var polledPosition: Double = 0
    private var lastPollDate = Date()
    private var timer: Timer?
    private var artworkKey: String = ""
    private var isScrubbing = false
    /// True while a background poll read is in flight, so overlapping ticks (a slow
    /// AppleScript read that runs past the 1 s timer) don't pile up concurrent reads.
    private var pollInFlight = false
    /// Suppresses the poll writing the volume back while the user is dragging the
    /// slider, so a stale read mid-drag can't fight the user's own adjustment.
    private var isAdjustingVolume = false

    /// The (1-based) window / tab indices of the browser tab we last found media in,
    /// so background-tab playback keeps being tracked and controlled even when a
    /// different tab (mail, docs, …) is frontmost. Re-discovered whenever it goes
    /// stale (tab navigated away, closed, or reordered).
    private var browserTab: (window: Int, tab: Int)?

    /// YouTube chapters are fetched *complete* from the Innertube API once per video
    /// (the per-poll DOM scrape only sees lazy-rendered rows/names). These cache that
    /// result so it isn't refetched every second.
    private var currentVideoID: String?           // the video the panel is showing now
    private var chapterVideoID: String?           // the video `fetchedChapters` belongs to
    private var fetchedChapters: [MediaChapter] = []
    private var chapterFetchInFlightID: String?   // a fetch already started for this id

    init() {
        requestAutomationForNativeSources()
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        // Smoothly advance the playhead between polls.
        let display = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(display, forMode: .common)
    }

    // MARK: - Position

    private func tick() {
        guard isPlaying, !isScrubbing, duration > 0 else { return }
        let elapsed = Date().timeIntervalSince(lastPollDate)
        position = min(polledPosition + elapsed, duration)
    }

    func beginScrub() { isScrubbing = true }

    func scrub(to seconds: Double) {
        isScrubbing = true
        position = seconds
    }

    func endScrub(at seconds: Double) {
        guard let source else { isScrubbing = false; return }
        if source.isBrowser {
            runBrowserJS(source, Self.jsSeek(to: seconds))
        } else {
            _ = Self.runScript(#"tell application "\#(source.rawValue)" to set player position to \#(Int(seconds))"#)
        }
        polledPosition = seconds
        lastPollDate = Date()
        isScrubbing = false
    }

    /// JS to seek a browser video to `seconds`. Prefers YouTube's own player API
    /// (`movie_player.seekTo`) because YouTube's playback controller re-syncs the
    /// `<video>` element and *reverts* a raw `currentTime` write — so setting
    /// `currentTime` alone makes the scrubber snap straight back. Falls back to
    /// `currentTime` for every other site (plain HTML5 video).
    private static func jsSeek(to seconds: Double) -> String {
        let t = Int(seconds)
        return "(function(){var t=\(t);var p=document.getElementById('movie_player');if(p&&p.seekTo){p.seekTo(t,true);return;}var v=document.querySelector('video');if(v)v.currentTime=t;})()"
    }

    // MARK: - Volume

    func beginVolumeAdjust() { isAdjustingVolume = true }

    /// Set the active source's output volume (0…1). Browsers unmute the `<video>` too,
    /// so nudging the slider up always makes sound; native players clamp to their 0–100
    /// `sound volume` scale.
    func setVolume(_ value: Double) {
        let v = min(max(value, 0), 1)
        volume = v                     // immediate — the slider tracks the finger
        scheduleVolumeCommit(v)
    }

    private var volumeCommitWork: DispatchWorkItem?
    private var lastVolumeCommit = Date.distantPast

    /// Push the volume to the actual player, throttled to ~12 Hz and always off the main
    /// thread. The slider previously ran a blocking AppleScript / browser-JS round-trip
    /// on every drag frame, which stuttered (and could beachball) the drag; now the UI
    /// tracks the finger instantly while the side-effect is coalesced and dispatched
    /// off-main, with a trailing write so the final resting value always lands.
    private func scheduleVolumeCommit(_ v: Double) {
        guard source != nil else { return }
        volumeCommitWork?.cancel()
        let minInterval = 0.08
        let since = Date().timeIntervalSince(lastVolumeCommit)
        if since >= minInterval {
            commitVolume(v)
        } else {
            let work = DispatchWorkItem { [weak self] in self?.commitVolume(v) }
            volumeCommitWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (minInterval - since), execute: work)
        }
    }

    private func commitVolume(_ v: Double) {
        guard let source else { return }
        lastVolumeCommit = Date()
        let script: String
        if source.isBrowser {
            let inner = "(function(){var vd=document.querySelector('video');if(vd){vd.muted=false;vd.volume=\(v);}})()"
            if let loc = browserTab {
                script = Self.tabScript(source, inner, window: loc.window, tab: loc.tab)
            } else {
                script = Self.scanScript(source, inner)
            }
        } else {
            script = #"tell application "\#(source.rawValue)" to set sound volume to \#(Int((v * 100).rounded()))"#
        }
        Task.detached(priority: .userInitiated) { _ = Self.runScript(script) }
    }

    func endVolumeAdjust() { isAdjustingVolume = false }

    /// Toggle Picture-in-Picture for the current browser video: exit if the tab already
    /// owns the PiP window, otherwise request it. No-op for native players.
    func togglePiP() {
        guard let source, source.isBrowser else { return }
        runBrowserJS(source, Self.jsTogglePiP)
    }

    // MARK: - Transport

    func playPause() {
        guard let source else { return }
        if source.isBrowser { runBrowserJS(source, Self.jsPlayPause) }
        else { sendAppCommand("playpause") }
        poll()
    }

    func next() {
        guard let source else { return }
        if source.isBrowser { runBrowserJS(source, Self.jsNext) }
        else { sendAppCommand("next track") }
        poll()
    }

    func previous() {
        guard let source else { return }
        if source.isBrowser { runBrowserJS(source, Self.jsPrev) }
        else { sendAppCommand("previous track") }
        poll()
    }

    /// Pin the panel to a specific source so you can browse between players. This
    /// only changes which app the panel *shows/controls* — it does not start or stop
    /// playback, so switching to a paused track leaves it paused and doesn't cut off
    /// whatever else is playing. Use the transport buttons to actually play it.
    func select(_ newSource: MediaSource) {
        manualSource = newSource
        poll()
    }

    private func sendAppCommand(_ command: String) {
        guard let source else { return }
        _ = Self.runScript(#"tell application "\#(source.rawValue)" to \#(command)"#)
    }

    // MARK: - Polling

    /// Schedule a poll. The blocking AppleScript reads run on a detached utility task
    /// (they can take 100 ms–1 s+, especially the browser tab scan), so the main thread
    /// — which drives the open/close spring, hover and the EQ — is never stalled. Only
    /// the input snapshot and the result apply touch the main actor. The `pollInFlight`
    /// guard drops overlapping ticks so a slow read never stacks concurrent scans.
    private func poll() {
        guard !isScrubbing, !pollInFlight else { return }
        pollInFlight = true

        // Snapshot the inputs on the main actor. Browsers only count as a source when
        // they actually have media; sources the user hasn't enabled are never touched,
        // so they never prompt.
        let enabled = SettingsStore.shared.enabledSources
        let tabSnapshot = browserTab

        Task.detached(priority: .utility) { [weak self] in
            let result = Self.readAll(enabled: enabled, browserTab: tabSnapshot)
            await self?.finishPoll(result)
        }
    }

    /// The result of one off-main read sweep: the state of every readable source, the
    /// list of sources found running, and the (possibly re-discovered) browser media tab.
    private struct PollResult: Sendable {
        var states: [MediaSource: TrackInfo]
        var running: [MediaSource]
        var browserTab: (window: Int, tab: Int)?
    }

    /// Read every enabled, running source once. Runs entirely off the main actor — all
    /// AppleScript I/O happens here. `browserTab` is threaded through so background-tab
    /// media stays tracked, and the updated value is returned for the main actor to store.
    private nonisolated static func readAll(enabled: Set<MediaSource>,
                                            browserTab: (window: Int, tab: Int)?) -> PollResult {
        var tab = browserTab
        var states: [MediaSource: TrackInfo] = [:]
        for source in MediaSource.allCases where enabled.contains(source) && isRunning(source) {
            if let info = readState(from: source, browserTab: &tab) { states[source] = info }
        }
        let running = MediaSource.allCases.filter { states[$0] != nil }
        return PollResult(states: states, running: running, browserTab: tab)
    }

    /// Apply an off-main read on the main actor: pick the active source and publish.
    private func finishPoll(_ result: PollResult) {
        pollInFlight = false
        // A scrub started while the read was in flight — its result is stale, drop it
        // so it can't yank the playhead out from under the user's drag.
        guard !isScrubbing else { return }

        browserTab = result.browserTab
        runningSources = result.running
        let states = result.states

        // A manually-chosen source pins tracking to it.
        if let manual = manualSource {
            if let info = states[manual] {
                apply(info, from: manual)
                return
            }
            // The chosen source stopped/quit — drop the override and auto-detect.
            manualSource = nil
        }

        // Pick the best source: a playing one wins; the preferred app breaks ties;
        // native apps edge out browsers; otherwise anything with a track.
        let preferred = SettingsStore.shared.mediaPriority
        func rank(_ source: MediaSource) -> Int {
            var r = 0
            if states[source]?.playing == true { r -= 100 }
            if source == preferred { r -= 10 }
            if !source.isBrowser { r -= 1 }
            return r
        }

        if let best = states.keys.min(by: { rank($0) < rank($1) }), let info = states[best] {
            apply(info, from: best)
        } else {
            clear()
        }
    }

    private struct TrackInfo: Sendable {
        var title: String
        var artist: String
        var album: String
        var duration: Double
        var position: Double
        var playing: Bool
        var artworkURL: String?
        var chapters: [MediaChapter] = []
        /// Output volume 0…1, or nil when the source doesn't expose one.
        var volume: Double?
        /// The YouTube video id, when the browser tab is on YouTube — used to fetch the
        /// complete chapter list once per video and to detect when it changes.
        var videoID: String?
    }

    /// Parse a `sec::title;;sec::title;;…` chapter string (the shared format emitted by
    /// both the DOM scrape and the Innertube fetch).
    private nonisolated static func parseChapters(_ raw: String) -> [MediaChapter] {
        guard !raw.isEmpty else { return [] }
        return raw.components(separatedBy: ";;").compactMap { seg in
            let kv = seg.components(separatedBy: "::")
            guard let start = Double(kv[0]) else { return nil }
            return MediaChapter(start: start, title: kv.count > 1 ? kv[1] : "")
        }
    }

    private nonisolated static func isRunning(_ source: MediaSource) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == source.bundleID }
    }

    private nonisolated static func readState(from source: MediaSource,
                                              browserTab: inout (window: Int, tab: Int)?) -> TrackInfo? {
        guard isRunning(source) else { return nil }
        if source.isBrowser { return readBrowserState(source, browserTab: &browserTab) }

        let durationExpr = source == .spotify
            ? "(duration of current track) / 1000"
            : "duration of current track"
        let artworkExpr = source == .spotify
            ? #"& linefeed & (artwork url of current track)"#
            : ""

        let script = """
        tell application "\(source.rawValue)"
            if player state is stopped then return "STOPPED"
            set trackName to name of current track
            set trackArtist to artist of current track
            set trackAlbum to album of current track
            set trackDur to \(durationExpr)
            set trackPos to player position
            set playState to (player state as text)
            set trackVol to sound volume
            return trackName & linefeed & trackArtist & linefeed & trackAlbum & linefeed & (trackDur as text) & linefeed & (trackPos as text) & linefeed & playState & linefeed & (trackVol as text) \(artworkExpr)
        end tell
        """

        guard let result = Self.runScript(script)?.stringValue, result != "STOPPED" else { return nil }
        let parts = result.components(separatedBy: "\n")
        guard parts.count >= 6 else { return nil }

        return TrackInfo(
            title: parts[0],
            artist: parts[1],
            album: parts[2],
            duration: Self.parseSeconds(parts[3]),
            position: Self.parseSeconds(parts[4]),
            playing: parts[5].lowercased().contains("playing"),
            // Volume is a 0–100 app property; artwork URL (Spotify only) trails it.
            artworkURL: parts.count >= 8 ? parts[7] : nil,
            volume: parts.count >= 7 ? Self.parseSeconds(parts[6]) / 100 : nil
        )
    }

    /// Parse a number AppleScript rendered as text. AppleScript formats reals using the
    /// *system locale*, so on a machine whose locale uses a comma decimal separator
    /// `player position` / `duration` come back as e.g. "231,4" — which `Double(_:)`
    /// (period-only) rejects, leaving the time readout and scrubber stuck at 0:00. Fall
    /// back to swapping the comma for a period so both separators work.
    private nonisolated static func parseSeconds(_ text: String) -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let value = Double(trimmed) { return value }
        return Double(trimmed.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    // MARK: - Browser (YouTube / any HTML5 <video>)

    /// JS reads a tab's <video> plus the Media Session metadata (which
    /// YouTube and most media sites populate), returning fields joined by `|||`.
    /// Single-quoted, one line, no backslashes — so it embeds in an AppleScript
    /// string without escaping.
    private nonisolated static let jsReadState = "(function(){var v=document.querySelector('video');if(!v)return '';var m=navigator.mediaSession&&navigator.mediaSession.metadata;var t=(m&&m.title)?m.title:document.title;var a=(m&&m.artist)?m.artist:'';var ar=(m&&m.artwork&&m.artwork.length)?m.artwork[m.artwork.length-1].src:'';var ch='';try{var best=[];var lists=document.querySelectorAll('ytd-macro-markers-list-renderer');for(var li=0;li<lists.length;li++){var items=lists[li].querySelectorAll('ytd-macro-markers-list-item-renderer');if(items.length<2)continue;var tmp=[],prev=-1,ok=true;for(var i=0;i<items.length;i++){var te=items[i].querySelector('#time');if(!te){ok=false;break;}var ps=te.textContent.trim().split(':');var sec=0;for(var k=0;k<ps.length;k++){sec=sec*60+parseInt(ps[k],10);}if(isNaN(sec)||sec<=prev){ok=false;break;}prev=sec;var ne=items[i].querySelector('#details h4')||items[i].querySelector('h4')||items[i].querySelector('.macro-markers');var nm=ne?ne.textContent.trim():(items[i].getAttribute('aria-label')||'');tmp.push(sec+'::'+nm);}if(ok&&tmp.length>best.length&&tmp[0].indexOf('0::')===0)best=tmp;}if(best.length>1)ch=best.join(';;');if(!ch){var c=document.querySelector('.ytp-chapters-container');if(c&&v.duration){var s=c.querySelectorAll('.ytp-chapter-hover-container');if(s.length>1){var ws=[],tot=0,j;for(j=0;j<s.length;j++){var w=s[j].getBoundingClientRect().width;ws.push(w);tot+=w;}if(tot>0){var acc=0,st=[];for(j=0;j<ws.length;j++){st.push(Math.round(acc/tot*v.duration)+'::');acc+=ws[j];}ch=st.join(';;');}}}}}catch(e){}return [t,a,'',((v.duration&&isFinite(v.duration)&&v.duration<1e9)?v.duration:0),(v.currentTime||0),(v.paused?'paused':'playing'),ar,ch,(v.muted?0:(v.volume||0)),(location.hostname.indexOf('youtube')>=0?((new URLSearchParams(location.search)).get('v')||''):'')].join('|||');})()"
    private static let jsPlayPause = "(function(){var v=document.querySelector('video');if(v){if(v.paused)v.play();else v.pause();}})()"
    /// Toggle Picture-in-Picture on the tab's <video>. Exits if this document already
    /// owns the PiP window, else requests it. Wrapped in try/catch so a browser that
    /// refuses (no support / blocked) just no-ops instead of throwing.
    private static let jsTogglePiP = "(function(){try{var v=document.querySelector('video');if(!v)return;if(v.webkitSetPresentationMode){v.webkitSetPresentationMode(v.webkitPresentationMode==='picture-in-picture'?'inline':'picture-in-picture');return;}if(document.pictureInPictureElement)document.exitPictureInPicture();else if(v.requestPictureInPicture)v.requestPictureInPicture();}catch(e){}})()"

    /// The *complete* chapter list, fetched from YouTube's own Innertube `/next`
    /// endpoint (the same private API the site uses) via a synchronous request in the
    /// page's context — so it carries the site's auth/cookies and needs no key of our
    /// own. Unlike the on-page DOM, which lazy-renders chapter rows and their names,
    /// this returns every `chapterRenderer` (start time + title) in one shot. Returns
    /// `sec::title;;sec::title;;…`, or "" if the video has no chapters. Run once per
    /// video (it's a network round-trip), never on the per-second poll.
    private static let jsFetchChapters = "(function(){try{var key=(window.ytcfg&&ytcfg.get&&ytcfg.get('INNERTUBE_API_KEY'));var ctx=(window.ytcfg&&ytcfg.get&&ytcfg.get('INNERTUBE_CONTEXT'));var vid=(new URLSearchParams(location.search)).get('v');if(!key||!ctx||!vid)return '';var x=new XMLHttpRequest();x.open('POST','/youtubei/v1/next?key='+key,false);x.setRequestHeader('Content-Type','application/json');x.send(JSON.stringify({context:ctx,videoId:vid}));if(x.status!==200)return '';var j=JSON.parse(x.responseText);var found=[];function walk(o,d){if(!o||d>16||found.length)return;if(Array.isArray(o)){var chs=[];for(var i=0;i<o.length;i++){var cr=o[i]&&o[i].chapterRenderer;if(cr&&cr.title&&typeof cr.timeRangeStartMillis!=='undefined'){chs.push(Math.round(cr.timeRangeStartMillis/1000)+'::'+(cr.title.simpleText||(cr.title.runs&&cr.title.runs[0].text)||''));}}if(chs.length>1){found=chs;return;}for(var i=0;i<o.length;i++)walk(o[i],d+1);}else if(typeof o==='object'){for(var k in o)walk(o[k],d+1);}}walk(j,0);return found.join(';;');}catch(e){return '';}})()"
    private static let jsNext = "(function(){var b=document.querySelector('.ytp-next-button');if(b)b.click();})()"
    private static let jsPrev = "(function(){var b=document.querySelector('.ytp-prev-button');if(b)b.click();else{var v=document.querySelector('video');if(v)v.currentTime=0;}})()"

    /// Run `js` in one specific tab (1-based indices) of a browser.
    private nonisolated static func tabScript(_ source: MediaSource, _ js: String, window w: Int, tab t: Int) -> String {
        if source == .safari {
            return "tell application \"Safari\" to do JavaScript \"\(js)\" in tab \(t) of window \(w)"
        }
        guard source.isChromium else { return "" }
        return "tell application \"\(source.rawValue)\" to execute tab \(t) of window \(w) javascript \"\(js)\""
    }

    /// Walk every tab of every window, run `js`, and return the first non-empty
    /// result prefixed with its `window` and `tab` indices (each on its own line) —
    /// so playback in a background tab is found even when another tab is frontmost.
    private nonisolated static func scanScript(_ source: MediaSource, _ js: String) -> String {
        let runInTab = source == .safari
            ? "do JavaScript \"\(js)\" in t"
            : "execute t javascript \"\(js)\""
        return """
        tell application "\(source.rawValue)"
            set wi to 0
            repeat with w in windows
                set wi to wi + 1
                set ti to 0
                repeat with t in tabs of w
                    set ti to ti + 1
                    try
                        set r to \(runInTab)
                        if r is not missing value and r is not "" then
                            return (wi as text) & linefeed & (ti as text) & linefeed & r
                        end if
                    end try
                end repeat
            end repeat
            return ""
        end tell
        """
    }

    /// Control JS (play/pause, next, scrub) targets the remembered media tab so it
    /// works while a different tab is frontmost; falls back to a plain scan if we
    /// haven't located the media tab yet.
    private func runBrowserJS(_ source: MediaSource, _ js: String) {
        if let loc = browserTab {
            _ = Self.runScript(Self.tabScript(source, js, window: loc.window, tab: loc.tab))
        } else {
            _ = Self.runScript(Self.scanScript(source, js))
        }
    }

    private nonisolated static func readBrowserState(_ source: MediaSource,
                                                     browserTab: inout (window: Int, tab: Int)?) -> TrackInfo? {
        // Fast path: re-read the tab we already found media in (one JS call).
        if let loc = browserTab,
           let payload = runScript(tabScript(source, jsReadState, window: loc.window, tab: loc.tab))?.stringValue,
           let info = parseBrowserPayload(payload) {
            return info
        }

        // Otherwise scan every tab/window and remember where the media lives.
        guard let raw = runScript(scanScript(source, jsReadState))?.stringValue else {
            browserTab = nil
            return nil
        }
        let lines = raw.components(separatedBy: "\n")
        guard lines.count >= 3, let w = Int(lines[0]), let t = Int(lines[1]),
              let info = parseBrowserPayload(lines[2...].joined(separator: "\n")) else {
            browserTab = nil
            return nil
        }
        browserTab = (w, t)
        return info
    }

    private nonisolated static func parseBrowserPayload(_ result: String) -> TrackInfo? {
        let parts = result.components(separatedBy: "|||")
        guard parts.count >= 6, !parts[0].isEmpty else { return nil }
        let chapters = parts.count >= 8 ? Self.parseChapters(parts[7]) : []
        let videoID = (parts.count >= 10 && !parts[9].isEmpty) ? parts[9] : nil
        return TrackInfo(
            title: parts[0],
            artist: parts[1],
            album: parts[2],
            duration: Double(parts[3]) ?? 0,
            position: Double(parts[4]) ?? 0,
            playing: parts[5] == "playing",
            artworkURL: parts.count >= 7 ? parts[6] : nil,
            chapters: chapters,
            volume: parts.count >= 9 ? Double(parts[8]) : nil,
            videoID: videoID
        )
    }

    /// Fetch the complete chapter list for a YouTube video via the Innertube API and
    /// cache it. Runs off the main thread (the request is synchronous and can take a
    /// few hundred ms) and applies the result back on the main actor only if we're
    /// still on that video. One shot per video id — the `chapterFetchInFlightID` guard
    /// in `apply` keeps the per-second poll from re-firing it.
    private func startChapterFetch(source: MediaSource, videoID: String) {
        guard let loc = browserTab else { return }
        chapterFetchInFlightID = videoID
        let script = Self.tabScript(source, Self.jsFetchChapters, window: loc.window, tab: loc.tab)
        Task.detached(priority: .utility) { [weak self] in
            let raw = Self.runScript(script)?.stringValue ?? ""
            let chapters = Self.parseChapters(raw)
            guard !chapters.isEmpty else { return }
            await self?.applyFetchedChapters(chapters, for: videoID)
        }
    }

    /// Cache the Innertube chapter result and, if the panel is still on that video,
    /// show it. Split out so the background fetch has a clean main-actor hop.
    private func applyFetchedChapters(_ chapters: [MediaChapter], for videoID: String) {
        chapterVideoID = videoID
        fetchedChapters = chapters
        if currentVideoID == videoID, self.chapters != chapters {
            self.chapters = chapters
        }
    }

    private func apply(_ info: TrackInfo, from source: MediaSource) {
        self.source = source
        hasTrack = true
        title = info.title.isEmpty ? "Unknown Track" : info.title
        artist = info.artist
        album = info.album
        duration = info.duration
        isPlaying = info.playing
        polledPosition = info.position
        lastPollDate = Date()
        if !isScrubbing { position = info.position }
        currentVideoID = info.videoID

        // A browser tab on YouTube is identified by its video id (so hover-preview
        // metadata and same-video transport never re-fire the island); anything else
        // by its track fields.
        islandKey = (source.isBrowser && info.videoID != nil)
            ? "yt:\(info.videoID!)"
            : "\(info.title)|\(info.artist)|\(info.album)"

        // Chapters: prefer the complete Innertube-fetched set for this exact video;
        // until that lands (or for non-YouTube video) use the DOM-scraped ones.
        let effectiveChapters = (info.videoID != nil && info.videoID == chapterVideoID)
            ? fetchedChapters : info.chapters
        if chapters != effectiveChapters { chapters = effectiveChapters }

        // Kick off a one-time complete fetch when a new YouTube video appears.
        if let vid = info.videoID, vid != chapterVideoID, vid != chapterFetchInFlightID {
            startChapterFetch(source: source, videoID: vid)
        }

        supportsVolume = info.volume != nil
        if let v = info.volume, !isAdjustingVolume { volume = v }

        let key = "\(source.rawValue)|\(info.title)|\(info.artist)"
        if key != artworkKey {
            artworkKey = key
            loadArtwork(for: info, from: source)
        }
    }

    private func clear() {
        source = nil
        hasTrack = false
        isPlaying = false
        title = "Nothing Playing"
        artist = ""
        album = ""
        duration = 0
        position = 0
        polledPosition = 0
        artwork = nil
        artworkKey = ""
        chapters = []
        currentVideoID = nil
        islandKey = ""
        supportsVolume = false
    }

    // MARK: - Artwork

    private func loadArtwork(for info: TrackInfo, from source: MediaSource) {
        // Spotify and browsers expose an HTTP artwork URL we can download.
        if let urlString = info.artworkURL,
           urlString.hasPrefix("http"),
           let url = URL(string: urlString) {
            artwork = nil
            Task { [weak self] in
                if let (data, _) = try? await URLSession.shared.data(from: url),
                   let image = NSImage(data: data) {
                    await MainActor.run { self?.artwork = image }
                }
            }
            return
        }

        guard source == .music else { artwork = nil; return }

        // Apple Music: pull raw artwork bytes. The AppleScript fetch and the image
        // decode both run off the main thread (they can take a beat) and are applied
        // back on the main actor only if we're still on the same track — so a track
        // change never stalls the panel at the moment its info updates.
        artwork = nil
        let script = #"""
        tell application "Music"
            try
                set d to data of artwork 1 of current track
                return d
            end try
        end tell
        """#
        let key = artworkKey
        Task.detached(priority: .utility) { [weak self] in
            guard let descriptor = Self.runScript(script),
                  let data = descriptor.data as Data?,
                  !data.isEmpty,
                  let image = NSImage(data: data) else { return }
            await MainActor.run {
                guard let self, self.artworkKey == key else { return }
                self.artwork = image
            }
        }
    }

    // MARK: - Automation permission

    /// Proactively ask macOS for permission to control each installed native player
    /// (Music, Spotify). Because this is a background agent app (`LSUIElement`), the
    /// automation consent prompt is never triggered organically the way it is for a
    /// foreground app — so without this, sending an Apple Event to Music just fails
    /// silently and Music never shows up as a source. `AEDeterminePermissionToAutomateTarget`
    /// surfaces the standard "NotchGlass wants to control Music" prompt once, then is a
    /// no-op on later launches.
    private func requestAutomationForNativeSources() {
        // Only prompt for native players the user has actually enabled — never for
        // apps they've turned off in Settings. (Read the enabled set here on the
        // main actor, then hand just the bundle IDs to the background queue.)
        let enabled = SettingsStore.shared.enabledSources
        let installed = MediaSource.allCases.filter { source in
            !source.isBrowser && enabled.contains(source) &&
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundleID) != nil
        }
        DispatchQueue.global(qos: .utility).async {
            for source in installed { _ = Self.requestAutomation(for: source.bundleID) }
        }
    }

    /// Trigger (and report) the automation-permission check for one target app.
    @discardableResult
    private nonisolated static func requestAutomation(for bundleID: String) -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let desc = target.aeDesc else { return false }
        // Wildcard event class/id: we only care whether we're allowed to talk to the app.
        let status = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, true)
        if status != noErr {
            NSLog("NowPlayingManager: automation for \(bundleID) not granted (status \(status))")
        }
        return status == noErr
    }

    // MARK: - AppleScript

    nonisolated static func runScript(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if let error {
            NSLog("NowPlayingManager: AppleScript error \(error[NSAppleScript.errorNumber] ?? "?"): \(error[NSAppleScript.errorMessage] ?? "?")")
            return nil
        }
        return result
    }
}
