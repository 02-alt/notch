import SwiftUI

// MARK: - Astronomy

/// Low-precision positions for the Sun and Moon, accurate to well under a degree —
/// plenty for drawing the day's sun/moon arc and finding sunrise/sunset, golden
/// hour, and the moon phase locally, with **no network call** (it's pure math on
/// the coordinate we already have).
///
/// One primitive does the work: `sunAltitude` / `moonAltitude` give a body's
/// elevation above the horizon at an absolute instant. Every rise/set/twilight
/// time is then found by *sampling* that across the day and interpolating the
/// horizon crossings — one well-understood formula to trust rather than a separate
/// closed form per event. Formulae: NOAA (Sun) and Schlyter (Moon).
enum Astronomy {
    private static let d2r = Double.pi / 180

    /// Days since the J2000.0 epoch (2000-01-01 12:00 UTC). 10957.5 = days from the
    /// Unix epoch to J2000.0.
    private static func days(_ date: Date) -> Double {
        date.timeIntervalSince1970 / 86400.0 - 10957.5
    }

    /// Greenwich mean sidereal time, degrees.
    private static func gmst(_ n: Double) -> Double {
        (280.46061837 + 360.98564736629 * n).truncatingRemainder(dividingBy: 360)
    }

    /// Sun: ecliptic longitude (deg) and equatorial right ascension / declination (deg).
    private static func sun(_ n: Double) -> (lambda: Double, ra: Double, dec: Double) {
        let L = 280.460 + 0.9856474 * n
        let g = (357.528 + 0.9856003 * n) * d2r
        let lambda = L + 1.915 * sin(g) + 0.020 * sin(2 * g)
        let lamR = lambda * d2r
        let eps = (23.439 - 0.0000004 * n) * d2r
        let ra = atan2(cos(eps) * sin(lamR), cos(lamR)) / d2r
        let dec = asin(sin(eps) * sin(lamR)) / d2r
        return (lambda.truncatingRemainder(dividingBy: 360), ra, dec)
    }

    /// Altitude (deg above horizon) of a body at the given RA/Dec, instant and place.
    private static func altitude(raDeg: Double, decDeg: Double, n: Double,
                                 latDeg: Double, lonDeg: Double) -> Double {
        let lst = gmst(n) + lonDeg
        var ha = (lst - raDeg).truncatingRemainder(dividingBy: 360)
        if ha < -180 { ha += 360 }; if ha > 180 { ha -= 360 }
        let haR = ha * d2r, latR = latDeg * d2r, decR = decDeg * d2r
        let s = sin(latR) * sin(decR) + cos(latR) * cos(decR) * cos(haR)
        return asin(max(-1, min(1, s))) / d2r
    }

    static func sunAltitude(_ date: Date, latitude: Double, longitude: Double) -> Double {
        let n = days(date)
        let s = sun(n)
        return altitude(raDeg: s.ra, decDeg: s.dec, n: n, latDeg: latitude, lonDeg: longitude)
    }

    static func moonAltitude(_ date: Date, latitude: Double, longitude: Double) -> Double {
        let m = moon(date)
        return altitude(raDeg: m.ra, decDeg: m.dec, n: days(date), latDeg: latitude, lonDeg: longitude)
    }

