import SwiftUI
import AppKit

/// Messages tab: the recent iMessage/SMS conversations read from the local Messages
/// database, with an inline reply sent through Messages.app. Drills in from the chat
/// list to a thread and back. All reads are local; replying needs Messages running.
struct MessagesTabView: View {
    @EnvironmentObject private var store: MessagesStore
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Group {
            if !store.accessGranted {
                accessPrompt
            } else if let chat = store.selectedChat {
                thread(chat)
            } else {
                chatList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { store.start() }
        .onDisappear { store.stop() }
        // Never let an unsent reply carry from one conversation into another — that
        // would send it to the wrong recipient.
        .onChange(of: store.selectedChat?.id) { _, _ in draft = "" }
    }

    // MARK: - Chat list

    private var chatList: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            header(title: "Messages", subtitle: store.chats.isEmpty ? nil : "\(store.chats.count) recent")
            if store.chats.isEmpty {
                emptyState(icon: "message", line: "No conversations yet.")
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: Spacing.xs) {
                        ForEach(store.chats) { chat in
                            chatRow(chat)
                        }
                    }
                }
            }
        }
        .padding(Spacing.lg)
    }

    private func chatRow(_ chat: IMChat) -> some View {
        Button { store.select(chat) } label: {
            HStack(spacing: Spacing.base) {
                avatar(for: chat.title)
                VStack(alignment: .leading, spacing: 2) {
                    Text(chat.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(preview(chat))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: Spacing.sm)
                Text(timeLabel(chat.lastDate))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .padding(.horizontal, Spacing.base)
            .padding(.vertical, Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .notchHover(scale: 1.01)
    }

    private func preview(_ chat: IMChat) -> String {
        let body = chat.lastText.replacingOccurrences(of: "\n", with: " ")
        return chat.lastFromMe ? "You: \(body)" : body
    }

    // MARK: - Thread

    private func thread(_ chat: IMChat) -> some View {
        VStack(spacing: 0) {
            threadHeader(chat)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: Spacing.xs) {
                        ForEach(store.messages) { message in
                            bubble(message).id(message.id)
                        }
                        Color.clear.frame(height: 1).id(bottomAnchor)
                    }
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.sm)
                }
                .onChange(of: store.messages) { _, _ in scrollToEnd(proxy) }
                .onAppear { scrollToEnd(proxy, animated: false) }
            }
            replyBar(chat)
        }
    }

    private func threadHeader(_ chat: IMChat) -> some View {
        HStack(spacing: Spacing.sm) {
            Button { store.back() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 28, height: 28)
                    .background { Circle().fill(Color.white.opacity(0.08)) }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            Text(chat.title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.base)
        .padding(.bottom, Spacing.sm)
    }

    /// A message bubble — sent (from me) is solid white / black text on the right, the
    /// way iMessage tints the sender; received stays neutral grey on the left.
    private func bubble(_ message: IMMessage) -> some View {
        let mine = message.fromMe
        let fg: Color = mine ? .black : .white
        return HStack {
            if mine { Spacer(minLength: 44) }
            Text(message.text)
                .font(.system(size: 12.5))
                .textSelection(.enabled)
                .foregroundStyle(fg)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, Spacing.base)
                .padding(.vertical, Spacing.sm)
                .background {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(mine ? AnyShapeStyle(Color.white)
                                   : AnyShapeStyle(Color.white.opacity(0.10)))
                }
            if !mine { Spacer(minLength: 44) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(mine ? "You" : "Them")
    }

    private func replyBar(_ chat: IMChat) -> some View {
        VStack(spacing: Spacing.s) {
            if let error = store.sendError {
                Text(error)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .center, spacing: Spacing.sm) {
                TextField("Reply", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white)
                    .tint(.white)
                    .lineLimit(1...4)
                    .focused($inputFocused)
                    .onKeyPress(phases: .down) { press in
                        guard press.key == .return, !press.modifiers.contains(.shift) else { return .ignored }
                        sendReply()
                        return .handled
                    }
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.sm)
                    .background {
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.07))
                            .overlay { Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1) }
                    }
                Button(action: sendReply) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24, weight: .regular))
                        .foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty
                                         ? Theme.tertiaryText : settings.accent)
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.bottom, Spacing.base)
        .padding(.top, Spacing.s)
    }

    private func sendReply() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.send(text)
        draft = ""
    }

    // MARK: - Access prompt

    private var accessPrompt: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "lock.shield")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.white.opacity(0.85))
            Text("Full Disk Access needed")
                .font(.system(size: 13.5, weight: .semibold))
            Text("The Messages tab reads your conversations from the local Messages database, which macOS protects. Grant All in a notch Full Disk Access, then reopen this tab.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.tertiaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text("Open Full Disk Access")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.sm)
                    .background { Capsule().fill(settings.accent.opacity(0.9)) }
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Spacing.lg)
    }

    // MARK: - Bits

    @State private var draft = ""
    @FocusState private var inputFocused: Bool
    private let bottomAnchor = "messages.bottom"

    private func header(title: String, subtitle: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
            if let subtitle {
                Text(subtitle).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.tertiaryText)
            }
            Spacer()
        }
    }

    private func emptyState(icon: String, line: String) -> some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: icon).font(.system(size: 26)).foregroundStyle(.white.opacity(0.8))
            Text(line).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.tertiaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func avatar(for name: String) -> some View {
        let initial = name.first.map { String($0).uppercased() } ?? "?"
        return Text(initial)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background { Circle().fill(Color.white.opacity(0.12)) }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard !store.messages.isEmpty else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
        } else {
            proxy.scrollTo(bottomAnchor, anchor: .bottom)
        }
    }

    private func timeLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}
