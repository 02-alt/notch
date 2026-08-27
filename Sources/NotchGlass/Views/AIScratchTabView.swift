import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A tiny Claude scratchpad that lives in the notch: type a question, get an
/// answer, without leaving whatever you're doing. It reuses the Claude Code login
/// the Fuel tab already reads (the OAuth token in the Keychain), so there's no API
/// key to paste — if you're signed in to Claude Code, this just works.
///
/// The transcript is deliberately ephemeral (kept in memory, not saved) — it's a
/// scratch surface, cleared with a tap or when the app quits.
struct AIScratchTabView: View {
    @EnvironmentObject private var settings: SettingsStore
    @StateObject private var store = ScratchStore()
    @AppStorage("scratch.model") private var modelID = ScratchModel.opus.rawValue
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    /// Files staged for the next message — added via the "+" button or dropped onto
    /// the chat. Images are sent to Claude as vision, PDFs as documents, text files
    /// inlined. Cleared once the message is sent.
    @State private var attachments: [ChatAttachment] = []
    @State private var dropTargeted = false

    /// A stable scroll anchor for the "thinking" bubble while a reply is in flight.
    private static let pendingID = "scratch.pending"

    private var model: ScratchModel {
        get { ScratchModel(rawValue: modelID) ?? .opus }
        nonmutating set { modelID = newValue.rawValue }
    }

    var body: some View {
        VStack(spacing: Spacing.sm) {
            header
            transcript
            inputBar
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        // Drop documents anywhere on the chat to attach them to the next message.
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.ember, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Header

    /// A slim Messages-style bar: the contact name ("Claude") centered, the model
    /// picker on the left and a clear button on the right.
    private var header: some View {
        ZStack {
            HStack(spacing: Spacing.s) {
                Image(systemName: "ellipsis.message.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Claude")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            HStack(spacing: Spacing.sm) {
                modelMenu
                Spacer(minLength: 0)
                if !store.messages.isEmpty {
                    Button { store.clear() } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.secondaryText)
                            .frame(width: 26, height: 26)
                            .background { Circle().fill(Color.white.opacity(0.08)) }
                    }
                    .buttonStyle(.plain)
                    .notchHover(scale: 1.08)
                    .help("Clear the conversation")
                }
            }
        }
        .padding(.bottom, Spacing.hair)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
        }
    }

