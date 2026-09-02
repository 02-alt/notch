import SwiftUI
import AppKit

/// A tiny Claude scratchpad that lives in the notch: type a question, get an
/// answer, without leaving whatever you're doing. It reuses the Claude Code login
/// the Fuel tab already reads (the OAuth token in the Keychain), so there's no API
/// key to paste — if you're signed in to Claude Code, this just works.
///
/// The transcript is saved to disk, so the conversation survives quitting and
/// relaunching the app — it stays until you clear it with the trash button.
struct AIScratchTabView: View {
    @StateObject private var store = ScratchStore()
    @AppStorage("scratch.model") private var modelID = ScratchModel.opus.rawValue
    // Which backend the chat talks to: Claude in the cloud (default) or a local AI
    // server running on this Mac (LM Studio). `localModelID` is the id of the chosen
    // local model, remembered across launches.
    @AppStorage("scratch.provider") private var providerID = ChatProvider.claude.rawValue
    @AppStorage("scratch.localModel") private var localModelID = ""
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

    private var provider: ChatProvider {
        ChatProvider(rawValue: providerID) ?? .claude
    }

    /// The model id sent with a request — a Claude model, or the chosen local one.
    private var activeModelID: String {
        provider == .claude ? model.rawValue : localModelID
    }

    /// How the assistant is named to VoiceOver — matches the header, so a local
    /// model isn't announced as "Claude".
    private var assistantName: String {
        provider == .claude ? "Claude" : "Local AI"
    }

    /// The short name shown in the picker and headers for the current selection.
    private var activeTitle: String {
        switch provider {
        case .claude: return model.title
        case .local:  return localModelID.isEmpty ? "Local" : LocalClient.short(localModelID)
        }
    }

