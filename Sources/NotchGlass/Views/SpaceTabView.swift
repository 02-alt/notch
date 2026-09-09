import SwiftUI

/// The **Space** tab: a single full-bleed live world map (see ``LiveMapCard``) with
/// the ISS's real-time ground track, a gliding marker, its visibility footprint, the
/// observer's location, the next-pass countdown and live telemetry.
///
/// Everything is computed locally from the ISS orbit by ``ISSPassManager`` /
/// ``SGP4``; the only network call is fetching the public TLE, and — like the
/// weather tab — the user's coordinate is never sent anywhere.
struct SpaceTabView: View {
    @StateObject private var location = LocationManager()
    @ObservedObject private var iss = ISSPassManager.shared

    /// Space palette — a fixed cyan that reads as sky, independent of the app accent.
    static let sky = Color(red: 0.35, green: 0.85, blue: 1.0)

    private var coordinateKey: String {
        guard let c = location.location?.coordinate else { return "none" }
        return String(format: "%.2f,%.2f", c.latitude, c.longitude)
    }

    var body: some View {
        Group {
            if let c = location.location?.coordinate {
                LiveMapCard(pass: iss.nextPass, now: iss.now, track: iss.track,
                            observerLatitude: c.latitude, observerLongitude: c.longitude,
                            isLoading: iss.isLoading, error: iss.errorText)
                    .task(id: coordinateKey) {
                        await iss.load(latitude: c.latitude, longitude: c.longitude)
                    }
            } else if location.authorization == .denied || location.authorization == .restricted {
                message("Space needs your location", "Enable Location Services to predict ISS passes overhead.",
                        symbol: "location.slash")
            } else {
                message("Finding your location…", "Passes are predicted for where you are.",
                        symbol: "location", loading: true)
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .onAppear { location.request(); location.start() }
        .onDisappear { location.stop() }
        // Keep the live "now" dot and ground point ticking while the tab is open.
        .task {
            while !Task.isCancelled {
                if let c = location.location?.coordinate {
                    iss.refreshNow(latitude: c.latitude, longitude: c.longitude)
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func message(_ title: String, _ subtitle: String, symbol: String,
                         loading: Bool = false) -> some View {
        VStack(spacing: 10) {
            if loading {
                ThinkingOrb(size: 34)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
            Text(title).font(.system(size: 15, weight: .bold))
            Text(subtitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

// MARK: - Bundled space imagery

/// The Space tab's photographic assets, loaded once from the app's own Resources
/// (`Contents/Resources/space`, copied there by `build-app.sh`) via `Bundle.main` —
/// the same approach as the ambience audio, and deliberately NOT `Bundle.module`,
/// whose generated accessor hard-fails inside a packaged `.app`. `nil` when the
/// image isn't bundled (e.g. a bare `swift run`), so callers fall back gracefully.
enum SpaceAsset {
    /// NASA Blue Marble equirectangular (Plate Carrée) world map — public domain.
    /// The whole globe: left edge −180° lon, right +180°, top +90° lat, bottom −90°,
    /// so a point maps linearly onto it.
    static let worldMap: Image? = load("worldmap", "jpg")
    /// Bold ISS station icon (drawn, transparent) — the marker that rides the track;
    /// legible at map scale where a photo would read as a grey lattice.
    static let iss: Image? = load("iss", "png")

    private static func load(_ name: String, _ ext: String) -> Image? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "space"),
              let img = NSImage(contentsOf: url) else { return nil }
        return Image(nsImage: img)
    }
}

// MARK: - Hero: the live world map

/// The ISS's live position on a NASA world map: its ground track for the current
/// orbit (dim behind, bright ahead), a glowing marker that glides as the position
/// refreshes, a faint "footprint" of where it's above the horizon, and a small ring
/// for the observer. The next-pass countdown sits top-right and live telemetry
/// (altitude, ground speed, sunlit/eclipsed) runs along the bottom. A deep-space
/// gradient stands in if the map image isn't bundled.
private struct LiveMapCard: View {
    let pass: ISSPass?
    let now: ISSNow?
    let track: [SubPoint]
    let observerLatitude: Double
    let observerLongitude: Double
    let isLoading: Bool
    let error: String?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let r = Self.mapRect(in: size)
            ZStack {
                map(size)
                Canvas { ctx, _ in
                    Self.drawFootprint(ctx, r: r, now: now)
                    Self.drawTrack(ctx, r: r, track: track)
                    Self.drawObserver(ctx, r: r, lat: observerLatitude, lon: observerLongitude)
                }
                marker(r)
                scrim
                overlay
                if now == nil { statusNote }
            }
            .frame(width: size.width, height: size.height)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        }
    }

    // MARK: Layers

    @ViewBuilder private func map(_ size: CGSize) -> some View {
        if let world = SpaceAsset.worldMap {
            world.resizable().scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()
                .saturation(1.05)
        } else {
            LinearGradient(colors: [Color(red: 0.05, green: 0.08, blue: 0.16),
                                    Color(red: 0.02, green: 0.03, blue: 0.06)],
                           startPoint: .top, endPoint: .bottom)
        }
    }

    /// The live ISS — a bold station icon (solar-array wings + body) that reads at
    /// map scale where a photo turns into a grey lattice. A faint dark halo lifts it
    /// off bright land and a cyan glow marks it as live; it eases to each new position
    /// over the ~3 s refresh so it glides rather than teleports. Falls back to a
    /// glowing dot if the icon isn't bundled.
    @ViewBuilder private func marker(_ r: CGRect) -> some View {
        if let now {
            let p = Self.project(lat: now.subLatitude, lon: now.subLongitude, in: r)
            Group {
                if let iss = SpaceAsset.iss {
                    ZStack {
                        Circle()
                            .fill(RadialGradient(
                                colors: [.black.opacity(0.45), .clear],
                                center: .center, startRadius: 2, endRadius: 34))
                            .frame(width: 68, height: 68)
                            .blur(radius: 1.5)
                        iss.resizable().scaledToFit()
                            .frame(width: 46)
                            .shadow(color: SpaceTabView.sky.opacity(0.85), radius: 6)
                    }
                } else {
                    ZStack {
                        Circle().fill(SpaceTabView.sky).frame(width: 11, height: 11)
                            .shadow(color: SpaceTabView.sky, radius: 8)
                        Circle().strokeBorder(.white, lineWidth: 1.5).frame(width: 11, height: 11)
                    }
                }
            }
            .position(p)
            .animation(.linear(duration: 3), value: p)
        }
    }

    private var scrim: some View {
        LinearGradient(stops: [
            .init(color: .black.opacity(0.55), location: 0.0),
            .init(color: .black.opacity(0.06), location: 0.28),
            .init(color: .black.opacity(0.10), location: 0.62),
            .init(color: .black.opacity(0.66), location: 1.0),
        ], startPoint: .top, endPoint: .bottom)
    }

    private var overlay: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: 0)
            bottomBar
        }
    }

    /// Shown until the first live position lands (or if the orbit feed failed).
    private var statusNote: some View {
        VStack(spacing: 8) {
            if isLoading || error == nil { ThinkingOrb(size: 28) }
            else {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            Text(error ?? "Acquiring orbit…")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
        }
        .padding(14)
        .background { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.45)) }
        .padding(20)
    }

    private var header: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("ISS · LIVE")
                        .font(.system(size: 9, weight: .bold)).kerning(0.6)
                        .foregroundStyle(.white.opacity(0.75))
                    Text(now?.isUp == true ? "Overhead you" : "Tracking")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                }
                Spacer(minLength: 0)
                if let pass {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(Self.countdown(pass, now: context.date))
                            .font(.system(size: 18, weight: .bold).monospacedDigit())
                            .foregroundStyle(pass.visible ? SpaceTabView.sky : .white)
                            // Tick the pass countdown with rolling digits.
                            .contentTransition(.numericText())
                            .animation(.snappy(duration: 0.3), value: Self.countdown(pass, now: context.date))
                        Text(pass.visible ? "next visible pass" : "next pass")
                            .font(.system(size: 8.5, weight: .semibold)).kerning(0.3)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            .shadow(color: .black.opacity(0.7), radius: 4, y: 1)
            .padding(.horizontal, 14)
            .padding(.top, 12)
        }
    }

    @ViewBuilder private var bottomBar: some View {
        if let now {
            HStack(spacing: 6) {
                chip("\(Int(now.altitudeKm.rounded())) km", "arrow.up.to.line")
                chip(Self.speed(now.speedKmh), "gauge.with.dots.needle.67percent")
                Spacer(minLength: 0)
                chip(now.sunlit ? "Sunlit" : "In shadow",
                     now.sunlit ? "sun.max.fill" : "moon.fill")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    private func chip(_ text: String, _ symbol: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold))
            Text(text).font(.system(size: 10, weight: .bold).monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background { Capsule().fill(Color.black.opacity(0.55)) }
        .overlay { Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1) }
        .fixedSize()
    }

    // MARK: Projection & drawing

    /// The rectangle the equirectangular map fills (aspect-fill, centred) — the same
    /// crop SwiftUI's `.scaledToFill` produces, so overlay coordinates line up.
    private static func mapRect(in size: CGSize) -> CGRect {
        var w = size.width, h = size.width / 2   // image is 2:1
        if h < size.height { h = size.height; w = size.height * 2 }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private static func project(lat: Double, lon: Double, in r: CGRect) -> CGPoint {
        CGPoint(x: r.minX + CGFloat((lon + 180) / 360) * r.width,
                y: r.minY + CGFloat((90 - lat) / 180) * r.height)
    }

    /// The ground track, split wherever it wraps the ±180° meridian, with the past
    /// stretch dim and the stretch still to come lit.
    private static func drawTrack(_ ctx: GraphicsContext, r: CGRect, track: [SubPoint]) {
        guard track.count > 1 else { return }
        func stroke(_ pts: [SubPoint], color: Color, width: CGFloat) {
            guard pts.count > 1 else { return }
            var path = Path()
            path.move(to: project(lat: pts[0].latitude, lon: pts[0].longitude, in: r))
            for i in 1..<pts.count {
                let a = pts[i - 1], b = pts[i]
                let raw = b.longitude - a.longitude
                if abs(raw) <= 180 {
                    path.addLine(to: project(lat: b.latitude, lon: b.longitude, in: r))
                } else {
                    // Wrapped the ±180° meridian: run out to the edge on a's side, then
                    // continue in from the opposite edge, both at the crossing latitude,
                    // so the track stays continuous instead of breaking mid-map.
                    let bUn = raw > 180 ? b.longitude - 360 : b.longitude + 360
                    let edgeLon: Double = bUn > 180 ? 180 : -180
                    let f = (edgeLon - a.longitude) / (bUn - a.longitude)
                    let latC = a.latitude + (b.latitude - a.latitude) * f
                    path.addLine(to: project(lat: latC, lon: edgeLon, in: r))
                    path.move(to: project(lat: latC, lon: -edgeLon, in: r))
                    path.addLine(to: project(lat: b.latitude, lon: b.longitude, in: r))
                }
            }
            ctx.stroke(path, with: .color(color),
                       style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        }
        // Dark under-stroke first, so the track stays legible over bright land as
        // well as dark ocean; then the cyan line on top. Overlap the past/future
        // halves at now (m≈0) so they join seamlessly.
        let past = track.filter { $0.minutesFromNow <= 0.01 }
        let future = track.filter { $0.minutesFromNow >= -0.01 }
        stroke(past,   color: .black.opacity(0.45), width: 4)
        stroke(future, color: .black.opacity(0.5),  width: 4.5)
        stroke(past,   color: SpaceTabView.sky.opacity(0.55), width: 1.6)
        stroke(future, color: SpaceTabView.sky,               width: 2.2)
    }

    /// A faint ellipse for the ISS's visibility footprint (roughly where it sits above
    /// the horizon). Equirectangular stretches east–west with latitude, so widen the
    /// horizontal radius by 1/cos(lat).
    private static func drawFootprint(_ ctx: GraphicsContext, r: CGRect, now: ISSNow?) {
        guard let now else { return }
        let radiusDeg = 20.0   // central angle to the visibility horizon, ~ for 420 km
        let c = project(lat: now.subLatitude, lon: now.subLongitude, in: r)
        let ry = CGFloat(radiusDeg / 180) * r.height
        let cosLat = max(0.35, cos(now.subLatitude * .pi / 180))
        let rx = min(CGFloat(radiusDeg / cosLat / 360) * r.width, r.width * 0.45)
        let rect = CGRect(x: c.x - rx, y: c.y - ry, width: 2 * rx, height: 2 * ry)
        ctx.fill(Path(ellipseIn: rect), with: .color(SpaceTabView.sky.opacity(0.12)))
        ctx.stroke(Path(ellipseIn: rect), with: .color(SpaceTabView.sky.opacity(0.35)), lineWidth: 1)
    }

    /// A small hollow ring marking the observer's own location for context.
    private static func drawObserver(_ ctx: GraphicsContext, r: CGRect, lat: Double, lon: Double) {
        let p = project(lat: lat, lon: lon, in: r)
        let dot = CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)
        ctx.fill(Path(ellipseIn: dot), with: .color(.white))
        let ring = CGRect(x: p.x - 5.5, y: p.y - 5.5, width: 11, height: 11)
        ctx.stroke(Path(ellipseIn: ring), with: .color(.white.opacity(0.8)), lineWidth: 1.5)
    }

    // MARK: text helpers

    private static func speed(_ kmh: Double) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0
        return (f.string(from: NSNumber(value: kmh)) ?? "\(Int(kmh))") + " km/h"
    }

    private static func countdown(_ pass: ISSPass, now: Date) -> String {
        if now >= pass.rise && now <= pass.setTime { return "NOW" }
        let dt = pass.rise.timeIntervalSince(now)
        if dt <= 0 { return "—" }
        let m = Int(dt / 60)
        if m < 60 { return "in \(max(1, m)) min" }
        let h = m / 60, mm = m % 60
        return mm == 0 ? "in \(h)h" : "in \(h)h \(mm)m"
    }
}

