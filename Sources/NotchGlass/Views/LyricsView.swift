import SwiftUI

/// The synced, auto-scrolling lyrics view embedded *inside the Media tab* (so the
/// player and its lyrics live on one surface — no tab-flipping). It reads the app-wide
/// `NowPlayingManager` for the playhead and the shared `LyricsService` for the lyrics,
/// highlights and auto-scrolls the active line, and seeks the player when a line is
/// tapped. The glow is tinted by `tint` (the player's album colour) so it stays part
/// of the same now-playing surface.
struct LyricsView: View {
    @EnvironmentObject private var np: NowPlayingManager
    @EnvironmentObject private var lyrics: LyricsService

    /// The player's live tint (album colour, else accent), passed in so both the
    /// player controls and the lyrics glow recolour together.
    let tint: Color

    /// The line currently under the playhead, tracked in state so scrolling and the
    /// highlight animate on change rather than recomputing silently every tick.
    @State private var activeIndex: Int?

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Fetch on track change (works even when lyrics aren't pinned). Deduped by
            // track key, so it's a no-op when `AppDelegate` already fetched for a pin.
            .task(id: np.islandKey) { syncFetch() }
            .onChange(of: np.position) { _, pos in
                let idx = lyrics.activeIndex(at: pos)
                if idx != activeIndex { activeIndex = idx }
            }
            .onChange(of: lyrics.state) { _, _ in
                activeIndex = lyrics.activeIndex(at: np.position)
            }
    }

    private func syncFetch() {
        guard np.hasTrack else { return }
        lyrics.load(for: np)
    }

    @ViewBuilder
    private var content: some View {
        if !np.hasTrack {
            message("Play a song to see its lyrics", symbol: "music.note")
        } else {
            switch lyrics.state {
            case .idle, .loading:
                message("Finding lyrics…", symbol: "text.magnifyingglass", spin: true)
            case .synced(let lines):
                synced(lines)
            case .plain(let text):
                plain(text)
            case .instrumental:
                message("Instrumental", symbol: "music.quarternote.3")
            case .notFound:
                message("No lyrics found", symbol: "questionmark.circle")
            case .offline:
                message("Couldn't reach the lyrics service", symbol: "wifi.slash")
            }
        }
    }

    /// The synced, auto-scrolling karaoke view. Lines before the playhead are dimmed,
    /// the active line is bright and tinted, upcoming lines sit in between.
    private func synced(_ lines: [LyricLine]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    ForEach(lines.indices, id: \.self) { i in
                        lineRow(i: i, line: lines[i])
                            .id(i)
                    }
                }
                .padding(.vertical, Spacing.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: activeIndex) { _, idx in
                guard let idx else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
                    proxy.scrollTo(idx, anchor: .center)
                }
            }
        }
        .mask(
            // Feather the top/bottom edges so lines fade in and out rather than
            // clipping hard against the panel chrome.
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.14),
                .init(color: .black, location: 0.86),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        )
    }

    private func lineRow(i: Int, line: LyricLine) -> some View {
        let isActive = i == activeIndex
        let isPast = activeIndex.map { i < $0 } ?? false
        // Empty lines are instrumental gaps between verses — show a small pulse dot on
        // the active one instead of blank space.
        return Group {
            if line.text.isEmpty {
                Circle()
                    .fill(isActive ? tint : Color.white.opacity(0.3))
                    .frame(width: 6, height: 6)
                    .padding(.vertical, 2)
            } else {
                Text(line.text)
                    .font(.system(size: isActive ? 16 : 13,
                                  weight: isActive ? .bold : .semibold))
                    .foregroundStyle(isActive ? Color.white
                                     : Color.white.opacity(isPast ? 0.32 : 0.6))
                    .shadow(color: isActive ? tint.opacity(0.55) : .clear, radius: 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { np.endScrub(at: line.time) }   // tap a line to seek there
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isActive)
    }

    /// Untimed lyrics: no highlight to drive, so just present the text, scrollable.
    private func plain(_ text: String) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.7))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Spacing.sm)
        }
    }

    private func message(_ text: String, symbol: String, spin: Bool = false) -> some View {
        VStack(spacing: Spacing.s) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.5))
                .symbolEffect(.pulse, isActive: spin)
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
