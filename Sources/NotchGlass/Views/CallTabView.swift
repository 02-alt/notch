import SwiftUI

/// The Call tab — a cockpit for whatever call you're in. It lights up automatically
/// when the mic or camera goes live (via ``CallMonitor``), showing live status (which
/// app, how long, mic/camera state), a voice level meter, and a universal hardware
/// **mute** you can hit without alt-tabbing back to the call app.
///
/// This is the universal v1: it works with every call app because it reads macOS's own
/// device-in-use signals. Per-app extras (Discord join/speaking/chat events, web-call
/// mute state) layer on top later. Panel-native so it reads on every theme.
struct CallTabView: View {
    @EnvironmentObject private var settings: SettingsStore
    @StateObject private var call = CallMonitor.shared

    var body: some View {
        VStack(spacing: Spacing.base) {
            header
            if call.onCall {
                liveState
            } else {
                idle
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { call.start(); call.startMetering() }
        .onDisappear { call.stopMetering() }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("CALL")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.secondaryText)
                .kerning(0.6)
            Spacer(minLength: 0)
            if call.onCall, let app = call.callApp {
                Text(app)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryText)
                    .lineLimit(1)
            }
        }
    }

    // MARK: Idle

    private var idle: some View {
        VStack(spacing: Spacing.sm) {
            Spacer(minLength: 0)
            Image(systemName: "phone.and.waveform.fill")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
            Text("No call right now")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.primaryText)
            Text("This lights up on its own the moment your mic or camera goes live — with mute, level and call alerts.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Spacing.xl)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Live

    private var liveState: some View {
        VStack(spacing: Spacing.lg) {
            Spacer(minLength: 0)
            muteButton
            statusRow
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Big circular mute control with a live level ring around it.
    private var muteButton: some View {
        let muted = call.inputMuted
        return Button {
            call.toggleMute()
        } label: {
            ZStack {
                // Level ring — grows with your voice while unmuted.
                Circle()
                    .stroke(Theme.line(0.10), lineWidth: 4)
                    .frame(width: 92, height: 92)
                Circle()
                    .trim(from: 0, to: muted ? 0 : CGFloat(call.level))
                    .stroke(settings.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 92, height: 92)
                    .animation(.easeOut(duration: 0.12), value: call.level)

                Circle()
                    .fill(muted ? Theme.line(0.12) : Color.red.opacity(0.9))
                    .frame(width: 72, height: 72)
                Image(systemName: muted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(muted ? Theme.secondaryText : .white)
            }
        }
        .buttonStyle(.plain)
        .notchHover(scale: 1.04)
        .help(muted ? "Unmute your microphone" : "Mute your microphone")
        .overlay(alignment: .bottom) {
            Text(muted ? "Muted" : "Live")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(muted ? Theme.secondaryText : .red)
                .offset(y: 16)
        }
    }

    private var statusRow: some View {
        HStack(spacing: Spacing.sm) {
            chip(call.cameraLive ? "video.fill" : "video.slash.fill",
                 call.cameraLive ? "Camera on" : "Camera off",
                 on: call.cameraLive)
            durationChip
        }
        .padding(.top, Spacing.md)
    }

    private func chip(_ symbol: String, _ text: String, on: Bool) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold))
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(on ? Theme.primaryText : Theme.secondaryText)
        .padding(.horizontal, Spacing.md)
        .frame(height: 28)
        .innerCard(cornerRadius: 10)
    }

    private var durationChip: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = call.callStartedAt.map { context.date.timeIntervalSince($0) } ?? 0
            HStack(spacing: Spacing.xs) {
                Image(systemName: "clock.fill").font(.system(size: 10, weight: .bold))
                Text(Self.duration(elapsed))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .contentTransition(.numericText())
            }
            .foregroundStyle(Theme.primaryText)
            .padding(.horizontal, Spacing.md)
            .frame(height: 28)
            .innerCard(cornerRadius: 10)
        }
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let t = Int(max(0, seconds))
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