    /// Moon: ecliptic longitude (deg) and equatorial RA/Dec (deg). Schlyter's series
    /// with the leading longitude/latitude perturbations kept, so it's good to a few
    /// arc-minutes — comfortably enough for the arc and rise/set.
    private static func moon(_ date: Date) -> (lonDeg: Double, ra: Double, dec: Double) {
        let n = days(date)
        let dd = n + 1.5   // Schlyter epoch is 1999-12-31 00:00 UTC
        let N = (125.1228 - 0.0529538083 * dd) * d2r
        let inc = 5.1454 * d2r
        let w = (318.0634 + 0.1643573223 * dd) * d2r
        let a = 60.2666
        let e = 0.054900
        var M = ((115.3654 + 13.0649929509 * dd) * d2r).truncatingRemainder(dividingBy: 2 * .pi)
        var E = M + e * sin(M) * (1 + e * cos(M))
        for _ in 0..<3 { E -= (E - e * sin(E) - M) / (1 - e * cos(E)) }
        let xv = a * (cos(E) - e)
        let yv = a * sqrt(1 - e * e) * sin(E)
        let v = atan2(yv, xv)
        let r = sqrt(xv * xv + yv * yv)
        let xh = r * (cos(N) * cos(v + w) - sin(N) * sin(v + w) * cos(inc))
        let yh = r * (sin(N) * cos(v + w) + cos(N) * sin(v + w) * cos(inc))
        let zh = r * sin(v + w) * sin(inc)
        var lon = atan2(yh, xh) / d2r
        var lat = atan2(zh, sqrt(xh * xh + yh * yh)) / d2r

        // Leading perturbations (Sun angles).
        let Ls = (280.460 + 0.9856474 * n) * d2r
        let Ms = (357.528 + 0.9856003 * n) * d2r
        let Lm = N + w + M
        let D = Lm - Ls
        let F = Lm - N
        lon += -1.274 * sin(M - 2 * D)
        lon +=  0.658 * sin(2 * D)
        lon += -0.186 * sin(Ms)
        lon += -0.059 * sin(2 * M - 2 * D)
        lon += -0.057 * sin(M - 2 * D + Ms)
        lon +=  0.053 * sin(M + 2 * D)
        lon +=  0.046 * sin(2 * D - Ms)
        lon +=  0.041 * sin(M - Ms)
        lon += -0.035 * sin(D)
        lon += -0.031 * sin(M + Ms)
        lat += -0.173 * sin(F - 2 * D)

        let eps = (23.4393 - 3.563e-7 * n) * d2r
        let lonR = lon * d2r, latR = lat * d2r
        let xe = cos(latR) * cos(lonR)
        let ye = cos(latR) * sin(lonR) * cos(eps) - sin(latR) * sin(eps)
        let ze = cos(latR) * sin(lonR) * sin(eps) + sin(latR) * cos(eps)
        let ra = atan2(ye, xe) / d2r
        let dec = atan2(ze, sqrt(xe * xe + ye * ye)) / d2r
        return (lon.truncatingRemainder(dividingBy: 360), ra, dec)
    }

    /// Moon phase: illuminated fraction (0…1), whether it's waxing, and a name.
    static func moonPhase(_ date: Date) -> (fraction: Double, waxing: Bool, name: String) {
        let sunLon = sun(days(date)).lambda
        let moonLon = moon(date).lonDeg
        var elong = (moonLon - sunLon).truncatingRemainder(dividingBy: 360)
        if elong < 0 { elong += 360 }
        let fraction = (1 - cos(elong * d2r)) / 2
        let waxing = elong < 180
        let name: String
        switch elong {
        case ..<11.25, 348.75...: name = "New Moon"
        case ..<78.75:  name = "Waxing Crescent"
        case ..<101.25: name = "First Quarter"
        case ..<168.75: name = "Waxing Gibbous"
        case ..<191.25: name = "Full Moon"
        case ..<258.75: name = "Waning Gibbous"
        case ..<281.25: name = "Last Quarter"
        default:        name = "Waning Crescent"
        }
        return (fraction, waxing, name)
    }
}

// MARK: - Sky model

/// One sampled point on a body's day-long altitude track.
struct AltSample: Equatable { let t: Date; let alt: Double }

/// Everything the sun/moon cards draw, computed once per render from the coordinate
/// and the current instant by sampling the altitude tracks across the local day.
struct SkyModel: Equatable {
    let dayStart: Date
    let now: Date

    let sunSamples: [AltSample]
    let sunNowAlt: Double
    let sunrise: Date?
    let sunset: Date?
    let solarNoon: Date?
    let goldenHour: Date?     // evening golden-hour start (sun descending through +6°)
    let lastLight: Date?      // civil dusk (sun at −6° after sunset)
    let dayLength: TimeInterval?

    let moonSamples: [AltSample]
    let moonNowAlt: Double
    let moonrise: Date?
    let moonset: Date?
    let moonFraction: Double
    let moonWaxing: Bool
    let moonPhaseName: String

    static func make(latitude: Double, longitude: Double, now: Date) -> SkyModel {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: now)
        let step: TimeInterval = 600   // 10-minute sampling
        let count = 144

        var sun: [AltSample] = [], moon: [AltSample] = []
        sun.reserveCapacity(count + 1); moon.reserveCapacity(count + 1)
        for i in 0...count {
            let t = dayStart.addingTimeInterval(Double(i) * step)
            sun.append(AltSample(t: t, alt: Astronomy.sunAltitude(t, latitude: latitude, longitude: longitude)))
            moon.append(AltSample(t: t, alt: Astronomy.moonAltitude(t, latitude: latitude, longitude: longitude)))
        }

