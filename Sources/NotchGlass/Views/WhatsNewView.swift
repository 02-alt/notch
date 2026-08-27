import SwiftUI

/// The in-notch "What's New" release notes. Rendered as the panel's own content
/// (like Settings) — welded into the notch, with the body grown to fit the whole
/// list — rather than a floating card. Shown on the first panel open after an
/// update (and manually from Settings): a headline, the release summary, the list
/// of what changed, and a button to dismiss.
struct WhatsNewView: View {
    let releases: [ReleaseNote]
    let onDismiss: () -> Void

    @EnvironmentObject private var settings: SettingsStore

    private var accent: Color { settings.accent }

    /// The newest release drives the version badge / summary; every release's
    /// changes are listed below (usually just the one).
    private var headline: ReleaseNote? { releases.first }

    var body: some View {
        VStack(spacing: Spacing.base) {
            header

            // Sized to fit by the panel body, so this normally shows every row
            // without scrolling; the ScrollView is only a safety net for an
            // unusually long release.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: Spacing.md) {
                    ForEach(releases) { release in
                        ForEach(release.changes) { change in
                            changeRow(change)
                        }
                    }
                }
                .padding(.horizontal, Spacing.hair)
            }

            Button(action: onDismiss) {
                Text("Continue")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(accent.readableForeground)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.base)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Capsule(style: .continuous).fill(accent))
            .linkCursor()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // White-on-dark card, matched to the dark panel surface (a dark stage is
        // added under it on the Light theme by the caller).
        .environment(\.colorScheme, .dark)
        .onExitCommand { onDismiss() }
    }

    private var header: some View {
        VStack(spacing: Spacing.sm) {
            HStack {
                HStack(spacing: Spacing.s) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(accent)
                    Text("What's New")
                        .font(.system(size: 17, weight: .heavy))
                        .foregroundStyle(.white)
                }
                Spacer()
                if let v = headline?.version {
                    Text("Version \(v)")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, Spacing.md).padding(.vertical, Spacing.xs)
                        .background(Capsule().fill(accent.opacity(0.25)))
                        .overlay(Capsule().strokeBorder(accent.opacity(0.5), lineWidth: 1))
                }
            }
            if let summary = headline?.summary {
                Text(summary)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func changeRow(_ change: ReleaseChange) -> some View {
        HStack(alignment: .top, spacing: Spacing.base) {
            Image(systemName: change.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(accent.opacity(0.16)))
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(change.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                Text(change.detail)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.base)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
    }
}
