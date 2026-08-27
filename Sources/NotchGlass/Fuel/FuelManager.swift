import SwiftUI
import Combine

/// A snapshot of Claude usage shown by the Fuel tab. `sessionUsed` / `weekUsed`
/// are the authoritative server utilizations (0…1 used); the token counts come
/// from the local CLI transcripts.
struct FuelState {
    enum Status { case unknown, live, noToken, unauthorized, rateLimited, offline, serverError }

    var status: Status = .unknown
    var provider: AIProvider = .claude

    var sessionUsed: Double = 0            // 0…1 of the 5-hour window used
    var sessionResetsAt: Date?
    var weekUsed: Double?                  // 0…1 of the weekly window used
    var weekResetsAt: Date?

    var blockTokens: Int = 0               // tokens in the current active block
    var todayTokens: Int = 0
    var topModel: String?                  // short name of the most-used model this block
    var sessionsToday: Int = 0             // distinct 5-hour blocks drawn from today

    // Extra-usage ("credits") spend, once a token window runs dry. All amounts in
    // major currency units (e.g. 25.66). `creditsEverEnabled == false` → this account
    // never turned credits on, so the block shows an "off" placeholder.
    var creditsUsed: Double = 0
    var creditsLimit: Double = 0           // 0 = no cap set
    var creditsSymbol: String = "$"
    var creditsCritical: Bool = false      // at/over the cap
    var creditsEverEnabled: Bool = false

    var lastUpdated: Date?                  // when the live gauge last succeeded
    var retryAt: Date?                      // during rate-limit backoff, when we'll try again

    var connected: Bool { status == .live }

    /// True once we've had at least one successful live reading — so a transient
    /// rate-limit can keep showing that (stale) reading instead of blanking out.
    var hasReading: Bool { sessionResetsAt != nil }

    /// Short status label for the header ("Connected", "Not signed in", …).
    var statusLabel: String {
        switch status {
        case .unknown:      return "Connecting…"
        case .live:         return "Connected"
        case .noToken:      return "Not signed in"
        case .unauthorized: return "Sign in again"
        case .rateLimited:  return "Rate limited"
        case .offline:      return "Offline"
        case .serverError:  return "Server error"
        }
    }

    /// A one-line hint for the non-connected states.
    var hint: String? {
        let name = provider.title
        switch status {
        case .noToken, .unauthorized:
            switch provider {
            case .claude:  return "Sign in to Claude Code (run /login) to see your live fuel."
            case .chatgpt: return "Sign in to Codex (run codex login) to see your live fuel."
            }
        case .offline:      return "Couldn’t reach \(name) — check your connection."
        case .rateLimited:  return "\(name) is throttling requests — try again shortly."
        case .serverError:  return "\(name)’s usage endpoint returned an error."
        case .live, .unknown: return nil
        }
    }
}

/// Owns the Fuel tab's live state: fetches server utilization + local token totals
/// on a timer, but only while the tab is actually on screen (`activate` /
/// `deactivate`) so it never touches the keychain or network in the background.
@MainActor
final class FuelManager: ObservableObject {
    @Published private(set) var state = FuelState()
    @Published private(set) var isRefreshing = false

    /// Which AI's fuel we're currently showing. Switched from the Fuel tab header.
    private(set) var provider: AIProvider = SettingsStore.shared.fuelProvider

    private let projectsPath = ("~/.claude/projects" as NSString).expandingTildeInPath
    private let windowHours = 5.0
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    /// Base poll cadence, chosen by the user in Settings (Live 5s / Normal 30s /
    /// Relaxed 60s). Utilization only shifts as you spend tokens, so the Normal
    /// default is plenty and keeps us well clear of the endpoint's rate limit.
    private var pollInterval: TimeInterval { SettingsStore.shared.fuelRefreshRate.interval }