        let sunrise = Self.crossing(sun, level: -0.833, rising: true)
        let sunset  = Self.crossing(sun, level: -0.833, rising: false, after: sunrise)
        let noon    = sun.max(by: { $0.alt < $1.alt })?.t
        let golden  = Self.crossing(sun, level: 6,  rising: false, after: noon)
        let dusk    = Self.crossing(sun, level: -6, rising: false, after: sunset)
        let dayLen: TimeInterval? = (sunrise != nil && sunset != nil)
            ? sunset!.timeIntervalSince(sunrise!) : nil

        let moonrise = Self.crossing(moon, level: 0.125, rising: true)
        let moonset  = Self.crossing(moon, level: 0.125, rising: false, after: moonrise)
        let phase = Astronomy.moonPhase(now)

        return SkyModel(
            dayStart: dayStart, now: now,
            sunSamples: sun,
            sunNowAlt: Astronomy.sunAltitude(now, latitude: latitude, longitude: longitude),
            sunrise: sunrise, sunset: sunset, solarNoon: noon,
            goldenHour: golden, lastLight: dusk, dayLength: dayLen,
            moonSamples: moon,
            moonNowAlt: Astronomy.moonAltitude(now, latitude: latitude, longitude: longitude),
            moonrise: moonrise, moonset: moonset,
            moonFraction: phase.fraction, moonWaxing: phase.waxing, moonPhaseName: phase.name
        )
    }

    /// First time the track crosses `level` in the requested direction (optionally
    /// only after `after`), linearly interpolated between the two bracketing samples.
    private static func crossing(_ s: [AltSample], level: Double,
                                 rising: Bool, after: Date? = nil) -> Date? {
        for k in 1..<s.count {
            if let after, s[k].t <= after { continue }
            let a = s[k - 1].alt - level, b = s[k].alt - level
            let isRise = a < 0 && b >= 0
            let isSet  = a > 0 && b <= 0
            guard (rising && isRise) || (!rising && isSet) else { continue }
            let f = a / (a - b)   // fraction between the two samples
            return s[k - 1].t.addingTimeInterval(f * s[k].t.timeIntervalSince(s[k - 1].t))
        }
        return nil
    }
}

/// Maps a body's day track into a card's coordinate space: time → x, altitude → y,
/// with the horizon pinned to a fixed line so the sunrise/sunset markers sit level.
private struct ArcMap {
    let dayStart: Date
    let width: CGFloat
    let horizonY: CGFloat
    let scaleUp: CGFloat
    let scaleDown: CGFloat

    init(samples: [AltSample], dayStart: Date, size: CGSize,
         horizonFraction: CGFloat = 0.60) {
        self.dayStart = dayStart
        width = size.width
        horizonY = size.height * horizonFraction
        let maxAlt = max(samples.map(\.alt).max() ?? 10, 5)
        let minAlt = min(samples.map(\.alt).min() ?? -10, -5)
        scaleUp   = (horizonY - size.height * 0.16) / CGFloat(maxAlt)
        scaleDown = (size.height * 0.92 - horizonY) / CGFloat(-minAlt)
    }

    func x(_ d: Date) -> CGFloat { width * CGFloat(d.timeIntervalSince(dayStart) / 86400) }
    func y(_ alt: Double) -> CGFloat {
        horizonY - CGFloat(alt) * (alt >= 0 ? scaleUp : scaleDown)
    }
    func point(_ d: Date, _ alt: Double) -> CGPoint { CGPoint(x: x(d), y: y(alt)) }
}

// MARK: - Sun arc card

