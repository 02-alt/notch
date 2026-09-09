import SwiftUI

/// Twitch tab: sign in with Twitch, edit the live stream's title + category, and watch
/// (and reply to) chat — all from the notch.
struct TwitchTabView: View {
    @EnvironmentObject private var store: TwitchStore
    @EnvironmentObject private var settings: SettingsStore

    @State private var titleDraft = ""
    @State private var categoryDraft = ""
    @State private var chatDraft = ""
    @FocusState private var chatFocused: Bool
    private let bottomAnchor = "twitch.chat.bottom"

    private var purple: Color { Color(hex: "#9146FF") ?? .purple }

    var body: some View {
        Group {
            switch store.phase {
            case .notConfigured: notConfigured
            case .signedOut:     signIn
            case .awaitingAuth:  awaitingAuth
            case .connecting:    loading
            case .ready:         ready
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Spacing.lg)
        .onAppear {
            store.start()
            titleDraft = store.title
            categoryDraft = store.category
        }
        .onDisappear { store.stop() }
        .onChange(of: store.title) { _, new in titleDraft = new }
        .onChange(of: store.category) { _, new in categoryDraft = new }
    }

    // MARK: - Ready (editor + chat)

    private var ready: some View {
        VStack(spacing: Spacing.md) {
            header
            editor
            Divider().overlay(Theme.line(0.12))
            chatList
            chatBar
        }
    }

    private var header: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(store.chatConnected ? Color.green : Theme.tertiaryText)
            Text(store.displayName)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
            Spacer()
            Button("Sign out") { store.signOut() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, Spacing.md).padding(.vertical, Spacing.xs)
                .background { Capsule().fill(Color.white.opacity(0.08)) }
        }
    }

    private var editor: some View {
        VStack(spacing: Spacing.sm) {
            labeledField("Title", text: $titleDraft)
            labeledField("Category", text: $categoryDraft)
            HStack(spacing: Spacing.sm) {
                if let error = store.errorText {
                    Text(error)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
                Spacer()
                Button {
                    store.saveEdit(newTitle: titleDraft, newCategory: categoryDraft)
                } label: {
                    HStack(spacing: Spacing.xs) {
                        if store.savingEdit { ProgressView().controlSize(.small) }
                        Text(store.savingEdit ? "Saving…" : "Update stream")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Spacing.lg).padding(.vertical, Spacing.sm)
                    .background { Capsule().fill(purple.opacity(dirty ? 0.9 : 0.4)) }
                }
                .buttonStyle(.plain)
                .disabled(!dirty || store.savingEdit)
            }
        }
    }

    private var dirty: Bool {
        titleDraft != store.title || categoryDraft != store.category
    }

    private func labeledField(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: Spacing.sm) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 62, alignment: .leading)
            TextField(label, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(.white)
                .tint(purple)
                .padding(.horizontal, Spacing.md).padding(.vertical, Spacing.sm)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line(0.12), lineWidth: 1) }
                }
        }
    }

    private var chatList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: Spacing.xs) {
                    ForEach(store.chat) { msg in
                        (Text(msg.user).font(.system(size: 12, weight: .bold))
                            .foregroundColor(Color(hex: msg.colorHex ?? "") ?? purple)
                         + Text("  \(msg.text)").font(.system(size: 12))
                            .foregroundColor(.white))
                            .fixedSize(horizontal: false, vertical: true)
                            .id(msg.id)
                    }
                    Color.clear.frame(height: 1).id(bottomAnchor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: store.chat) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
            }
        }
    }

    private var chatBar: some View {
        HStack(spacing: Spacing.sm) {
            TextField(store.chatConnected ? "Chat" : "Connecting…", text: $chatDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(.white)
                .tint(purple)
                .focused($chatFocused)
                .onSubmit(sendChat)
                .padding(.horizontal, Spacing.lg).padding(.vertical, Spacing.sm)
                .background {
                    Capsule().fill(Color.white.opacity(0.07))
                        .overlay { Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1) }
                }
                .disabled(!store.chatConnected)
            Button(action: sendChat) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(chatDraft.trimmingCharacters(in: .whitespaces).isEmpty ? Theme.tertiaryText : purple)
            }
            .buttonStyle(.plain)
            .disabled(chatDraft.trimmingCharacters(in: .whitespaces).isEmpty || !store.chatConnected)
        }
    }

    private func sendChat() {
        let text = chatDraft
        chatDraft = ""
        store.sendChat(text)
    }

    // MARK: - Auth / empty states

    private var signIn: some View {
        centered(icon: "dot.radiowaves.left.and.right", title: "Connect Twitch") {
            Text("Sign in to edit your stream’s title and category and watch chat, right from the notch.")
                .multilineTextAlignment(.center)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.tertiaryText)
                .frame(maxWidth: 320)
            if let error = store.errorText {
                Text(error).font(.system(size: 10.5)).foregroundStyle(.orange).multilineTextAlignment(.center)
            }
            Button { store.connect() } label: {
                Text("Connect Twitch")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Spacing.xl).padding(.vertical, Spacing.sm)
                    .background { Capsule().fill(purple) }
            }
            .buttonStyle(.plain)
        }
    }

    private var awaitingAuth: some View {
        centered(icon: "key.fill", title: "Enter this code on Twitch") {
            Text(store.userCode)
                .font(.system(size: 30, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .tracking(4)
            Text("Go to twitch.tv/activate (it should have opened) and enter the code to finish connecting.")
                .multilineTextAlignment(.center)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.tertiaryText)
                .frame(maxWidth: 320)
            Button { store.openVerification() } label: {
                Text("Open twitch.tv/activate")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Spacing.lg).padding(.vertical, Spacing.sm)
                    .background { Capsule().fill(purple.opacity(0.9)) }
            }
            .buttonStyle(.plain)
        }
    }

    private var loading: some View {
        VStack(spacing: Spacing.md) { ProgressView().controlSize(.large) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var notConfigured: some View {
        centered(icon: "wrench.and.screwdriver.fill", title: "Twitch isn’t set up yet") {
            Text("This build has no Twitch Client ID. Register a public app at dev.twitch.tv and drop its Client ID into TwitchAPI.clientID.")
                .multilineTextAlignment(.center)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.tertiaryText)
                .frame(maxWidth: 340)
        }
    }

    private func centered<Content: View>(icon: String, title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(.white.opacity(0.85))
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