    var body: some View {
        VStack(spacing: Spacing.sm) {
            chatBar
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
                    .strokeBorder(Color.white, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Chats

    /// A horizontal row of chat pills — one per saved conversation, tap to switch —
    /// with a "+" at the end to start a new one. Right-click a pill to delete it.
    private var chatBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.s) {
                ForEach(store.conversations) { convo in
                    chatPill(convo)
                }
                newChatButton
            }
            .padding(.horizontal, Spacing.hair)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chatPill(_ convo: ScratchConversation) -> some View {
        let active = convo.id == store.activeID
        return Button { store.switchTo(convo.id) } label: {
            Text(convo.displayTitle)
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(active ? Color.black : Theme.secondaryText)
                .padding(.horizontal, Spacing.md)
                .frame(height: 24)
                .background {
                    Capsule().fill(active ? AnyShapeStyle(Color.white)
                                          : AnyShapeStyle(Color.white.opacity(0.08)))
                }
        }
        .buttonStyle(.plain)
        .notchHover(scale: 1.06)
        .contextMenu {
            Button(role: .destructive) { store.delete(convo.id) } label: {
                Label("Delete Chat", systemImage: "trash")
            }
        }
        .accessibilityLabel("\(convo.displayTitle) chat")
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }

    private var newChatButton: some View {
        Button { store.newChat() } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 28, height: 24)
                .background { Capsule().fill(Color.white.opacity(0.08)) }
        }
        .buttonStyle(.plain)
        .notchHover(scale: 1.08)
        .help("New chat")
        .accessibilityLabel("New chat")
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
                Text(provider == .claude ? "Claude" : "Local AI")
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
                    .accessibilityLabel("Clear the conversation")
                }
            }
        }
        .padding(.bottom, Spacing.hair)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
        }
    }

    /// A single "which AI do you want to talk to" picker. The top section is Claude
    /// (in the cloud); the bottom lists whatever models a local LM Studio server has
    /// loaded, so you can chat entirely on-device. Picking either one also switches
    /// the active provider.
    private var modelMenu: some View {
        Menu {
            Section("Claude") {
                ForEach(ScratchModel.allCases) { m in
                    Button {
                        providerID = ChatProvider.claude.rawValue
                        model = m
                    } label: {
                        if provider == .claude && model == m { Label(m.title, systemImage: "checkmark") }
                        else { Text(m.title) }
                    }
                }
            }
            Section("Local — LM Studio") {
                if store.localModels.isEmpty {
                    Button { store.detectLocal() } label: {
                        Label("No local model found — Refresh", systemImage: "arrow.clockwise")
                    }
                } else {
                    ForEach(store.localModels, id: \.self) { id in
                        Button {
                            providerID = ChatProvider.local.rawValue
                            localModelID = id
                        } label: {
                            if provider == .local && localModelID == id {
                                Label(LocalClient.short(id), systemImage: "checkmark")
                            } else {
                                Text(LocalClient.short(id))
                            }
                        }
                    }
                    Divider()
                    Button { store.detectLocal() } label: {
                        Label("Refresh models", systemImage: "arrow.clockwise")
                    }
                }
            }
        } label: {
            HStack(spacing: Spacing.xs) {
                Text(activeTitle).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
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
        .accessibilityLabel("Choose which AI to chat with")
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
        .accessibilityLabel("Attach documents")
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
            // Jump to the latest message when the user switches to another chat.
            .onChange(of: store.activeID) { _, _ in scrollToEnd(proxy) }
            // A transcript restored from disk arrives fully populated, so the
            // count/isSending changes never fire — jump to the latest reply on appear.
            .onAppear { scrollToEnd(proxy) }
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

    /// A chat bubble. The user's bubble is solid white with black text, the way
    /// iMessage tints the sender's bubble; Claude's replies stay on a neutral grey —
    /// the surface reads pure black-and-white, no accent colour.
    private func bubble(_ message: ScratchMessage) -> some View {
        let isUser = message.role == .user
        let fg: Color = isUser ? .black : .white
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
                    .fill(isUser ? AnyShapeStyle(Color.white)
                                 : AnyShapeStyle(Color.white.opacity(0.10)))
            }
            if !isUser { Spacer(minLength: 44) }
        }
        // VoiceOver reads the bubble as one element and announces who spoke, since
        // the white/grey tint alone can't convey sender to a screen reader.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isUser ? "You" : assistantName)
    }

    private var pendingBubble: some View {
        HStack {
            HStack(spacing: Spacing.sm) {
                ThinkingOrb(size: 18, tint: .white)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(assistantName) is typing")
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "ellipsis.message.fill")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.white.opacity(0.85))
                .accessibilityHidden(true)
            Text(provider == .claude ? "Message Claude" : "Message \(activeTitle)")
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
                    .tint(Color.white)
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
        .onAppear {
            inputFocused = true
            // Ask a local LM Studio server what models it has loaded, so the picker
            // can offer them. Silent + cheap if nothing's running.
            store.detectLocal()
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !attachments.isEmpty), !store.isSending else { return }
        if provider == .local && localModelID.isEmpty {
            store.error = "Pick a local model first — open the model menu (top left)."
            return
        }
        let staged = attachments
        draft = ""
        attachments = []
        store.send(text, attachments: staged, provider: provider, model: activeModelID)
    }
}

/// A file staged for a message — an image (sent to Claude as a vision block), a PDF
/// (a document block), or a text-readable file (inlined as text with its filename).
struct ChatAttachment: Identifiable, Equatable, Codable {
    enum Kind: Equatable, Codable {
        case image(mediaType: String)
        case pdf
        case text
    }

    let id: UUID
    let filename: String
    let kind: Kind
    /// Base64 for image/pdf; the decoded UTF-8 contents for text.
    let payload: String

    init(id: UUID = UUID(), filename: String, kind: Kind, payload: String) {
        self.id = id
        self.filename = filename
        self.kind = kind
        self.payload = payload
    }

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

    /// The OpenAI-style content part(s) this attachment contributes — used by the
    /// local (LM Studio) backend. Images become `image_url` data URIs (only vision
    /// models will use them); PDFs degrade to a note, since local servers can't read
    /// them directly; text files inline as before.
    var openAIParts: [[String: Any]] {
        switch kind {
        case .image(let media):
            return [["type": "image_url",
                     "image_url": ["url": "data:\(media);base64,\(payload)"]]]
        case .pdf:
            return [["type": "text",
                     "text": "[Attached PDF “\(filename)” — the local model can't read PDFs directly.]"]]
        case .text:
            return [["type": "text",
                     "text": "Attached file “\(filename)”:\n\n\(payload)"]]
        }
    }
}