/// The hero: the sun's path across the sky for the whole day. A smooth arc over a
/// dashed horizon, the daytime wedge washed in warm light, sunrise/sunset markers
/// on the horizon and a glowing sun at the current moment (dim, below the line, at
/// night). The bottom carries a 00·06·12·18 time axis.
struct SunArcCard: View {
    let model: SkyModel
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: Spacing.hair) {
                    Text("SUN")
                        .font(.system(size: 9, weight: .bold)).kerning(0.6)
                        .foregroundStyle(Theme.secondaryText)
                    Text(model.now.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 20, weight: .bold))
                }
                Spacer(minLength: 0)
                if let len = model.dayLength {
                    VStack(alignment: .trailing, spacing: Spacing.hair) {
                        Text("DAYLIGHT")
                            .font(.system(size: 9, weight: .bold)).kerning(0.6)
                            .foregroundStyle(Theme.secondaryText)
                        Text(Self.duration(len))
                            .font(.system(size: 20, weight: .bold).monospacedDigit())
                    }
                }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.base)

            GeometryReader { geo in
                let map = ArcMap(samples: model.sunSamples, dayStart: model.dayStart, size: geo.size)
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, size in Self.draw(ctx, size: size, map: map, model: model, accent: accent) }

                    // Sunrise / sunset markers on the horizon.
                    if let sr = model.sunrise {
                        horizonPill("sunrise.fill", sr, at: CGPoint(x: map.x(sr), y: map.horizonY))
                    }
                    if let ss = model.sunset {
                        horizonPill("sunset.fill", ss, at: CGPoint(x: map.x(ss), y: map.horizonY))
                    }

                    // The sun at "now".
                    let p = map.point(model.now, model.sunNowAlt)
                    let up = model.sunNowAlt > -0.833
                    Circle()
                        .fill(up ? accentSun : Color(white: 0.7))
                        .frame(width: 13, height: 13)
                        .shadow(color: (up ? accentSun : .white).opacity(0.9), radius: up ? 9 : 4)
                        .position(p)

                    // Time axis.
                    ForEach([0, 6, 12, 18], id: \.self) { hr in
                        let t = model.dayStart.addingTimeInterval(Double(hr) * 3600)
                        Text(String(format: "%02d", hr))
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.tertiaryText)
                            .position(x: map.x(t), y: geo.size.height - 8)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.10, green: 0.14, blue: 0.24),
                                              Color(red: 0.05, green: 0.06, blue: 0.10)],
                                     startPoint: .top, endPoint: .bottom))
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    private var accentSun: Color { Color(red: 1.0, green: 0.83, blue: 0.42) }

    private func horizonPill(_ symbol: String, _ date: Date, at p: CGPoint) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            Text(date.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 10, weight: .bold).monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background { Capsule().fill(Color.black.opacity(0.55)) }
        .overlay { Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1) }
        .fixedSize()
        .position(p)
    }

    /// The Canvas layer: warm daytime fill under the arc, the arc line, and the
    /// dashed horizon.
    private static func draw(_ ctx: GraphicsContext, size: CGSize,
                             map: ArcMap, model: SkyModel, accent: Color) {
        guard !model.sunSamples.isEmpty else { return }

        var line = Path()
        for (i, s) in model.sunSamples.enumerated() {
            let pt = map.point(s.t, s.alt)
            if i == 0 { line.move(to: pt) } else { line.addLine(to: pt) }
        }

        // Daytime wedge: area under the arc, clipped to above the horizon.
        var fill = line
        fill.addLine(to: CGPoint(x: size.width, y: size.height))
        fill.addLine(to: CGPoint(x: 0, y: size.height))
        fill.closeSubpath()
        ctx.drawLayer { layer in
            layer.clip(to: Path(CGRect(x: 0, y: 0, width: size.width, height: map.horizonY)))
            layer.fill(fill, with: .linearGradient(
                Gradient(colors: [Color(red: 1.0, green: 0.82, blue: 0.40).opacity(0.45),
                                  Color(red: 1.0, green: 0.62, blue: 0.30).opacity(0.06)]),
                startPoint: CGPoint(x: size.width / 2, y: 0),
                endPoint: CGPoint(x: size.width / 2, y: map.horizonY)))
        }

        // Horizon.
        var hz = Path()
        hz.move(to: CGPoint(x: 0, y: map.horizonY))
        hz.addLine(to: CGPoint(x: size.width, y: map.horizonY))
        ctx.stroke(hz, with: .color(.white.opacity(0.22)),
                   style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

        // The arc.
        ctx.stroke(line, with: .color(.white.opacity(0.85)),
                   style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
    }

    /// "13h 34m".
    private static func duration(_ t: TimeInterval) -> String {
        let m = Int(t / 60); return "\(m / 60)h \(m % 60)m"
    }
}

// MARK: - Golden hour card

/// A compact elevation sparkline with the golden-hour band lit in a gold→violet
/// wash and a dot at the current moment. The big number is the evening golden hour.
struct GoldenHourCard: View {
    let model: SkyModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Text(model.goldenHour?.formatted(date: .omitted, time: .shortened) ?? "—")
                    .font(.system(size: 20, weight: .bold))
                Text("GOLDEN HOUR")
                    .font(.system(size: 9, weight: .bold)).kerning(0.6)
                    .foregroundStyle(Theme.secondaryText)
                Spacer(minLength: 0)
            }
            GeometryReader { geo in
                let map = ArcMap(samples: model.sunSamples, dayStart: model.dayStart,
                                 size: geo.size, horizonFraction: 0.72)
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, size in draw(ctx, size: size, map: map) }
                    let p = map.point(model.now, model.sunNowAlt)
                    Circle()
                        .fill(Color(red: 1.0, green: 0.78, blue: 0.45))
                        .frame(width: 8, height: 8)
                        .shadow(color: Color(red: 1.0, green: 0.6, blue: 0.3).opacity(0.9), radius: 5)
                        .position(p)
                }
            }
        }
        .padding(Spacing.base)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.10, blue: 0.16),
                                              Color(red: 0.06, green: 0.05, blue: 0.09)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    private func draw(_ ctx: GraphicsContext, size: CGSize, map: ArcMap) {
        var line = Path()
        for (i, s) in model.sunSamples.enumerated() {
            let pt = map.point(s.t, s.alt)
            if i == 0 { line.move(to: pt) } else { line.addLine(to: pt) }
        }
        ctx.stroke(line, with: .color(.white.opacity(0.35)),
                   style: StrokeStyle(lineWidth: 1.4, lineCap: .round))

        // Golden-hour band: the samples whose altitude sits within −4°…+6°.
        var band = Path()
        var started = false
        for s in model.sunSamples where s.alt >= -4 && s.alt <= 6 {
            let pt = map.point(s.t, s.alt)
            if started { band.addLine(to: pt) } else { band.move(to: pt); started = true }
        }
        ctx.stroke(band, with: .linearGradient(
            Gradient(colors: [Color(red: 1.0, green: 0.80, blue: 0.40),
                              Color(red: 0.75, green: 0.45, blue: 0.85)]),
            startPoint: CGPoint(x: 0, y: 0),
            endPoint: CGPoint(x: size.width, y: size.height)),
            style: StrokeStyle(lineWidth: 3, lineCap: .round))

        // Horizon hairline.
        var hz = Path()
        hz.move(to: CGPoint(x: 0, y: map.horizonY))
        hz.addLine(to: CGPoint(x: size.width, y: map.horizonY))
        ctx.stroke(hz, with: .color(.white.opacity(0.14)),
                   style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
    }
}