    /// Rate-limit backoff. While `cooldownUntil` is in the future we skip the live
    /// fetch entirely (keeping the last good reading on screen). Each consecutive 429
    /// stretches the wait — but gently (linear in the poll interval, tightly capped)
    /// so a transient throttle clears in seconds rather than stranding the gauge for
    /// minutes. The server's own `Retry-After` hint always wins when present.
    private var cooldownUntil: Date?
    private var consecutiveRateLimits = 0
    private let maxBackoff: TimeInterval = 120

    init() {
        // Re-time the poll the moment the user changes the cadence in Settings, so a
        // switch to "Live" takes effect without waiting for the tab to be reopened.
        SettingsStore.shared.$fuelRefreshRate
            .dropFirst()
            .sink { [weak self] _ in self?.rescheduleTimer() }
            .store(in: &cancellables)
    }

    /// If the poll is currently running, tear it down and restart it at the current
    /// cadence. No-op when the tab is off screen (the timer is nil).
    private func rescheduleTimer() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Switch the tab to a different AI. Resets the readout and re-fetches from that
    /// provider's data source.
    func select(_ provider: AIProvider) {
        guard provider != self.provider else { return }
        self.provider = provider
        state = FuelState(provider: provider)   // clear stale numbers while we refetch
        refresh()
    }