/// Which backend the Chat tab talks to.
enum ChatProvider: String {
    case claude   // Anthropic in the cloud, via the Claude Code OAuth token
    case local    // a local LM Studio server on this Mac
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
struct ScratchMessage: Identifiable, Equatable, Codable {
    enum Role: String, Codable { case user, assistant }
    let id: UUID
    let role: Role
    var text: String
    /// Files the user attached to this (user) turn. Empty for assistant replies.
    var attachments: [ChatAttachment] = []

    init(id: UUID = UUID(), role: Role, text: String, attachments: [ChatAttachment] = []) {
        self.id = id
        self.role = role
        self.text = text
        self.attachments = attachments
    }
}

/// Holds the chats and drives requests to Claude. Every conversation is loaded from
/// disk on launch and re-saved after each turn, so they survive quitting the app.
/// The user can keep several chats side by side and switch between them with the pill
/// row; `messages` always mirrors whichever chat is active.
@MainActor
final class ScratchStore: ObservableObject {
    /// Every saved chat, in stable creation order (the pill row's order).
    @Published private(set) var conversations: [ScratchConversation] = []
    /// The chat currently shown; `messages` is its transcript.
    @Published private(set) var activeID: UUID
    @Published private(set) var messages: [ScratchMessage] = []
    @Published private(set) var isSending = false
    @Published var error: String?
    /// Model ids reported by a local LM Studio server, if one is running. Empty when
    /// none is reachable — the picker then shows a "no local model" hint instead.
    @Published private(set) var localModels: [String] = []

    /// Remembers which chat was open across launches.
    private static let activeKey = "scratch.activeChat"

    init() {
        var convos = ChatArchive.load()
        if convos.isEmpty {
            let fresh = ScratchConversation()
            ChatArchive.save(fresh)
            convos = [fresh]
        }
        let savedID = UserDefaults.standard.string(forKey: Self.activeKey)
            .flatMap(UUID.init(uuidString:))
        let active = convos.first { $0.id == savedID } ?? convos[0]
        conversations = convos
        activeID = active.id
        messages = active.messages
    }

    /// Empty the active chat (keeps the pill, resets its title to "New Chat").
    func clear() {
        messages.removeAll()
        error = nil
        if let i = conversations.firstIndex(where: { $0.id == activeID }) {
            conversations[i].title = ""
        }
        syncActive()
    }

    /// Start a fresh chat — or reuse an existing blank one so taps don't pile up
    /// empty pills — and switch to it.
    func newChat() {
        if let empty = conversations.first(where: { $0.messages.isEmpty }) {
            switchTo(empty.id)
            return
        }
        let convo = ScratchConversation()
        conversations.append(convo)
        ChatArchive.save(convo)
        switchTo(convo.id)
    }

    /// Show a different chat, saving the one we're leaving first.
    func switchTo(_ id: UUID) {
        guard id != activeID else { return }
        syncActive()
        activeID = id
        messages = conversations.first { $0.id == id }?.messages ?? []
        error = nil
        UserDefaults.standard.set(id.uuidString, forKey: Self.activeKey)
    }

    /// Delete a chat. If it was the last one, a fresh empty chat takes its place; if it
    /// was the active one, the first remaining chat becomes active.
    func delete(_ id: UUID) {
        ChatArchive.delete(id)
        conversations.removeAll { $0.id == id }
        if conversations.isEmpty {
            let fresh = ScratchConversation()
            ChatArchive.save(fresh)
            conversations = [fresh]
        }
        if activeID == id {
            let next = conversations[0]
            activeID = next.id
            messages = next.messages
            error = nil
            UserDefaults.standard.set(next.id.uuidString, forKey: Self.activeKey)
        }
    }

    /// Fold the live `messages` back into the active chat, refresh its title from the
    /// first user line, and persist it.
    private func syncActive() {
        guard let i = conversations.firstIndex(where: { $0.id == activeID }) else { return }
        conversations[i].messages = messages
        conversations[i].updatedAt = Date()
        if conversations[i].title.isEmpty,
           let first = messages.first(where: { $0.role == .user }) {
            conversations[i].title = Self.derivedTitle(from: first)
        }
        ChatArchive.save(conversations[i])
    }