// MARK: - Moon card

/// The moon's current phase drawn as a lit disc, with its name, illuminated
/// percentage and today's moonrise/moonset.
struct MoonCard: View {
    let model: SkyModel

    var body: some View {
        HStack(spacing: Spacing.base) {
            MoonPhotoDisc(date: model.now, fraction: model.moonFraction, waxing: model.moonWaxing, size: 56)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(model.moonPhaseName)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(Int((model.moonFraction * 100).rounded()))% lit")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "arrow.up").font(.system(size: 8, weight: .bold))
                    Text(model.moonrise?.formatted(date: .omitted, time: .shortened) ?? "—")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    Image(systemName: "arrow.down").font(.system(size: 8, weight: .bold))
                        .padding(.leading, Spacing.hair)
                    Text(model.moonset?.formatted(date: .omitted, time: .shortened) ?? "—")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                }
                .foregroundStyle(Theme.tertiaryText)
                .padding(.top, Spacing.hair)
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.base)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.09, green: 0.10, blue: 0.16),
                                              Color(red: 0.04, green: 0.05, blue: 0.08)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
    }
}

/// A moon phase disc: a dark globe with the lit portion painted on the correct
/// limb, the terminator drawn as an ellipse that carves a crescent (before first
/// quarter) or fills a gibbous bulge (after it).
struct MoonDisc: View {
    let fraction: Double
    let waxing: Bool
    var size: CGFloat = 56
    /// Soft white halo around the disc — on for the single hero disc, off for the
    /// tightly-packed phase strip where 7 overlapping halos would muddy together.
    var glow: Bool = true

    private let lit = Color(white: 0.94)
    private let dark = Color(white: 0.15)

    var body: some View {
        Canvas { ctx, s in
            let r = min(s.width, s.height) / 2
            let c = CGPoint(x: s.width / 2, y: s.height / 2)
            let circle = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            ctx.fill(circle, with: .color(dark))
            ctx.drawLayer { layer in
                layer.clip(to: circle)
                // Fully-lit limb (right when waxing, left when waning).
                let half = CGRect(x: waxing ? c.x : c.x - r, y: c.y - r, width: r, height: 2 * r)
                layer.fill(Path(half), with: .color(lit))
                // Terminator ellipse.
                let rx = r * CGFloat(abs(1 - 2 * fraction))
                let ell = Path(ellipseIn: CGRect(x: c.x - rx, y: c.y - r, width: 2 * rx, height: 2 * r))
                layer.fill(ell, with: .color(fraction < 0.5 ? dark : lit))
            }
            ctx.stroke(circle, with: .color(.white.opacity(0.15)), lineWidth: 1)
        }
        .frame(width: size, height: size)
        .shadow(color: .white.opacity(glow ? 0.22 : 0), radius: glow ? 8 : 0)
    }
}

