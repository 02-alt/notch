import SwiftUI
import AppKit

/// Screen capture from the notch. A segmented switch flips between **Screenshot**
/// and **Record** — but the same three scopes (Region / Window / Full) sit under
/// *both* modes, so you can screenshot *or* record an area, a window, or the whole
/// screen. Tapping a scope in Record mode either starts the in-notch full-screen
/// recording (Full → the takeover Stop screen) or hands off to the system capture
/// toolbar (Region / Window). Every finished capture is routed onto the Drop shelf
/// (see `ScreenRecorder`).
struct RecordTabView: View {
    @EnvironmentObject private var vm: NotchViewModel
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject private var recorder = ScreenRecorder.shared

    /// Whether the scopes below take a still or a video. Ignored while a full-screen
    /// recording runs — that state takes over the whole tab with the Stop screen.
    enum Mode: String, CaseIterable, Identifiable {
        case screenshot, record
        var id: String { rawValue }
        var title: String { self == .screenshot ? "Screenshot" : "Record" }
        var symbol: String { self == .screenshot ? "camera.fill" : "record.circle" }
    }

    @State private var mode: Mode = .screenshot

    var body: some View {
        Group {
            if recorder.isRecording {
                // A full-screen recording pins the screen — the entire tab becomes
                // the Stop control so there's one unmissable target.
                recordingScreen
                    .transition(.opacity)
            } else {
                VStack(spacing: 12) {
                    modeSwitch
                    scopeRow
                }
                .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: recorder.isRecording)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: mode)
    }

    // MARK: - Mode switch

    private var modeSwitch: some View {
        HStack(spacing: 4) {
            ForEach(Mode.allCases) { m in
                Button {
                    mode = m
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: m.symbol)
                            .font(.system(size: 12, weight: .semibold))
                        Text(m.title)
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(mode == m ? Theme.primaryText : Theme.secondaryText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background {
                        if mode == m {
                            Capsule(style: .continuous)
                                .fill(Theme.primaryText.opacity(0.14))
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .linkCursor()
            }
        }
        .padding(4)
        .innerCard(cornerRadius: 19)
    }

    // MARK: - Scopes (shared by both modes)

    /// The three capture scopes. Same row under both modes; the mode only changes
    /// what each tile *does* (and its subtitle / accent).
    private var scopeRow: some View {
        HStack(spacing: 12) {
            scopeTile(.region)
            scopeTile(.window)
            scopeTile(.full)
        }
        .frame(maxHeight: .infinity)
    }

    /// A capture scope — region, window or whole screen.
    private enum Scope {
        case region, window, full
        var title: String {
            switch self {
            case .region: return "Region"
            case .window: return "Window"
            case .full:   return "Full"
            }
        }
        var symbol: String {
            switch self {
            case .region: return "rectangle.dashed"
            case .window: return "macwindow"
            case .full:   return "rectangle.inset.filled"
            }
        }
    }

    /// Subtitle depends on the mode so the tile reads correctly as a still vs video.
    private func subtitle(_ scope: Scope) -> String {
        switch (mode, scope) {
        case (.screenshot, .region): return "Drag an area"
        case (.screenshot, .window): return "Pick a window"
        case (.screenshot, .full):   return "Whole screen"
        case (.record, .region):     return "Record an area"
        case (.record, .window):     return "Record a window"
        case (.record, .full):       return "Whole screen"
        }
    }

    /// Runs the capture for the current mode + scope.
    private func fire(_ scope: Scope) {
        switch (mode, scope) {
        case (.screenshot, .region): recorder.captureRegion()
        case (.screenshot, .window): recorder.captureWindow()
        case (.screenshot, .full):   recorder.captureFullScreen()
        case (.record, .region):     recorder.recordRegion()
        case (.record, .window):     recorder.recordWindow()
        case (.record, .full):       recorder.recordFullScreen()
        }
    }

    private func scopeTile(_ scope: Scope) -> some View {
        let recording = mode == .record
        let accent = Color(hex: "FF453A") ?? .red
        return Button {
            fire(scope)
        } label: {
            VStack(spacing: 7) {
                Image(systemName: scope.symbol)
                    .font(.system(size: 25, weight: .regular))
                    .foregroundStyle(recording ? accent : Theme.primaryText)
                Text(scope.title)
                    .font(.system(size: 13, weight: .bold))
                Text(subtitle(scope))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .foregroundStyle(Theme.primaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .innerCard()
        .notchHover(scale: 1.03)
    }

    // MARK: - Recording (full-screen Stop screen)

    /// Full-tab Stop screen shown while a full-screen recording runs — one big
    /// target plus a live elapsed readout, ringed in red so it's unmistakable.
    private var recordingScreen: some View {
        Button {
            recorder.stopRecording()
        } label: {
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color(hex: "FF453A") ?? .red)
                        .frame(width: 86, height: 86)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.white)
                        .frame(width: 30, height: 30)
                }
                .blackGlass(in: Circle(), interactive: true)

                elapsedLabel

                Text("Stop Recording")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .innerCard()
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous)
                .strokeBorder(Color(hex: "FF453A") ?? .red, lineWidth: 2)
        }
        .notchHover(scale: 1.02)
    }

    /// Live MM:SS since the recording began, with a pulsing REC label above it.
    private var elapsedLabel: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let elapsed = recorder.startDate.map { ctx.date.timeIntervalSince($0) } ?? 0
            VStack(spacing: 3) {
                HStack(spacing: 5) {
                    PulseDot(color: Color(hex: "FF453A") ?? .red, diameter: 7)
                    Text("REC")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(Color(hex: "FF453A") ?? .red)
                }
                Text(Self.clock(elapsed))
                    .font(.system(size: 22, weight: .bold).monospacedDigit())
                    .foregroundStyle(Theme.primaryText)
            }
        }
    }

    private static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