    /// A short pill title from a chat's first user message (its text, or an attachment
    /// name), trimmed to one line.
    nonisolated static func derivedTitle(from message: ScratchMessage) -> String {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = !text.isEmpty ? text : (message.attachments.first?.filename ?? "New Chat")
        let firstLine = source.split(whereSeparator: \.isNewline).first.map(String.init) ?? source
        return firstLine.count > 28 ? String(firstLine.prefix(27)) + "…" : firstLine
    }

    /// Refresh the list of locally-loaded models (fire-and-forget; silent on failure).
    func detectLocal() {
        Task { localModels = await LocalClient.models() }
    }

    func send(_ text: String, attachments: [ChatAttachment] = [],
              provider: ChatProvider, model: String) {
        error = nil
        messages.append(ScratchMessage(role: .user, text: text, attachments: attachments))
        syncActive()
        isSending = true

        // Snapshot the running conversation so the model has the thread's context,
        // then shape it for whichever backend we're talking to.
        let snapshot = messages

        Task {
            let result: ScratchResult
            switch provider {
            case .claude:
                result = await ScratchClient.send(messages: Self.anthropicWire(snapshot), model: model)
            case .local:
                result = await LocalClient.send(messages: Self.openAIWire(snapshot), model: model)
            }
            isSending = false
            switch result {
            case .ok(let reply):
                messages.append(ScratchMessage(role: .assistant, text: reply))
                syncActive()
            case .noToken:
                error = "Sign in to Claude Code to use Chat (no OAuth token found)."
            case .unauthorized:
                error = "Claude Code session expired — sign in again to continue."
            case .rateLimited:
                error = "Rate limited — give it a moment and try again."
            case .badData:
                error = "Couldn't read the reply. Try again."
            case .http(let code, let message):
                error = message.isEmpty ? "Request failed (HTTP \(code))." : message
            case .offline(let message):
                error = provider == .local ? message : "Network error: \(message)"
            }
        }
    }