// MARK: - Moon phase strip card

/// A week of the Moon as a horizontal filmstrip of lit discs — one per day, centered
/// on today (largest, haloed), the days before and after tapering away to each side.
/// The big number is today's illuminated percentage; the strip makes the waxing /
/// waning direction legible at a glance. Mirrors the reference "orb row" block.
struct MoonPhaseStripCard: View {
    let model: SkyModel

    /// Days shown on each side of today → `2 * span + 1` discs.
    private static let span = 3

    private struct Day: Identifiable {
        let id: Int          // day offset from today, also the array anchor
        let fraction: Double
        let waxing: Bool
    }

    private var days: [Day] {
        let cal = Calendar.current
        // Sample each day at local noon, a representative mid-day phase.
        let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: model.now) ?? model.now
        return (-Self.span...Self.span).map { off in
            let d = cal.date(byAdding: .day, value: off, to: noon) ?? noon
            let p = Astronomy.moonPhase(d)
            return Day(id: off, fraction: p.fraction, waxing: p.waxing)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: Spacing.s) {
                    Image(systemName: "moon.stars.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.secondaryText)
                    Text(model.moonPhaseName)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                }
                Spacer(minLength: 0)
                Label(model.moonWaxing ? "Waxing" : "Waning",
                      systemImage: model.moonWaxing ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 9, weight: .bold)).kerning(0.3)
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xs)
                    .background { Capsule().fill(Color.white.opacity(0.06)) }
                    .overlay { Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1) }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.base)

            GeometryReader { geo in strip(in: geo.size) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.08, green: 0.09, blue: 0.15),
                                              Color(red: 0.03, green: 0.04, blue: 0.07)],
                                     startPoint: .top, endPoint: .bottom))
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    private func strip(in size: CGSize) -> some View {
        let items = days
        let big = min(size.height * 0.64, 56)
        let cx = size.width / 2
        let discY = size.height * 0.58
        // Spread discs so the outermost still clears the edges.
        let step = min((size.width - big) / CGFloat(2 * Self.span), big * 0.66)

        return ZStack {
            // Soft halo behind today's disc.
            Circle()
                .fill(RadialGradient(colors: [Color(red: 0.82, green: 0.86, blue: 1.0).opacity(0.55),
                                              .clear],
                                     center: .center, startRadius: 0, endRadius: big * 0.85))
                .frame(width: big * 2.1, height: big * 2.1)
                .blur(radius: 6)
                .position(x: cx, y: discY)

            ForEach(items) { day in
                let dist = abs(day.id - 0)
                let scale = pow(0.72, CGFloat(dist))
                let opacity = max(0.32, 1 - CGFloat(dist) * 0.17)
                MoonDisc(fraction: day.fraction, waxing: day.waxing,
                         size: big * scale, glow: false)
                    .opacity(opacity)
                    .position(x: cx + CGFloat(day.id) * step, y: discY)
                    .zIndex(Double(Self.span - dist))
            }

            // Today's illuminated percentage, sitting above the hero disc.
            HStack(alignment: .firstTextBaseline, spacing: Spacing.hair) {
                Text("\(Int((model.moonFraction * 100).rounded()))")
                    .font(.system(size: 26, weight: .heavy).monospacedDigit())
                Text("%")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(Theme.secondaryText)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 4)
            .position(x: cx, y: max(16, discY - big * 0.72))
            .zIndex(Double(Self.span + 1))
        }
    }
}

// MARK: - Daylight band card

