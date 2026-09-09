import Foundation

/// A minimal Twitch chat client over IRC-on-WebSocket (`wss://irc-ws.chat.twitch.tv`).
///
/// Connects, authenticates with the user's OAuth token, joins their channel, and streams
/// incoming messages via `onMessage`. Replies to server PINGs to stay alive and can send
/// messages back (`chat:edit` scope). Callbacks fire on a background queue — the store
/// hops to the main actor.
final class TwitchChat {
    struct ChatMessage: Identifiable, Equatable {
        let id = UUID()
        let user: String
        let colorHex: String?   // Twitch-provided name colour, e.g. "#1E90FF"
        let text: String
        var bits: Int = 0       // cheer amount when the line carries bits, else 0
        let date = Date()
    }

    private let login: String       // the user's lowercased login = channel to join
    private let token: String       // OAuth access token (no "oauth:" prefix)
    private var task: URLSessionWebSocketTask?
    /// Set on `disconnect` so the receive loop stops re-arming. A plain flag (not niling
    /// `task`, which the background receive/send read) avoids a cross-thread race on the
    /// task reference.
    private var closed = false
    /// Whether we've told the store we're connected yet — flipped true on the *first*
    /// frame the server actually delivers (not optimistically at `connect`), so a socket
    /// that never opens is never reported as a live chat.
    private var announcedConnected = false
    private let session = URLSession(configuration: .default)

    var onMessage: ((ChatMessage) -> Void)?
    var onConnected: ((Bool) -> Void)?
    /// A channel event (sub, resub, gift, raid…) delivered as an IRC `USERNOTICE`, passed
    /// as its human-readable line (Twitch's `system-msg`, e.g. "Nick subscribed at Tier 1").
    var onSystemEvent: ((String) -> Void)?

    init(login: String, token: String) {
        self.login = login.lowercased()
        self.token = token
    }

    func connect() {
        let task = session.webSocketTask(with: URL(string: "wss://irc-ws.chat.twitch.tv:443")!)
        self.task = task
        task.resume()
        // Request tags (name colour + display name) and commands, then log in and join.
        sendRaw("CAP REQ :twitch.tv/tags twitch.tv/commands")
        sendRaw("PASS oauth:\(token)")
        sendRaw("NICK \(login)")
        sendRaw("JOIN #\(login)")
        // `onConnected?(true)` is deferred to the first received frame (see `receive`) so
        // a socket that never opens isn't reported as connected.
        receive()
    }

    func disconnect() {
        closed = true
        task?.cancel(with: .goingAway, reason: nil)
        onConnected?(false)
    }

    /// Send a chat message to the joined channel.
    func send(_ text: String) {
        let clean = text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        sendRaw("PRIVMSG #\(login) :\(clean)")
    }

    // MARK: - Transport

    private func sendRaw(_ line: String) {
        task?.send(.string(line + "\r\n")) { _ in }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self, !self.closed else { return }
            switch result {
            case .failure:
                // Report the drop; the store schedules a reconnect. Don't re-arm.
                self.onConnected?(false)
            case .success(let message):
                // The socket is genuinely up once the server sends its first frame.
                if !self.announcedConnected {
                    self.announcedConnected = true
                    self.onConnected?(true)
                }
                switch message {
                case .string(let text): self.handle(text)
                case .data(let data): self.handle(String(decoding: data, as: UTF8.self))
                @unknown default: break
                }
                self.receive()   // re-arm for the next frame
            }
        }
    }

    /// A frame can carry several `\r\n`-separated IRC lines.
    private func handle(_ frame: String) {
        for raw in frame.split(whereSeparator: { $0 == "\r" || $0 == "\n" }) {
            parse(String(raw))
        }
    }

    private func parse(_ line: String) {
        var rest = Substring(line)
        var tags: [String: String] = [:]

        // Optional IRCv3 tag block: "@key=val;key2=val2 …"
        if rest.first == "@", let sp = rest.firstIndex(of: " ") {
            for pair in rest[rest.index(after: rest.startIndex)..<sp].split(separator: ";") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                tags[String(kv[0])] = kv.count > 1 ? String(kv[1]) : ""
            }
            rest = rest[rest.index(after: sp)...]
        }

        // Keepalive.
        if rest.hasPrefix("PING") { sendRaw("PONG :tmi.twitch.tv"); return }

        // ":nick!user@host COMMAND params :trailing"
        guard rest.first == ":", let sp = rest.firstIndex(of: " ") else { return }
        let prefix = rest[rest.index(after: rest.startIndex)..<sp]
        rest = rest[rest.index(after: sp)...]

        if rest.hasPrefix("USERNOTICE") {
            let sys = tags["system-msg"].flatMap { $0.isEmpty ? nil : unescapeTag($0) }
            if let sys { onSystemEvent?(sys) }
            return
        }

        guard rest.hasPrefix("PRIVMSG "), let sep = rest.range(of: " :") else { return }

        let text = String(rest[sep.upperBound...])
        let nick = prefix.split(separator: "!").first.map(String.init) ?? "?"
        let display = tags["display-name"].flatMap { $0.isEmpty ? nil : $0 } ?? nick
        let color = tags["color"].flatMap { $0.isEmpty ? nil : $0 }
        let bits = Int(tags["bits"] ?? "") ?? 0
        onMessage?(ChatMessage(user: display, colorHex: color, text: text, bits: bits))
    }

    /// Unescape an IRCv3 tag value (`system-msg` arrives with spaces as `\s`, etc.).
    private func unescapeTag(_ s: String) -> String {
        s.replacingOccurrences(of: "\\s", with: " ")
            .replacingOccurrences(of: "\\:", with: ";")
            .replacingOccurrences(of: "\\r", with: "")
            .replacingOccurrences(of: "\\n", with: "")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