    /// Starts / stops the poll (at the user's chosen cadence). Driven by the Fuel tab:
    /// active only while its view is on screen *and* the panel is open, so we never
    /// touch the keychain or the network in the background.
    func setActive(_ active: Bool) {
        if active {
            guard timer == nil else { return }
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Refresh the readout. `force` (the header's refresh button) ignores the
    /// rate-limit cooldown and tries the live fetch immediately.
    func refresh(force: Bool = false) {
        guard !isRefreshing else { return }
        if force { cooldownUntil = nil; consecutiveRateLimits = 0 }
        isRefreshing = true
        switch provider {
        case .claude:  refreshClaude()
        case .chatgpt: refreshChatGPT()
        }
    }

    // MARK: - Claude (OAuth usage endpoint + local transcripts)

    private func refreshClaude() {
        let path = projectsPath
        let hours = windowHours
        // While backing off from a 429, don't touch the network — keep showing the
        // last good reading. Local token counts (Stage 2) still refresh below.
        let skipLive = (cooldownUntil.map { $0 > Date() }) ?? false
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // Stage 1 — authoritative live utilization from the OAuth usage endpoint.
            // Fast (~1s) and the real fuel gauge, so it lands first.
            let fetch: LiveFetchResult? = skipLive ? nil : LiveUsageClient.fetchDetailed()
            DispatchQueue.main.async {
                guard let self, self.provider == .claude else { return }
                var s = self.state
                // `fetch == nil` means the live call was skipped during cooldown —
                // keep the current status/data untouched.
                if let fetch {
                    switch fetch {
                    case .ok(let u):
                        self.consecutiveRateLimits = 0
                        self.cooldownUntil = nil
                        s.status = .live
                        s.retryAt = nil
                        if let sess = u.session {
                            s.sessionUsed = min(1, max(0, sess.utilization / 100))
                            s.sessionResetsAt = sess.resetsAt
                        }
                        if let w = u.week {
                            s.weekUsed = min(1, max(0, w.utilization / 100))
                            s.weekResetsAt = w.resetsAt
                        } else {
                            s.weekUsed = nil
                        }
                        // Extra-usage credits: the server's running spend once a token
                        // window is exhausted. Only shown if this account ever enabled them.
                        if let c = u.credits, c.everEnabled {
                            s.creditsEverEnabled = true
                            s.creditsUsed = c.used
                            s.creditsLimit = c.limit
                            s.creditsSymbol = Self.currencySymbol(c.currency)
                            s.creditsCritical = c.critical
                        } else {
                            s.creditsEverEnabled = false
                        }
                        s.lastUpdated = Date()
                    case .rateLimited(let retryAfter):
                        // Back off and preserve the last reading — sessionUsed / resets
                        // stay put so the gauge doesn't blank. Honour the server's
                        // Retry-After when it sends one; otherwise grow the wait linearly
                        // in the poll interval (30s, 60s, 90s… at Normal) and cap it low,
                        // so a passing throttle clears quickly instead of ballooning.
                        self.consecutiveRateLimits += 1
                        let grown = min(self.maxBackoff, self.pollInterval * Double(self.consecutiveRateLimits))
                        let backoff = retryAfter.map { min($0, self.maxBackoff) } ?? grown
                        let until = Date().addingTimeInterval(backoff)
                        self.cooldownUntil = until
                        s.status = .rateLimited
                        s.retryAt = until
                    case .noToken:      s.status = .noToken;     s.retryAt = nil
                    case .unauthorized: s.status = .unauthorized; s.retryAt = nil
                    case .offline:      s.status = .offline;      s.retryAt = nil
                    case .http, .badData: s.status = .serverError; s.retryAt = nil
                    }
                    self.state = s
                }
            }

            // Stage 2 — local token counts for the current block and today. Only the
            // last day's transcripts are scanned (the projects folder can be many GB).
            let since = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-hours * 3600)
            let entries = UsageReader.load(projectsPath: path, includeCacheReads: false, since: since)
            let block = UsageReader.currentBlock(entries: entries, windowHours: hours)
            let sessionsToday = UsageReader.sessionsToday(entries: entries, windowHours: hours)
            let cal = Calendar.current
            let today = entries.filter { cal.isDateInToday($0.date) }.reduce(0) { $0 + $1.tokens }
            DispatchQueue.main.async {
                guard let self else { return }
                if self.provider == .claude {
                    var s = self.state
                    s.todayTokens = today
                    s.sessionsToday = sessionsToday
                    if let b = block, b.isActive {
                        s.blockTokens = b.used
                        s.topModel = b.perModel.max { $0.value < $1.value }.map { Self.shortModel($0.key) }
                    } else {
                        s.blockTokens = 0
                        s.topModel = nil
                    }
                    self.state = s
                }
                self.isRefreshing = false
                // The user switched providers mid-fetch — service the new one now.
                if self.provider != .claude { self.refresh() }
            }
        }
    }

    // MARK: - ChatGPT (local Codex/ChatGPT login + session transcripts)

    private func refreshChatGPT() {
        let hours = windowHours
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let since = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-hours * 3600)
            let snap = CodexUsageReader.load(windowHours: hours, since: since)
            DispatchQueue.main.async {
                guard let self else { return }
                if self.provider == .chatgpt {
                    var s = FuelState(provider: .chatgpt)
                    switch snap.status {
                    case .noAuth: s.status = .noToken
                    case .noData, .live: s.status = .live
                    }
                    s.sessionUsed = snap.sessionUsed ?? 0
                    s.sessionResetsAt = snap.sessionResetsAt
                    s.weekUsed = snap.weekUsed
                    s.weekResetsAt = snap.weekResetsAt
                    s.blockTokens = snap.blockTokens
                    s.todayTokens = snap.todayTokens
                    s.topModel = snap.topModel
                    s.lastUpdated = Date()
                    self.state = s
                }
                self.isRefreshing = false
                if self.provider != .chatgpt { self.refresh() }
            }
        }
    }

    /// A short symbol for the credits readout, falling back to the ISO code.
    static func currencySymbol(_ code: String) -> String {
        switch code.uppercased() {
        case "EUR": return "€"
        case "USD", "CAD", "AUD", "NZD": return "$"
        case "GBP": return "£"
        case "JPY", "CNY": return "¥"
        default:    return code.uppercased()
        }
    }

    private static func shortModel(_ m: String) -> String {
        let x = m.replacingOccurrences(of: "claude-", with: "").uppercased()
        if x.contains("OPUS") { return "Opus" }
        if x.contains("SONNET") { return "Sonnet" }
        if x.contains("HAIKU") { return "Haiku" }
        if x.contains("FABLE") { return "Fable" }
        return String(m.prefix(8))
    }
}