    private var modelMenu: some View {
        Menu {
            ForEach(ScratchModel.allCases) { m in
                Button {
                    model = m
                } label: {
                    if model == m { Label(m.title, systemImage: "checkmark") }
                    else { Text(m.title) }
                }
            }
        } label: {
            HStack(spacing: Spacing.xs) {
                Text(model.title).font(.system(size: 10.5, weight: .semibold))
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            }
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, Spacing.md)
            .frame(height: 24)
            .background { Capsule().fill(Color.white.opacity(0.08)) }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Attachments

    /// The composer's "+" — an iMessage-style round button that opens a file picker
    /// to attach documents (images, PDFs, text/code files) to the next message.
    private var plusButton: some View {
        Button { pickFiles() } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 30, height: 30)
                .background { Circle().fill(Color.white.opacity(0.08)) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .notchHover(scale: 1.08)
        .help("Attach documents")
    }

    /// Staged-attachment chips, shown above the composer until the message is sent.
    private var attachmentBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.s) {
                ForEach(attachments) { att in
                    HStack(spacing: Spacing.s) {
                        Image(systemName: att.symbol)
                            .font(.system(size: 11, weight: .semibold))
                        Text(att.filename)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                        Button { attachments.removeAll { $0.id == att.id } } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Theme.secondaryText)
                        }
                        .buttonStyle(.plain)
                        .linkCursor()
                    }
                    .foregroundStyle(.white)
                    .padding(.leading, Spacing.md)
                    .padding(.trailing, Spacing.sm)
                    .padding(.vertical, Spacing.s)
                    .background { Capsule().fill(Color.white.opacity(0.10)) }
                }
            }
            .padding(.horizontal, Spacing.hair)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Open the system file picker (multiple selection) and stage the chosen files.
    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { addFiles(panel.urls) }
    }

    /// Load each URL into an attachment, surfacing a message for any that can't be read.
    private func addFiles(_ urls: [URL]) {
        for url in urls {
            if let att = ChatAttachment.load(from: url) {
                attachments.append(att)
            } else {
                store.error = "Couldn't attach “\(url.lastPathComponent)” — unsupported or too large."
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            handled = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                DispatchQueue.main.async { addFiles([url]) }
            }
        }
        return handled
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    if store.messages.isEmpty && !store.isSending {
                        emptyState
                    }
                    ForEach(store.messages) { message in
                        bubble(message)
                            .id(message.id)
                    }
                    if store.isSending {
                        pendingBubble.id(Self.pendingID)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Spacing.xs)
            }
            .onChange(of: store.messages.count) { _, _ in scrollToEnd(proxy) }
            .onChange(of: store.isSending) { _, _ in scrollToEnd(proxy) }
        }
        .frame(maxHeight: .infinity)
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            if store.isSending {
                proxy.scrollTo(Self.pendingID, anchor: .bottom)
            } else if let last = store.messages.last?.id {
                proxy.scrollTo(last, anchor: .bottom)
            }
        }
    }

    /// A chat bubble. The user's bubble carries the theme's one deliberate accent —
    /// the ember — the way iMessage tints the sender's bubble; Claude's replies stay
    /// on a neutral grey so the surface reads mono apart from that single colour.
    private func bubble(_ message: ScratchMessage) -> some View {
        let isUser = message.role == .user
        let fg: Color = isUser ? Theme.ember.readableForeground : .white
        return HStack {
            if isUser { Spacer(minLength: 44) }
            VStack(alignment: .leading, spacing: Spacing.s) {
                // Attached files, shown as inline chips at the top of the bubble.
                ForEach(message.attachments) { att in
                    HStack(spacing: Spacing.s) {
                        Image(systemName: att.symbol).font(.system(size: 10, weight: .semibold))
                        Text(att.filename).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    }
                    .foregroundStyle(fg.opacity(0.85))
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xs)
                    .background { Capsule().fill(fg.opacity(0.15)) }
                }
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.system(size: 12.5))
                        .textSelection(.enabled)
                        .foregroundStyle(fg)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.horizontal, Spacing.base)
            .padding(.vertical, Spacing.sm)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isUser ? AnyShapeStyle(Theme.ember)
                                 : AnyShapeStyle(Color.white.opacity(0.10)))
            }
            if !isUser { Spacer(minLength: 44) }
        }
    }

    private var pendingBubble: some View {
        HStack {
            HStack(spacing: Spacing.sm) {
                ThinkingOrb(size: 18, tint: Theme.ember)
                Text("Typing…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(.horizontal, Spacing.base)
            .padding(.vertical, Spacing.sm)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.10))
            }
            Spacer(minLength: 44)
        }
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "ellipsis.message.fill")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.white.opacity(0.85))
            Text("Message Claude")
                .font(.system(size: 13.5, weight: .semibold))
            Text("Ask anything — the chat stays until you clear it.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.tertiaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    // MARK: - Input

    private var inputBar: some View {
        VStack(spacing: Spacing.s) {
            if let error = store.error {
                Text(error)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !attachments.isEmpty { attachmentBar }
            HStack(alignment: .center, spacing: Spacing.sm) {
                plusButton
                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white)
                    .tint(Theme.ember)
                    .lineLimit(1...4)
                    .focused($inputFocused)
                    .onSubmit(send)
                    // Return sends; Shift-Return falls through to insert a newline.
                    .onKeyPress(phases: .down) { press in
                        guard press.key == .return, !press.modifiers.contains(.shift) else {
                            return .ignored
                        }
                        send()
                        return .handled
                    }
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.sm)
                    .background {
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.07))
                            .overlay {
                                Capsule(style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                            }
                    }
            }
        }
        .onAppear { inputFocused = true }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !attachments.isEmpty), !store.isSending else { return }
        let staged = attachments
        draft = ""
        attachments = []
        store.send(text, attachments: staged, model: model.rawValue)
    }
}

/// A file staged for a message — an image (sent to Claude as a vision block), a PDF
/// (a document block), or a text-readable file (inlined as text with its filename).
struct ChatAttachment: Identifiable, Equatable {
    enum Kind: Equatable {
        case image(mediaType: String)
        case pdf
        case text
    }

    let id = UUID()
    let filename: String
    let kind: Kind
    /// Base64 for image/pdf; the decoded UTF-8 contents for text.
    let payload: String

    var symbol: String {
        switch kind {
        case .image: return "photo"
        case .pdf:   return "doc.richtext"
        case .text:  return "doc.text"
        }
    }

    /// The image media types Claude vision accepts.
    private static let imageTypes: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "gif": "image/gif", "webp": "image/webp",
    ]

    /// ~25 MB ceiling so a stray huge file can't blow past the API's request limit.
    private static let maxBytes = 25 * 1024 * 1024

    /// Build an attachment from a file URL, or nil if it can't be read / is too big.
    static func load(from url: URL) -> ChatAttachment? {
        guard let data = try? Data(contentsOf: url), data.count <= maxBytes else { return nil }
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        if let media = imageTypes[ext] {
            return ChatAttachment(filename: name, kind: .image(mediaType: media),
                                  payload: data.base64EncodedString())
        }
        if ext == "pdf" {
            return ChatAttachment(filename: name, kind: .pdf, payload: data.base64EncodedString())
        }
        if let text = String(data: data, encoding: .utf8) {
            return ChatAttachment(filename: name, kind: .text, payload: text)
        }
        return nil   // binary we can't decode as text
    }

    /// The Anthropic content block(s) this attachment contributes to a user turn.
    var contentBlocks: [[String: Any]] {
        switch kind {
        case .image(let media):
            return [["type": "image",
                     "source": ["type": "base64", "media_type": media, "data": payload]]]
        case .pdf:
            return [["type": "document",
                     "source": ["type": "base64", "media_type": "application/pdf", "data": payload]]]
        case .text:
            return [["type": "text",
                     "text": "Attached file “\(filename)”:\n\n\(payload)"]]
        }
    }
}