/// A horizontal "daylight" band: the whole day drawn as one gradient capsule whose
/// colour follows the real sky (night indigo → sunrise gold → midday blue → sunset
/// gold → night), with a knob at the current moment and the sunrise / sunset (and
/// evening golden-hour) times called out above it.
struct DaylightBandCard: View {
    let model: SkyModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            HStack(alignment: .top) {
                timeLabel("SUNRISE", model.sunrise, "sunrise.fill", align: .leading)
                Spacer(minLength: 0)
                if let g = model.goldenHour {
                    VStack(spacing: Spacing.hair) {
                        Label("GOLDEN HOUR", systemImage: "sun.max.fill")
                            .font(.system(size: 8.5, weight: .bold)).kerning(0.4)
                            .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.42))
                        Text(g.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 13, weight: .bold).monospacedDigit())
                    }
                }
                Spacer(minLength: 0)
                timeLabel("SUNSET", model.sunset, "sunset.fill", align: .trailing)
            }

            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(LinearGradient(stops: bandStops(),
                                             startPoint: .leading, endPoint: .trailing))
                    // Sunrise / sunset ticks on the band.
                    ForEach([model.sunrise, model.sunset].compactMap { $0 }, id: \.self) { t in
                        Capsule().fill(Color.black.opacity(0.35))
                            .frame(width: 2, height: h)
                            .position(x: min(max(CGFloat(frac(t)) * w, 1), w - 1), y: h / 2)
                    }
                    // Now knob.
                    let x = CGFloat(frac(model.now)) * w
                    Circle()
                        .fill(.white)
                        .frame(width: h + 2, height: h + 2)
                        .overlay { Circle().strokeBorder(Color.black.opacity(0.15), lineWidth: 1) }
                        .shadow(color: .black.opacity(0.4), radius: 3)
                        .position(x: min(max(x, (h + 2) / 2), w - (h + 2) / 2), y: h / 2)
                }
            }
            .frame(height: 22)
            Spacer(minLength: 0)
        }
        .padding(Spacing.lg)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.10, green: 0.11, blue: 0.18),
                                              Color(red: 0.04, green: 0.05, blue: 0.09)],
                                     startPoint: .top, endPoint: .bottom))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    private func timeLabel(_ title: String, _ date: Date?, _ symbol: String,
                           align: HorizontalAlignment) -> some View {
        VStack(alignment: align, spacing: Spacing.hair) {
            Label(title, systemImage: symbol)
                .font(.system(size: 8.5, weight: .bold)).kerning(0.4)
                .foregroundStyle(Theme.secondaryText)
            Text(date?.formatted(date: .omitted, time: .shortened) ?? "—")
                .font(.system(size: 15, weight: .bold).monospacedDigit())
        }
    }

    private func frac(_ d: Date) -> Double {
        min(max(d.timeIntervalSince(model.dayStart) / 86400, 0), 1)
    }

    /// One gradient stop per sun sample, coloured by the sky at that altitude.
    private func bandStops() -> [Gradient.Stop] {
        model.sunSamples.map { Gradient.Stop(color: Self.skyColor($0.alt), location: frac($0.t)) }
    }

    /// Sky colour for a given sun altitude — the palette the band interpolates.
    static func skyColor(_ alt: Double) -> Color {
        switch alt {
        case 12...:          return Color(red: 0.20, green: 0.46, blue: 0.86)   // full day
        case 3..<12:         return Color(red: 0.42, green: 0.62, blue: 0.92)   // mid-morning blue
        case -0.833..<3:     return Color(red: 1.0,  green: 0.74, blue: 0.36)   // golden
        case -6 ..< -0.833:  return Color(red: 0.95, green: 0.45, blue: 0.32)   // civil twilight
        case -12 ..< -6:     return Color(red: 0.34, green: 0.27, blue: 0.55)   // nautical dusk
        default:             return Color(red: 0.09, green: 0.10, blue: 0.20)   // night
        }
    }
}

// MARK: - Sun & Moon board

/// The blocks the Sun & Moon face can show. Freely added/removed from the "+"
/// menu, so the face is a small customizable dashboard rather than a fixed layout.
enum SunMoonBlock: String, CaseIterable, Identifiable, Codable {
    case sunArc, daylightBand, goldenHour, moon, moonPhases

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sunArc:       return "Sun Arc"
        case .daylightBand: return "Daylight"
        case .goldenHour:   return "Golden Hour"
        case .moon:         return "Moon"
        case .moonPhases:   return "Moon Phases"
        }
    }

    var symbol: String {
        switch self {
        case .sunArc:       return "sun.max.fill"
        case .daylightBand: return "sun.horizon.fill"
        case .goldenHour:   return "camera.filters"
        case .moon:         return "moon.stars.fill"
        case .moonPhases:   return "moonphase.waxing.gibbous"
        }
    }

    /// Full-width blocks sit on their own row; the rest pair up two-across.
    var isWide: Bool { self == .sunArc || self == .daylightBand || self == .moonPhases }

    /// Row height when this block leads a (wide) row.
    var height: CGFloat {
        switch self {
        case .sunArc:       return 176
        case .daylightBand: return 116
        case .moonPhases:   return 138
        case .goldenHour, .moon: return 132
        }
    }
}

