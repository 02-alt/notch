import SwiftUI
import AppKit

/// Now-playing tab — an *immersive* player: the album art fills the whole surface,
/// blurred and darkened, with the crisp cover, metadata and transport floating on
/// top. The scrubber and the prominent play button pick up the artwork's dominant
/// colour (falling back to the user accent), so the panel visibly "recolours" for
/// each track.
struct MediaTabView: View {
    @EnvironmentObject private var np: NowPlayingManager
    @EnvironmentObject private var settings: SettingsStore

    /// Dominant colour pulled from the current artwork; nil until computed / when
    /// there's no art. Drives the scrubber fill and the play-button glow.
    @State private var cover: Color?

    /// The live tint: the album colour when we have one, else the user's accent.
    private var tint: Color { cover ?? settings.accent }

    /// On the Liquid Glass theme we let the panel's Siri-glass hood be the player's
    /// surface — no opaque card — so the desktop refracts through and the album colour
    /// blooms *into* the glass. Every other theme keeps the immersive album card.
    private var isGlass: Bool { settings.panelTheme == .glass }

    var body: some View {
        ZStack {
            if !isGlass {
                backdrop
                // The smoked "black Liquid Glass" surface, laid over the immersive album
                // backdrop: the artwork lenses faintly through the glass (like the
                // wallpaper behind Apple's Siri overlay) while the card reads as deep
                // black glass with a light-catching rim.
                Color.clear.blackGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            // On the Liquid Glass theme the player sits *directly* on the panel's Siri
            // hood — no album bloom, no floor gradient, no inset frosted card behind it.
            // The hood is opaque black up top and fully clear at the bottom, so the
            // player reads as content floating on real glass with a 100% transparent
            // lower edge, exactly like the iPhone Siri overlay.
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Picture-in-Picture (browser video only) floats in the corner so it never
        // unbalances the symmetric control row.
        .overlay(alignment: .topTrailing) {
            if np.supportsPiP {
                Button { np.togglePiP() } label: {
                    Image(systemName: "pip.enter")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .blackGlass(in: Circle(), interactive: true)
                .linkCursor()
                .help("Picture in Picture")
                .padding(Spacing.md)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        // Recompute the palette whenever the artwork changes (new track).
        .task(id: np.artwork) { cover = np.artwork.flatMap(AlbumPalette.dominant) }
        .animation(.easeInOut(duration: 0.5), value: cover)
    }

    // MARK: - Immersive backdrop

    @ViewBuilder
    private var backdrop: some View {
        ZStack {
            if let image = np.artwork {
                // Full-bleed, heavily blurred cover — the immersive layer.
                Color.clear
                    .overlay {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .blur(radius: 40, opaque: true)
                            .scaleEffect(1.2) // hide the blurred edge feathering
                    }
                    .clipped()
            } else {
                // No art: a soft wash of the tint so the panel still feels alive.
                LinearGradient(
                    colors: [tint.opacity(0.5), Color.black],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }

            // Legibility scrim: darken overall, then deepen toward the left where the
            // title sits and along the bottom under the transport row.
            Color.black.opacity(0.34)
            LinearGradient(
                colors: [.black.opacity(0.55), .clear],
                startPoint: .leading, endPoint: .center
            )
            LinearGradient(
                colors: [.clear, .black.opacity(0.45)],
                startPoint: .center, endPoint: .bottom
            )
        }
    }

    // MARK: - Foreground content

    private var content: some View {
        HStack(alignment: .top, spacing: Spacing.lg) {
            // Left column: the cover, with the running-source chips tucked into the
            // space beneath it (freed up now that the cover top-aligns to the title).
            if settings.showArtwork || np.runningSources.count > 1 {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    if settings.showArtwork { artwork }
                    sourcePicker
                    Spacer(minLength: 0)
                }
                .frame(width: settings.showArtwork ? 108 : nil, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(np.title.uppercased())
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.5), radius: 4, y: 1)

                Text(np.artist.isEmpty ? "—" : np.artist)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.5), radius: 4, y: 1)

                Spacer(minLength: 6)

                if np.isLive {
                    liveIndicator
                } else {
                    Scrubber(tint: tint)

                    HStack {
                        Text(Self.time(np.position))
                        Spacer()
                        Text(Self.time(np.duration))
                    }
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                }

                Spacer(minLength: 2)

                controls
            }
        }
        .padding(Spacing.lg)
    }

    /// The crisp cover floating over its own blur, with a soft drop shadow so it
    /// lifts off the backdrop.
    private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.06))
            if let image = np.artwork {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(width: 108, height: 108)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.45), radius: 12, y: 5)
    }

    /// Replaces the scrubber + time row for live streams: a pulsing red "LIVE" badge
    /// (there's nothing to seek), with the elapsed listening time trailing when known.
    private var liveIndicator: some View {
        HStack(spacing: Spacing.sm) {
            LivePulse()
            Text("LIVE")
                .font(.system(size: 11, weight: .heavy))
                .tracking(1.5)
                .foregroundStyle(.white)
            Spacer(minLength: 6)
            if np.position > 0 {
                Text(Self.time(np.position))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
        .frame(height: 14)
    }

    /// The transport row: previous / play / next kept tight in the centre (like Apple
    /// Music), with the volume glyph out at the right edge. The source pickers now live
    /// under the cover, so this row is just about playback.
    private var controls: some View {
        ZStack {
            HStack(spacing: Spacing.lg) {
                if !np.isLive {
                    TransportButton(symbol: "backward.fill", diameter: 30, accent: tint) { np.previous() }
                        .disabled(!np.hasTrack).opacity(np.hasTrack ? 1 : 0.4)
                }
                TransportButton(symbol: np.isPlaying ? "pause.fill" : "play.fill",
                                diameter: 42, prominent: true, accent: tint) { np.playPause() }
                    .disabled(!np.hasTrack).opacity(np.hasTrack ? 1 : 0.4)
                if !np.isLive {
                    TransportButton(symbol: "forward.fill", diameter: 30, accent: tint) { np.next() }
                        .disabled(!np.hasTrack).opacity(np.hasTrack ? 1 : 0.4)
                }
            }
            // Volume pinned to the right without shifting the centred transport.
            HStack {
                Spacer()
                volumeControl
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The running-source pickers, tucked under the cover: one app-icon chip per open
    /// player (Music, Spotify, a browser…), the active one highlighted — tap to switch.
    /// Only shown when more than one player is open (nothing to pick between otherwise).
    @ViewBuilder private var sourcePicker: some View {
        if np.runningSources.count > 1 {
            HStack(spacing: Spacing.sm) {
                ForEach(np.runningSources, id: \.self) { src in
                    SourceChip(source: src, isActive: np.activeSource == src, accent: tint) {
                        np.select(src)
                    }
                }
            }
        }
    }

    /// Far-right glyph: the volume speaker. Click toggles mute; hovering reveals a
    /// slim slider just above it for fine control (kept off the row so it stays tidy).
    @ViewBuilder private var volumeControl: some View {
        if np.supportsVolume {
            VolumeButton(tint: tint)
        } else {
            Color.clear.frame(width: 30, height: 30)
        }
    }

    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Extracts a pleasing "dominant" colour from album art. Downsamples the image to a
/// tiny grid, then averages the pixels weighted toward the more saturated ones (so a
/// vivid accent wins over a large muddy/grey background), and normalises the result
/// to a vibrant-but-not-blown tint suitable for the scrubber and glow.
enum AlbumPalette {
    static func dominant(from image: NSImage) -> Color? {
        let side = 16
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 4 * side, bitsPerPixel: 32
        ) else { return nil }

        let ctx = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
                   from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.bitmapData else { return nil }

        var rSum = 0.0, gSum = 0.0, bSum = 0.0, wSum = 0.0
        for i in stride(from: 0, to: side * side * 4, by: 4) {
            let r = Double(data[i]) / 255
            let g = Double(data[i + 1]) / 255
            let b = Double(data[i + 2]) / 255
            let mx = max(r, g, b), mn = min(r, g, b)
            let sat = mx <= 0 ? 0 : (mx - mn) / mx
            // Weight by saturation (+ a floor) so colourful pixels dominate but a
            // fully greyscale cover still yields its average grey.
            let w = sat * sat + 0.05
            rSum += r * w; gSum += g * w; bSum += b * w; wSum += w
        }
        guard wSum > 0 else { return nil }

        let ns = NSColor(red: rSum / wSum, green: gSum / wSum, blue: bSum / wSum, alpha: 1)
            .usingColorSpace(.deviceRGB) ?? .gray
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &v, alpha: nil)
        // Normalise to a lively tint: ensure enough saturation and a mid-high value.
        let color = NSColor(hue: h,
                            saturation: min(max(s, 0.45), 0.9),
                            brightness: min(max(v, 0.6), 0.85),
                            alpha: 1)
        return Color(color)
    }
}

/// A tappable app-icon chip used to pick which media app drives playback — shown in
/// a small row under the cover when more than one player is running.
private struct SourceChip: View {
    let source: MediaSource
    let isActive: Bool
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let icon = source.appIcon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "music.note")
                        .resizable().scaledToFit()
                        .foregroundStyle(.white).padding(Spacing.xs)
                }
            }
            .frame(width: 18, height: 18)
            .padding(Spacing.s)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .blackGlass(
            in: Circle(),
            interactive: true, tint: isActive ? accent.opacity(0.6) : nil
        )
        .overlay {
            if isActive {
                Circle().strokeBorder(accent, lineWidth: 1.5)
            }
        }
        .opacity(isActive ? 1 : 0.6)
        .linkCursor()
        .help("Play from \(source.rawValue)")
    }
}