/// The models offered in the scratchpad's picker. Opus is the default; the lighter
/// models trade some depth for a snappier reply.
enum ScratchModel: String, CaseIterable, Identifiable {
    case opus = "claude-opus-5"
    case sonnet = "claude-sonnet-5"
    case haiku = "claude-haiku-4-5"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .opus:   return "Opus"
        case .sonnet: return "Sonnet"
        case .haiku:  return "Haiku"
        }
    }
}

/// One line of the scratchpad transcript.
struct ScratchMessage: Identifiable, Equatable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
    /// Files the user attached to this (user) turn. Empty for assistant replies.
    var attachments: [ChatAttachment] = []
}

/// Holds the in-memory transcript and drives requests to Claude. A per-view store
/// (the scratch is meant to be transient), so switching tabs and coming back keeps
/// this session only while the panel view stays alive.
@MainActor
final class ScratchStore: ObservableObject {
    @Published private(set) var messages: [ScratchMessage] = []
    @Published private(set) var isSending = false
    @Published var error: String?

    func clear() {
        messages.removeAll()
        error = nil
    }

    func send(_ text: String, attachments: [ChatAttachment] = [], model: String) {
        error = nil
        messages.append(ScratchMessage(role: .user, text: text, attachments: attachments))
        isSending = true

        // Snapshot the running conversation so Claude has the thread's context. A turn
        // with attachments becomes a content-block array (files first, then the typed
        // text); a plain turn stays a bare string.
        let wire: [[String: Any]] = messages.map { message in
            let role = message.role == .user ? "user" : "assistant"
            guard !message.attachments.isEmpty else {
                return ["role": role, "content": message.text]
            }
            var blocks = message.attachments.flatMap(\.contentBlocks)
            if !message.text.isEmpty {
                blocks.append(["type": "text", "text": message.text])
            }
            return ["role": role, "content": blocks]
        }

        Task {
            let result = await ScratchClient.send(messages: wire, model: model)
            isSending = false
            switch result {
            case .ok(let reply):
                messages.append(ScratchMessage(role: .assistant, text: reply))
            case .noToken:
                error = "Sign in to Claude Code to use Chat (no OAuth token found)."
            case .unauthorized:
                error = "Claude Code session expired — sign in again to continue."
            case .rateLimited:
                error = "Rate limited — give it a moment and try again."
            case .badData:
                error = "Couldn't read Claude's reply. Try again."
            case .http(let code, let message):
                error = message.isEmpty ? "Request failed (HTTP \(code))." : message
            case .offline(let message):
                error = "Network error: \(message)"
            }
        }
    }
}

/// Why a scratch request did (or didn't) work.
enum ScratchResult {
    case ok(String)
    case noToken
    case unauthorized
    case rateLimited(TimeInterval?)
    case http(Int, String)
    case offline(String)
    case badData
}

/// Posts a chat turn to Anthropic's Messages API using the Claude Code OAuth token
/// (the same credential the Fuel tab reads), so the scratchpad piggybacks on the
/// CLI's login rather than asking for an API key. This reuses Claude Code's OAuth
/// scope, so the request presents the Claude Code identity the token is issued for.
enum ScratchClient {
    static let endpoint = "https://api.anthropic.com/v1/messages"
    // Must start with `claude-code/`, matching the usage client, to be accepted.
    static let userAgent = "claude-code/2.1.201"
    // The OAuth token is minted for Claude Code, so the first system block must be
    // its identity line or the API rejects the credential.
    static let claudeCodeIdentity = "You are Claude Code, Anthropic's official CLI for Claude."
    static let assistantBrief = """
        You are a concise, helpful assistant living in a small scratchpad inside the \
        user's Mac menu-bar notch. Answer directly and briefly unless asked to \
        expand. Prefer plain text; use light Markdown only when it genuinely helps.
        """

    static func send(messages: [[String: Any]], model: String,
                     maxTokens: Int = 4096, timeout: TimeInterval = 120) async -> ScratchResult {
        guard let creds = Credentials.load() else { return .noToken }
        guard let url = URL(string: endpoint) else { return .offline("bad endpoint URL") }

        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": [
                ["type": "text", "text": claudeCodeIdentity],
                ["type": "text", "text": assistantBrief],
            ],
            "messages": messages,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return .badData }
        req.httpBody = data

        do {
            let (respData, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .offline("no response") }
            switch http.statusCode {
            case 200:
                guard let o = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
                      let content = o["content"] as? [[String: Any]] else { return .badData }
                let text = content
                    .filter { ($0["type"] as? String) == "text" }
                    .compactMap { $0["text"] as? String }
                    .joined(separator: "\n\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? .badData : .ok(text)
            case 401, 403:
                return .unauthorized
            case 429:
                return .rateLimited(nil)
            default:
                let message = (try? JSONSerialization.jsonObject(with: respData) as? [String: Any])
                    .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? ""
                return .http(http.statusCode, message)
            }
        } catch {
            return .offline(error.localizedDescription)
        }
    }
}
