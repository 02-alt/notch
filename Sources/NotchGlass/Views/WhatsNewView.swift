import SwiftUI

/// The in-notch "What's New" card. Presented over the panel content the first time
/// it's opened after an update (and manually from Settings): a headline, the release
/// summary, a scrollable list of what changed, and a button to dismiss.
///
/// Pinned to a dark appearance and floated on a translucent card so it reads the same
/// on every panel theme — a small modal that pops rather than blending in.
struct WhatsNewView: View {
    let releases: [ReleaseNote]
    let onDismiss: () -> Void

    @EnvironmentObject private var settings: SettingsStore
    @State private var appeared = false

    private var accent: Color { settings.accent }

    /// The newest release drives the version badge / summary at the top; every
    /// release's changes are listed below (usually just the one).
    private var headline: ReleaseNote? { releases.first }

    var body: some View {
        ZStack {
            // Dim, frosted backdrop — click anywhere outside the card to dismiss.
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.4))
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            card
                .scaleEffect(appeared ? 1 : 0.92)
                .opacity(appeared ? 1 : 0)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
        .environment(\.colorScheme, .dark)
        .onExitCommand { onDismiss() }
        .onAppear {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) { appeared = true }
        }
    }

    private var card: some View {
        VStack(spacing: 14) {
            header

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    ForEach(releases) { release in
                        ForEach(release.changes) { change in
                            changeRow(change)
                        }
                    }
                }
                .padding(.horizontal, 2)
            }

            Button(action: onDismiss) {
                Text("Continue")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(accent.readableForeground)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Capsule(style: .continuous).fill(accent))
            .linkCursor()
        }
        .padding(18)
        .frame(maxWidth: 380)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(white: 0.10))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(accent)
                    Text("What's New")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(.white)
                }
                Spacer()
                if let v = headline?.version {
                    Text("Version \(v)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(accent.opacity(0.25)))
                        .overlay(Capsule().strokeBorder(accent.opacity(0.5), lineWidth: 1))
                }
            }
            if let summary = headline?.summary {
                Text(summary)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func changeRow(_ change: ReleaseChange) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: change.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(accent.opacity(0.16)))
            VStack(alignment: .leading, spacing: 2) {
                Text(change.title)
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(.white)
                Text(change.detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(0.05)))
    }
}