/// The pulsing red dot that fronts the "LIVE" badge — a broadcast-style beacon that
/// breathes so a live stream reads as live at a glance.
private struct LivePulse: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            // Reduce Motion: a steady dot — still reads as "live", but doesn't breathe.
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .shadow(color: .red.opacity(0.6), radius: 3)
        } else {
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let pulse = 0.5 + 0.5 * sin(t * 3.2)
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .scaleEffect(0.8 + 0.2 * pulse)
                    .opacity(0.6 + 0.4 * pulse)
                    .shadow(color: .red.opacity(0.7 * pulse), radius: 4)
            }
            .frame(width: 8, height: 8)
        }
    }
}

/// The far-right volume glyph: a mute-toggle speaker whose waves track the level.
/// A slim draggable slider (tinted to the album colour) reveals just above it on
/// hover, so fine control is available without widening the symmetric control row.
private struct VolumeButton: View {
    @EnvironmentObject private var np: NowPlayingManager
    let tint: Color
    /// Level to restore when un-muting via the speaker glyph.
    @State private var preMute: Double = 0.5
    /// Hover is tracked on both the glyph and the popover (which sit flush) so moving
    /// the pointer from one to the other keeps the slider up.
    @State private var overGlyph = false
    @State private var overSlider = false
    private var shown: Bool { overGlyph || overSlider }

