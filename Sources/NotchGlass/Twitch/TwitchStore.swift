import Foundation
import AppKit

/// Drives the Twitch tab: OAuth device-code sign-in, loading + editing the stream's
/// title/category via Helix, and a live chat feed. Tokens persist so a reconnect after
/// relaunch is silent (refreshed as needed). All state the view binds to is here.
@MainActor
final class TwitchStore: ObservableObject {
    enum Phase: Equatable {
        case notConfigured   // no Client ID compiled in
        case signedOut
        case awaitingAuth    // showing the user code, polling for authorization
        case connecting      // exchanging code / loading the channel
        case ready           // channel loaded, chat live
    }

    @Published var phase: Phase = .signedOut
    @Published var userCode = ""
    @Published var verificationURL = "https://www.twitch.tv/activate"
    @Published var displayName = ""
    @Published var title = ""
    @Published var category = ""      // the game/category *name*
    @Published var chat: [TwitchChat.ChatMessage] = []
    @Published var chatConnected = false
    @Published var savingEdit = false
    @Published var errorText: String?

    private var broadcasterID = ""
    private var login = ""
    private var gameID = ""
    private var accessToken = ""
    private var refreshToken = ""
    private var expiry = Date.distantPast

    private var chatClient: TwitchChat?
    private var pollTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    /// Consecutive chat-reconnect attempts, for capped backoff so a persistently failing
    /// socket (bad scope, dead channel) can't hammer the network every few seconds —
    /// especially in background peek mode. Reset once a live line proves the socket works.
    private var reconnectAttempts = 0

    /// Whether the tab is currently on-screen. Together with `backgroundChat` this
    /// decides if the chat socket should be live: connected when either is true.
    private var tabVisible = false
    /// Keep chat connected even when the tab is hidden (drives the closed-notch chat
    /// peek). Set from the setting via `setBackgroundChat`.
    private var backgroundChat = false

    /// Fired for each chat *highlight* — a line that @-mentions you, a cheer, or a channel
    /// event (sub/raid/gift) — as a ready-made collapsed notice, not for ordinary chatter.
    /// The notch's Twitch appearance lives here, next to the store, mirroring
    /// `FuelEventMonitor.onEvent`. AppDelegate just throttles and flashes it.
    var onChatEvent: ((NotchViewModel.CollapsedEvent) -> Void)?

    private let defaults = UserDefaults.standard

    init() {
        accessToken = defaults.string(forKey: "twitch.access") ?? ""
        refreshToken = defaults.string(forKey: "twitch.refresh") ?? ""
        expiry = (defaults.object(forKey: "twitch.expiry") as? Date) ?? .distantPast
    }

    // MARK: - Lifecycle (tab appear / disappear)

    func start() {
        tabVisible = true
        ensureConnection()
    }

    func stop() {
        // Tab hidden. Keep the chat socket alive only if the background peek wants it;
        // otherwise drop it (channel info stays cached and reconnects on the next appear).
        tabVisible = false
        if !backgroundChat { teardownChat() }
    }

    /// Turn the closed-notch chat peek on/off. When on and signed in, the chat socket
    /// stays connected even with the tab hidden; when off, it's dropped once the tab is
    /// no longer visible.
    func setBackgroundChat(_ on: Bool) {
        backgroundChat = on
        if on { ensureConnection() }
        else if !tabVisible { teardownChat() }
    }

    /// Bring chat online if someone (the tab or the background peek) wants it and we're
    /// signed in. No-ops while awaiting auth, or if chat is already live.
    private func ensureConnection() {
        guard TwitchAPI.isConfigured else { phase = .notConfigured; return }
        guard tabVisible || backgroundChat else { return }
        guard !refreshToken.isEmpty else {
            if phase != .awaitingAuth { phase = .signedOut }
            return
        }
        switch phase {
        case .awaitingAuth, .connecting:
            return   // sign-in or channel load already in flight — don't double up
        case .ready:
            // Channel's loaded; just bring chat back if it dropped, without re-fetching
            // the channel. connectChat cancels any pending backoff retry, so this is safe
            // even mid-reconnect. Fresh entry point → fresh reconnect budget.
            if chatClient == nil {
                reconnectAttempts = 0
                reconnectNow()
            }
        default:
            Task { await resume() }
        }
    }