    /// Anthropic Messages shape: a turn with attachments becomes a content-block array
    /// (files first, then the typed text); a plain turn stays a bare string.
    static func anthropicWire(_ messages: [ScratchMessage]) -> [[String: Any]] {
        messages.map { message in
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
    }

    /// OpenAI chat shape (LM Studio): plain turns stay strings; turns with attachments
    /// become a content-parts array.
    static func openAIWire(_ messages: [ScratchMessage]) -> [[String: Any]] {
        messages.map { message in
            let role = message.role == .user ? "user" : "assistant"
            guard !message.attachments.isEmpty else {
                return ["role": role, "content": message.text]
            }
            var parts = message.attachments.flatMap(\.openAIParts)
            if !message.text.isEmpty {
                parts.append(["type": "text", "text": message.text])
            }
            return ["role": role, "content": parts]
        }
    }
}

/// One saved chat: its transcript plus a little metadata for the pill row.
struct ScratchConversation: Identifiable, Equatable, Codable {
    let id: UUID
    /// Auto-derived from the first user message; empty until then.
    var title: String
    var messages: [ScratchMessage]
    let createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), title: String = "", messages: [ScratchMessage] = [],
         createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// What the pill shows — a placeholder while the chat is still empty.
    var displayTitle: String { title.isEmpty ? "New Chat" : title }
}

/// On-disk store for every chat: one JSON file per conversation under Application
/// Support, so switching or clearing one chat only rewrites that file. Writes go
/// through a serial queue (off the main thread, and race-free); failures are silent
/// so a disk hiccup never takes down the chat.
enum ChatArchive {
    /// `~/Library/Application Support/NotchGlass/Chats`.
    static let directory: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("NotchGlass/Chats", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let ioQueue = DispatchQueue(label: "com.notchglass.chats")

    private static func fileURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    /// Every saved chat, oldest first (a stable order for the pill row).
    static func load() -> [ScratchConversation] {
        migrateLegacyTranscript()
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> ScratchConversation? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(ScratchConversation.self, from: data)
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    static func save(_ convo: ScratchConversation) {
        ioQueue.async {
            guard let data = try? JSONEncoder().encode(convo) else { return }
            try? data.write(to: fileURL(convo.id), options: .atomic)
        }
    }

    static func delete(_ id: UUID) {
        ioQueue.async { try? FileManager.default.removeItem(at: fileURL(id)) }
    }

    /// One-time upgrade from the earlier single-file transcript: fold it into the
    /// first chat, then remove it. Runs only while no per-chat files exist yet.
    private static func migrateLegacyTranscript() {
        let legacy = directory
            .deletingLastPathComponent()               // …/NotchGlass
            .appendingPathComponent("chat-transcript.json")
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        defer { try? FileManager.default.removeItem(at: legacy) }

        let existing = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" } ?? []
        guard existing.isEmpty,
              let data = try? Data(contentsOf: legacy),
              let messages = try? JSONDecoder().decode([ScratchMessage].self, from: data),
              !messages.isEmpty else { return }

        var convo = ScratchConversation(messages: messages)
        if let first = messages.first(where: { $0.role == .user }) {
            convo.title = ScratchStore.derivedTitle(from: first)
        }
        if let out = try? JSONEncoder().encode(convo) {
            try? out.write(to: fileURL(convo.id), options: .atomic)
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

/// Talks to a local LM Studio server on this Mac via its OpenAI-compatible API
/// (`http://localhost:1234/v1`). No API key, no cloud — the whole exchange stays on
/// the machine. LM Studio must be running with a model loaded and its local server
/// started (Developer ▸ Start Server); otherwise the connection simply refuses and we
/// surface a hint. The same endpoint shape works for other OpenAI-compatible local
/// servers, so pointing `base` elsewhere would reuse all of this.
enum LocalClient {
    static let base = "http://localhost:1234/v1"
    static let brief = """
        You are a concise, helpful assistant living in a small scratchpad inside the \
        user's Mac menu-bar notch. Answer directly and briefly unless asked to expand.
        """

    /// A compact display name for a model id (drop any publisher path, cap the length).
    static func short(_ id: String) -> String {
        let last = id.split(separator: "/").last.map(String.init) ?? id
        return last.count > 24 ? String(last.prefix(23)) + "…" : last
    }

    /// The ids of models the local server currently has available. Empty if nothing is
    /// reachable (server off, no model loaded) — deliberately quiet, short timeout.
    static func models() async -> [String] {
        guard let url = URL(string: base + "/models") else { return [] }
        let req = URLRequest(url: url, timeoutInterval: 3)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = o["data"] as? [[String: Any]] else { return [] }
        return arr.compactMap { $0["id"] as? String }
    }

    static func send(messages: [[String: Any]], model: String,
                     maxTokens: Int = 4096, timeout: TimeInterval = 300) async -> ScratchResult {
        guard let url = URL(string: base + "/chat/completions") else { return .offline("bad endpoint URL") }

        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var wire: [[String: Any]] = [["role": "system", "content": brief]]
        wire.append(contentsOf: messages)
        let body: [String: Any] = [
            "model": model,
            "messages": wire,
            "max_tokens": maxTokens,
            "stream": false,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return .badData }
        req.httpBody = data

        do {
            let (respData, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .offline("no response") }
            switch http.statusCode {
            case 200:
                guard let o = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
                      let choices = o["choices"] as? [[String: Any]],
                      let msg = choices.first?["message"] as? [String: Any],
                      let text = (msg["content"] as? String)?
                          .trimmingCharacters(in: .whitespacesAndNewlines)
                else { return .badData }
                return text.isEmpty ? .badData : .ok(text)
            case 404:
                return .http(404, "No model loaded in LM Studio — load one, then try again.")
            default:
                let message = (try? JSONSerialization.jsonObject(with: respData) as? [String: Any])
                    .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? ""
                return .http(http.statusCode, message)
            }
        } catch {
            return .offline("Can't reach LM Studio at localhost:1234. Open LM Studio, load a model, and start its local server (Developer ▸ Start Server).")
        }
    }
}