    private var symbol: String {
        if np.volume <= 0.001 { return "speaker.slash.fill" }
        if np.volume < 0.34   { return "speaker.wave.1.fill" }
        if np.volume < 0.67   { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    var body: some View {
        Button {
            if np.volume > 0.001 { preMute = np.volume; np.setVolume(0) }
            else { np.setVolume(preMute > 0.02 ? preMute : 0.5) }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .blackGlass(in: Circle(), interactive: true)
        .linkCursor()
        .help(np.volume > 0.001 ? "Mute" : "Unmute")
        .onHover { overGlyph = $0 }
        .overlay(alignment: .bottom) {
            VolumeSlider(tint: tint)
                .frame(width: 96, height: 14)
                .padding(.horizontal, Spacing.base)
                .padding(.vertical, Spacing.sm)
                .background(Capsule(style: .continuous).fill(Color.black.opacity(0.82)))
                .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                .fixedSize()
                // Sits flush on top of the glyph so the pointer can cross into it.
                .offset(y: -30)
                .opacity(shown ? 1 : 0)
                .allowsHitTesting(shown)
                .onHover { overSlider = $0 }
        }
        .animation(.easeOut(duration: 0.14), value: shown)
        .zIndex(shown ? 10 : 0)
    }
}

/// A slim horizontal volume slider bound to the now-playing volume. Fattens and
/// reveals a knob on hover; drag anywhere to set the level.
private struct VolumeSlider: View {
    @EnvironmentObject private var np: NowPlayingManager
    let tint: Color
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let p = min(max(np.volume, 0), 1)
            let h: CGFloat = hovering ? 6 : 4
            let knob = h + 5

            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.22)).frame(height: h)
                Capsule().fill(tint).frame(width: w * p, height: h)
                Circle()
                    .fill(.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.4), radius: 1.5)
                    .offset(x: min(max(w * p - knob / 2, 0), w - knob))
                    .opacity(hovering ? 1 : 0)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: hovering)
            .onHover { hovering = $0 }
            .pointerStyle(.grabIdle)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        np.beginVolumeAdjust()
                        np.setVolume(min(max(value.location.x / w, 0), 1))
                    }
                    .onEnded { value in
                        np.setVolume(min(max(value.location.x / w, 0), 1))
                        np.endVolumeAdjust()
                    }
            )
        }
        .frame(height: 14)
        .grabsWindowKeyForDrag()
    }
}