    private func teardownChat() {
        reconnectTask?.cancel()
        chatClient?.disconnect()
        chatClient = nil
    }

    /// Fetch a fresh token and open the chat socket. `connectChat` cancels any pending
    /// backoff retry, so this is safe to call at any time.
    private func reconnectNow() {
        Task { if let token = try? await validToken() { connectChat(token: token) } }
    }

    // MARK: - Sign in (device code flow)

    func connect() {
        guard TwitchAPI.isConfigured else { return }
        errorText = nil
        pollTask?.cancel()
        pollTask = Task { await runDeviceFlow() }
    }

    func signOut() {
        pollTask?.cancel()
        teardownChat()
        accessToken = ""; refreshToken = ""; expiry = .distantPast
        for key in ["twitch.access", "twitch.refresh", "twitch.expiry"] { defaults.removeObject(forKey: key) }
        chat = []; chatConnected = false; title = ""; category = ""; displayName = ""
        phase = .signedOut
    }

    func openVerification() {
        if let url = URL(string: verificationURL) { NSWorkspace.shared.open(url) }
    }

    private func runDeviceFlow() async {
        do {
            let dc = try await TwitchAPI.requestDeviceCode()
            userCode = dc.user_code
            verificationURL = dc.verification_uri
            phase = .awaitingAuth
            if let url = URL(string: dc.verification_uri) { NSWorkspace.shared.open(url) }

            let deadline = Date().addingTimeInterval(Double(dc.expires_in))
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: UInt64(max(1, dc.interval)) * 1_000_000_000)
                if Task.isCancelled { return }
                do {
                    store(try await TwitchAPI.pollForTokens(deviceCode: dc.device_code))
                    await resume()
                    return
                } catch TwitchAPI.TwitchError.authorizationPending {
                    continue   // keep waiting
                }
            }
            errorText = "Authorization timed out — try Connect again."
            phase = .signedOut
        } catch {
            errorText = error.localizedDescription
            phase = .signedOut
        }
    }

    // MARK: - Load channel + chat

    private func resume() async {
        phase = .connecting
        reconnectAttempts = 0
        do {
            let token = try await validToken()
            let user = try await TwitchAPI.currentUser(token: token)
            broadcasterID = user.id; login = user.login; displayName = user.display_name
            let ch = try await TwitchAPI.channel(broadcasterID: broadcasterID, token: token)
            title = ch.title; category = ch.game_name; gameID = ch.game_id
            phase = .ready
            connectChat(token: token)
        } catch {
            // Couldn't load the channel (dead token, network). Return to sign-in with the
            // reason rather than a half-loaded, non-functional .ready. Tokens are kept, so
            // reopening the tab retries automatically for a transient failure.
            errorText = error.localizedDescription
            phase = .signedOut
        }
    }

    private func connectChat(token: String) {
        reconnectTask?.cancel()
        chatClient?.disconnect()
        chat = []
        let client = TwitchChat(login: login, token: token)
        client.onMessage = { [weak self] msg in
            Task { @MainActor in
                guard let self else { return }
                self.chat.append(msg)
                if self.chat.count > 200 { self.chat.removeFirst(self.chat.count - 200) }
                self.reconnectAttempts = 0   // a real line proves the socket is healthy
                // Only *highlights* peek on the closed notch, not every line: a line that
                // @-mentions you, or a cheer.
                if let event = self.highlightEvent(for: msg) { self.onChatEvent?(event) }
            }
        }
        client.onSystemEvent = { [weak self] sys in
            Task { @MainActor in
                guard let self else { return }
                self.reconnectAttempts = 0
                // Subs, resubs, gifts, raids — always a highlight.
                self.onChatEvent?(.init(symbol: "star.fill", text: sys, tintHex: "9146FF"))
            }
        }
        client.onConnected = { [weak self] connected in
            Task { @MainActor in
                guard let self else { return }
                self.chatConnected = connected
                // An unexpected drop (not our own disconnect) while the tab's still up:
                // reconnect after a short delay so chat comes back on its own.
                if !connected, self.phase == .ready, self.chatClient === client {
                    self.scheduleChatReconnect()
                }
            }
        }
        chatClient = client
        client.connect()
    }

    /// A closed-notch notice for a chat line worth surfacing — a cheer, or a line that
    /// @-mentions you — or nil for ordinary chatter (which stays in the tab only).
    private func highlightEvent(for msg: TwitchChat.ChatMessage) -> NotchViewModel.CollapsedEvent? {
        if msg.bits > 0 {
            return .init(symbol: "sparkles", text: "\(msg.user) cheered \(msg.bits): \(msg.text)", tintHex: "9146FF")
        }
        if mentionsMe(msg.text) {
            return .init(symbol: "at", text: "\(msg.user): \(msg.text)", tintHex: "9146FF")
        }
        return nil
    }

    /// True when the line names the broadcaster (by display name or login, case-insensitive).
    /// Matches whole words only — split on non-name characters and compare tokens (a
    /// leading "@" stripped) — so an incidental substring like "category" containing the
    /// login "cat" isn't treated as an @-mention.
    private func mentionsMe(_ text: String) -> Bool {
        let names = Set([displayName, login].filter { !$0.isEmpty }.map { $0.lowercased() })
        guard !names.isEmpty else { return false }
        let isName: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "_" }
        let tokens = text.lowercased().split(whereSeparator: { !isName($0) })
        return tokens.contains { names.contains(String($0)) }
    }

    private func scheduleChatReconnect() {
        // Give up after a run of failures so a permanently-broken socket (missing scope,
        // dead channel) doesn't retry forever in the background. The tab re-appearing, or
        // toggling the peek, calls ensureConnection() and starts a fresh run.
        guard reconnectAttempts < 6 else { chatClient = nil; reconnectTask = nil; return }
        reconnectAttempts += 1
        // Capped backoff: 3s, 6s, 12s … up to 60s.
        let delay = min(3.0 * pow(2, Double(reconnectAttempts - 1)), 60)
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, phase == .ready, chatClient != nil else { return }
            reconnectNow()
        }
    }

    // MARK: - Edit stream + chat

    /// Push a new title and/or category. Category is set by name (resolved to a game id).
    func saveEdit(newTitle: String, newCategory: String) {
        Task {
            savingEdit = true; errorText = nil
            defer { savingEdit = false }
            do {
                let token = try await validToken()
                var newGameID: String?
                let cat = newCategory.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cat.isEmpty, cat.lowercased() != category.lowercased() {
                    guard let game = try await TwitchAPI.searchGame(name: cat, token: token) else {
                        errorText = "No Twitch category named “\(cat)”."; return
                    }
                    newGameID = game.id
                }
                let t = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                try await TwitchAPI.updateChannel(broadcasterID: broadcasterID, token: token,
                                                  title: t == title ? nil : t,
                                                  gameID: newGameID)
                let ch = try await TwitchAPI.channel(broadcasterID: broadcasterID, token: token)
                title = ch.title; category = ch.game_name; gameID = ch.game_id
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    func sendChat(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let client = chatClient else { return }
        client.send(clean)
        // Echo our own line immediately (Twitch IRC doesn't send our own messages back).
        chat.append(.init(user: displayName.isEmpty ? login : displayName, colorHex: nil, text: clean))
    }

    // MARK: - Tokens

    private func validToken() async throws -> String {
        if Date() >= expiry.addingTimeInterval(-60), !refreshToken.isEmpty {
            store(try await TwitchAPI.refresh(refreshToken: refreshToken))
        }
        guard !accessToken.isEmpty else { throw TwitchAPI.TwitchError.notConfigured }
        return accessToken
    }

    private func store(_ tokens: TwitchAPI.Tokens) {
        accessToken = tokens.access_token
        refreshToken = tokens.refresh_token
        expiry = Date().addingTimeInterval(Double(tokens.expires_in))
        defaults.set(accessToken, forKey: "twitch.access")
        defaults.set(refreshToken, forKey: "twitch.refresh")
        defaults.set(expiry, forKey: "twitch.expiry")
    }
}