/// The customizable Sun & Moon face: a scroll of blocks with a "+" tile to add more
/// and a right-click "Remove" on each. Everything is computed locally from the
/// coordinate (see ``SkyModel``) and refreshed each minute so the markers glide.
struct SunMoonBoardView: View {
    let latitude: Double
    let longitude: Double
    let accent: Color

    @AppStorage("weather.sunMoonBlocks") private var blocksJSON = SunMoonBoardView.defaultJSON

    static let defaultJSON = #"["sunArc","moonPhases","goldenHour","moon"]"#
    private static let halfHeight: CGFloat = 132

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            board(model: SkyModel.make(latitude: latitude, longitude: longitude, now: context.date))
        }
    }

    // Split out of `body` so the type-checker isn't overwhelmed by the nested
    // ForEach/HStack (it otherwise fails to infer the TimelineView's content type).
    private func board(model: SkyModel) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: Spacing.md) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    rowView(row, model: model)
                }
            }
            .padding(.vertical, Spacing.hair)
        }
    }

    private func rowView(_ row: [BoardItem], model: SkyModel) -> some View {
        HStack(spacing: Spacing.md) {
            ForEach(row) { item in
                itemView(item, model: model)
                    .frame(maxWidth: .infinity, minHeight: rowHeight(row), maxHeight: rowHeight(row))
            }
        }
    }

    // MARK: Items & layout

    private enum BoardItem: Identifiable {
        case block(SunMoonBlock)
        case add
        var id: String { if case .block(let b) = self { return b.rawValue }; return "add" }
        var isWide: Bool { if case .block(let b) = self { return b.isWide }; return false }
    }

    private var items: [BoardItem] {
        var out = blocks.map { BoardItem.block($0) }
        if !addable.isEmpty { out.append(.add) }
        return out
    }

    /// Pack items into rows: a wide block takes its own row; halves pair two-across.
    private var rows: [[BoardItem]] {
        var out: [[BoardItem]] = []
        var pending: BoardItem?
        for it in items {
            if it.isWide {
                if let p = pending { out.append([p]); pending = nil }
                out.append([it])
            } else if let p = pending {
                out.append([p, it]); pending = nil
            } else {
                pending = it
            }
        }
        if let p = pending { out.append([p]) }
        return out
    }

    private func rowHeight(_ row: [BoardItem]) -> CGFloat {
        if row.count == 1, case .block(let b) = row[0], b.isWide { return b.height }
        return Self.halfHeight
    }

    @ViewBuilder
    private func itemView(_ item: BoardItem, model: SkyModel) -> some View {
        switch item {
        case .block(let b):
            blockView(b, model: model)
                .contextMenu {
                    Button(role: .destructive) { remove(b) } label: {
                        Label("Remove \(b.title)", systemImage: "minus.circle")
                    }
                }
        case .add:
            addTile
        }
    }

    @ViewBuilder
    private func blockView(_ block: SunMoonBlock, model: SkyModel) -> some View {
        switch block {
        case .sunArc:       SunArcCard(model: model, accent: accent)
        case .daylightBand: DaylightBandCard(model: model)
        case .goldenHour:   GoldenHourCard(model: model)
        case .moon:         MoonCard(model: model)
        case .moonPhases:   MoonPhaseStripCard(model: model)
        }
    }

    private var addTile: some View {
        Menu {
            ForEach(addable) { b in
                Button { add(b) } label: { Label(b.title, systemImage: b.symbol) }
            }
        } label: {
            VStack(spacing: Spacing.sm) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                Text("Add block")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.line(0.18), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .notchHover(scale: 1.01)
    }

    // MARK: Storage

    private var blocks: [SunMoonBlock] {
        (try? JSONDecoder().decode([SunMoonBlock].self, from: Data(blocksJSON.utf8))) ?? []
    }

    private var addable: [SunMoonBlock] { SunMoonBlock.allCases.filter { !blocks.contains($0) } }

    private func setBlocks(_ list: [SunMoonBlock]) {
        if let data = try? JSONEncoder().encode(list) {
            withAnimation(.snappy(duration: 0.26, extraBounce: 0.1)) {
                blocksJSON = String(decoding: data, as: UTF8.self)
            }
        }
    }

    private func add(_ block: SunMoonBlock) {
        guard !blocks.contains(block) else { return }
        setBlocks(blocks + [block])
    }

    private func remove(_ block: SunMoonBlock) {
        setBlocks(blocks.filter { $0 != block })
    }
}