private struct TransportButton: View {
    let symbol: String
    let diameter: CGFloat
    var prominent: Bool = false
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: diameter * 0.42, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .blackGlass(
            in: Circle(),
            interactive: true, tint: prominent ? accent.opacity(0.7) : nil
        )
        // The play/pause button glows in the album colour so it reads as the hero.
        .shadow(color: prominent ? accent.opacity(0.6) : .clear, radius: 10)
        .linkCursor()
    }
}

/// Draggable progress bar bound to the now-playing position, tinted to `tint`.
///
/// When the source exposes chapters (YouTube), it renders as a row of rounded
/// "chapter pills" separated by small gaps — the played chapters filled in `tint`,
/// the rest dimmed, with a white playhead. Otherwise it's a single continuous bar.
private struct Scrubber: View {
    @EnvironmentObject private var np: NowPlayingManager
    let tint: Color
    /// Fattens the bar and shows the playhead while the pointer is over it.
    @State private var hovering = false
    /// Pointer x within the bar while hovering (nil when off it).
    @State private var hoverX: CGFloat?
    /// Pointer x while actively dragging the playhead (nil when not dragging).
    @State private var dragX: CGFloat?

    private let gap: CGFloat = 3

    private var chaptered: Bool { np.chapters.count > 1 }

    /// The x we key the chapter tooltip off: the drag position while scrubbing,
    /// otherwise the hover position. Nil hides the tooltip.
    private var activeX: CGFloat? { dragX ?? (hovering ? hoverX : nil) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let dur = max(np.duration, 0.001)
            // While dragging, the playhead tracks the finger from the drag-local `dragX`
            // — we don't write `np.position` every frame (that re-evaluated the whole
            // media tab, blur backdrop and all). The real seek is committed on release.
            let progress = dragX.map { min(max($0 / w, 0), 1) }
                ?? min(max(np.position / dur, 0), 1)
            let h: CGFloat = hovering ? 7 : 5

            ZStack(alignment: .leading) {
                if chaptered {
                    chapterBar(width: w, dur: dur, progress: progress, height: h)
                } else {
                    plainBar(width: w, progress: progress, height: h)
                }

                // Ghost marker at the cursor while hovering (before you commit), so
                // it's clear where a click or drag will seek to. Hidden once you grab
                // the playhead, since the real playhead then tracks the drag itself.
                if dragX == nil, hovering, let x = hoverX {
                    Capsule()
                        .fill(.white.opacity(0.5))
                        .frame(width: 2, height: h + 8)
                        .offset(x: min(max(x - 1, 0), w - 2))
                        .allowsHitTesting(false)
                }

                // White playhead marker, like the reference. Always shown for
                // chaptered timelines (so segment boundaries read clearly), and on
                // hover for the plain bar.
                Capsule()
                    .fill(.white)
                    .frame(width: 3, height: h + 6)
                    .shadow(color: .black.opacity(0.45), radius: 1.5)
                    .offset(x: min(max(progress * w - 1.5, 0), w - 3))
                    .opacity(chaptered || hovering ? 1 : 0)
            }
            // Scrub readout — floats just above the bar, tracking the cursor while
            // hovering the timeline or dragging the playhead. Shows the exact time
            // you'd seek to (for every video), plus the chapter name when the source
            // exposes chapters.
            .overlay(alignment: .topLeading) {
                if let x = activeX {
                    let t = Double(min(max(x / w, 0), 1)) * dur
                    let info = chaptered ? chapterInfo(atX: x, width: w, dur: dur) : nil
                    ScrubTooltip(
                        chapter: info.map { $0.chapter.title.isEmpty ? "Chapter \($0.index + 1)" : $0.chapter.title },
                        time: MediaTabView.time(t)
                    )
                    .position(x: min(max(x, 66), w - 66), y: -16)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: hovering)
            .animation(.easeOut(duration: 0.12), value: activeX)
            .onHover { hovering = $0 }
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let p): hoverX = p.x
                case .ended:         hoverX = nil
                }
            }
            .pointerStyle(.grabIdle)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard np.duration > 0 else { return }
                        np.beginScrub()   // freeze the playhead; no per-frame position write
                        dragX = value.location.x
                    }
                    .onEnded { value in
                        guard np.duration > 0 else { dragX = nil; return }
                        np.endScrub(at: min(max(value.location.x / w, 0), 1) * np.duration)
                        dragX = nil
                    }
            )
        }
        // A taller strip than the ~5–7pt visual bar, so the thin timeline is still
        // easy to grab and drag.
        .frame(height: 18)
        // The panel is non-activating; without this the drag wouldn't track (see
        // `grabsWindowKeyForDrag`).
        .grabsWindowKeyForDrag()
    }

    /// The chapter (and its index) under a given x on the bar.
    private func chapterInfo(atX x: CGFloat, width: CGFloat, dur: Double) -> (index: Int, chapter: MediaChapter)? {
        let chs = np.chapters
        guard !chs.isEmpty, width > 0, dur > 0 else { return nil }
        let t = Double(min(max(x / width, 0), 1)) * dur
        var idx = 0
        for (i, c) in chs.enumerated() {
            if c.start <= t + 0.001 { idx = i } else { break }
        }
        return (idx, chs[idx])
    }

    // MARK: - Plain

    private func plainBar(width: CGFloat, progress: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.22))
            Capsule().fill(tint).frame(width: width * progress)
        }
        .frame(height: height)
    }

    // MARK: - Chaptered

    private func chapterBar(width: CGFloat, dur: Double, progress: CGFloat, height: CGFloat) -> some View {
        // Chapter starts plus the track end give each segment's [start, end).
        let bounds = np.chapters.map(\.start) + [dur]
        return ZStack(alignment: .leading) {
            segments(bounds: bounds, dur: dur, width: width, height: height,
                     color: Color.white.opacity(0.22))
            segments(bounds: bounds, dur: dur, width: width, height: height, color: tint)
                .mask(alignment: .leading) {
                    Rectangle().frame(width: max(0, width * progress))
                }
        }
    }

    private func segments(bounds: [Double], dur: Double, width: CGFloat,
                          height: CGFloat, color: Color) -> some View {
        // Precompute each segment's x/width so ForEach iterates a stable collection
        // (a dynamic Range in ForEach is undefined behaviour in SwiftUI).
        let segs: [ChapterSegment] = (0..<(bounds.count - 1)).map { i in
            let start = bounds[i], end = bounds[i + 1]
            return ChapterSegment(
                id: i,
                x: CGFloat(start / dur) * width,
                width: max(2, CGFloat((end - start) / dur) * width - gap)
            )
        }
        return ZStack(alignment: .leading) {
            ForEach(segs) { seg in
                Capsule()
                    .fill(color)
                    .frame(width: seg.width, height: height)
                    .offset(x: seg.x)
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }
}

/// One chapter segment's laid-out geometry.
private struct ChapterSegment: Identifiable {
    let id: Int
    let x: CGFloat
    let width: CGFloat
}

/// The little floating label above the scrubber while you hover or drag it. Always
/// names the exact time you'd seek to; also names the chapter under the cursor when
/// the video is chaptered.
private struct ScrubTooltip: View {
    /// Chapter name under the cursor, when the video exposes chapters. Nil → time only.
    let chapter: String?
    let time: String

    var body: some View {
        HStack(spacing: Spacing.s) {
            if let chapter {
                Text(chapter)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text(time)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                Text(time)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.s)
        .background {
            Capsule(style: .continuous).fill(Color.black.opacity(0.8))
        }
        .overlay {
            Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
        .fixedSize()
    }
}
