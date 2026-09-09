import Foundation

/// Twitch OAuth (Device Code flow) + Helix REST calls used by the Twitch tab.
///
/// Auth is the **Device Code Grant**: the app asks Twitch for a short user code, the
/// user enters it at twitch.tv/activate, and the app polls until Twitch hands back an
/// access + refresh token. It needs only the (public) Client ID — no client secret —
/// so nothing sensitive ships in the app. Tokens refresh with the same Client ID.
enum TwitchAPI {
    /// The registered application's Client ID (dev.twitch.tv/console → Public app).
    /// Replace the placeholder with the real one to enable the tab.
    static let clientID = "kagdfdfpv1mpvja4a657c3ppn5gqt2"

    /// True once a real Client ID has been filled in.
    static var isConfigured: Bool { clientID != "REPLACE_WITH_TWITCH_CLIENT_ID" && !clientID.isEmpty }

    /// Everything the tab needs: edit the stream (title + category) and read/send chat.
    static let scopes = "channel:manage:broadcast chat:read chat:edit"

    enum TwitchError: LocalizedError {
        case notConfigured
        case authorizationPending
        case http(Int, String)
        case decode
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Twitch isn’t set up yet (missing Client ID)."
            case .authorizationPending: return "Waiting for you to authorize in the browser…"
            case .http(let code, let msg): return "Twitch error \(code): \(msg)"
            case .decode: return "Couldn’t read Twitch’s response."
            }
        }
    }

    // MARK: - Device Code flow

    struct DeviceCode: Decodable {
        let device_code: String
        let user_code: String
        let verification_uri: String
        let expires_in: Int
        let interval: Int
    }

    struct Tokens: Decodable {
        let access_token: String
        let refresh_token: String
        let expires_in: Int
    }

    /// Step 1: request a device + user code to show the user.
    static func requestDeviceCode() async throws -> DeviceCode {
        guard isConfigured else { throw TwitchError.notConfigured }
        var req = URLRequest(url: URL(string: "https://id.twitch.tv/oauth2/device")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form(["client_id": clientID, "scopes": scopes])
        return try await decode(req)
    }

    /// Step 2 (polled): exchange the device code for tokens once the user authorizes.
    /// Throws `.authorizationPending` while the user hasn't finished yet.
    static func pollForTokens(deviceCode: String) async throws -> Tokens {
        var req = URLRequest(url: URL(string: "https://id.twitch.tv/oauth2/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form([
            "client_id": clientID,
            "scopes": scopes,
            "device_code": deviceCode,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 200 {
            guard let tokens = try? JSONDecoder().decode(Tokens.self, from: data) else { throw TwitchError.decode }
            return tokens
        }
        // Twitch returns 400 "authorization_pending" until the user finishes.
        let body = String(data: data, encoding: .utf8) ?? ""
        if body.contains("authorization_pending") { throw TwitchError.authorizationPending }
        throw TwitchError.http(code, body)
    }

    /// Refresh an expired access token (public client — no secret needed).
    static func refresh(refreshToken: String) async throws -> Tokens {
        var req = URLRequest(url: URL(string: "https://id.twitch.tv/oauth2/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form([
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ])
        return try await decode(req)
    }

    // MARK: - Helix

    struct HelixUser: Decodable { let id: String; let login: String; let display_name: String }
    struct ChannelInfo: Decodable {
        let broadcaster_id: String
        let title: String
        let game_id: String
        let game_name: String
    }
    struct Game: Decodable { let id: String; let name: String; let box_art_url: String }

    /// The signed-in user (self) — for the broadcaster id + chat login.
    static func currentUser(token: String) async throws -> HelixUser {
        let list: HelixList<HelixUser> = try await helix("users", token: token)
        guard let user = list.data.first else { throw TwitchError.decode }
        return user
    }

    static func channel(broadcasterID: String, token: String) async throws -> ChannelInfo {
        let list: HelixList<ChannelInfo> = try await helix("channels?broadcaster_id=\(broadcasterID)", token: token)
        guard let info = list.data.first else { throw TwitchError.decode }
        return info
    }

    /// Update the live stream's title and/or category (`gameID`). Pass nil to leave one
    /// unchanged. `channel:manage:broadcast` scope required.
    static func updateChannel(broadcasterID: String, token: String,
                              title: String?, gameID: String?) async throws {
        var body: [String: String] = [:]
        if let title { body["title"] = title }
        if let gameID { body["game_id"] = gameID }
        guard !body.isEmpty else { return }
        var req = URLRequest(url: URL(string: "https://api.twitch.tv/helix/channels?broadcaster_id=\(broadcasterID)")!)
        req.httpMethod = "PATCH"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(clientID, forHTTPHeaderField: "Client-Id")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 204 else { throw TwitchError.http(code, String(data: data, encoding: .utf8) ?? "") }
    }

    /// Look up a category (game) by name for setting it. Uses the fuzzy
    /// `search/categories` endpoint (not exact `games?name=`), then prefers an exact
    /// case-insensitive match among the results so "just chatting" resolves correctly.
    static func searchGame(name: String, token: String) async throws -> Game? {
        let q = name.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? name
        let list: HelixList<Game> = try await helix("search/categories?query=\(q)&first=10", token: token)
        return list.data.first { $0.name.lowercased() == name.lowercased() } ?? list.data.first
    }

    // MARK: - Plumbing

    private struct HelixList<T: Decodable>: Decodable { let data: [T] }

    private static func helix<T: Decodable>(_ path: String, token: String) async throws -> T {
        var req = URLRequest(url: URL(string: "https://api.twitch.tv/helix/\(path)")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(clientID, forHTTPHeaderField: "Client-Id")
        return try await decode(req)
    }

    private static func decode<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw TwitchError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        guard let value = try? JSONDecoder().decode(T.self, from: data) else { throw TwitchError.decode }
        return value
    }

    private static func form(_ fields: [String: String]) -> Data {
        fields.map { key, value in
            let v = value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? value
            return "\(key)=\(v)"
        }.joined(separator: "&").data(using: .utf8) ?? Data()
    }
}

private extension CharacterSet {
    /// Form-body value encoding (stricter than `.urlQueryAllowed`, which leaves `&`/`+`).
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}
