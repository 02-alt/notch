import Foundation

// MARK: - Sky geometry

/// A point on the observer's sky: azimuth (° clockwise from north) and elevation
/// (° above the horizon).
struct SkyPoint: Equatable {
    var azimuth: Double
    var elevation: Double

    /// 8-point compass label for the azimuth ("SW", "NNE" folded to the nearest of 8).
    var compass: String {
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let i = Int((azimuth / 45.0).rounded()) & 7
        return names[i]
    }
}

/// One sampled instant along a pass — where the ISS sits in the sky and whether it
/// would actually be *seen* there (lit by the sun while the observer's sky is dark).
struct PassSample: Equatable {
    let time: Date
    let point: SkyPoint
    let sunlit: Bool     // ISS itself is in sunlight (not in Earth's shadow)
    let darkSky: Bool    // observer's sun is low enough to see it
    var visible: Bool { sunlit && darkSky }
}

/// A single predicted overhead pass of the ISS: when it clears the horizon, peaks,
/// and sets, how high it gets, which way it travels, and the full sky track for
/// drawing — plus whether any of it is actually visible to the naked eye.
struct ISSPass: Identifiable, Equatable {
    let rise: Date
    let peak: Date
    let setTime: Date
    let maxElevation: Double
    let riseAzimuth: Double
    let setAzimuth: Double
    let samples: [PassSample]
    /// True when at least part of the pass is naked-eye visible (sunlit craft, dark sky).
    let visible: Bool

    var id: Date { rise }
    var duration: TimeInterval { setTime.timeIntervalSince(rise) }
}

/// The ISS's live position for the observer: where it is in the sky (if up), the
/// ground point it's over, its altitude, and whether it's currently in sunlight.
struct ISSNow: Equatable {
    let sky: SkyPoint
    let subLatitude: Double
    let subLongitude: Double
    let altitudeKm: Double
    let speedKmh: Double
    let sunlit: Bool
    var isUp: Bool { sky.elevation > 0 }
}

/// One point on the ISS's ground track — the geographic point directly beneath it
/// at a given time, for drawing the orbit path on a world map.
struct SubPoint: Equatable {
    let latitude: Double
    let longitude: Double
    /// Minutes from "now" (negative = past, positive = future), so the map can fade
    /// the trailing path and brighten the leading one.
    let minutesFromNow: Double
}

// MARK: - Manager

/// Fetches the ISS orbit (a TLE from CelesTrak — a public feed, and crucially one we
/// query *without* sending anything about where the user is) and predicts its passes
/// locally with ``SGP4``. It mirrors ``WeatherManager``'s habits: a shared singleton
/// that caches the last result, only refetches the TLE when it's stale, and does the
/// heavy propagation off the main actor.
@MainActor
final class ISSPassManager: ObservableObject {
    static let shared = ISSPassManager()

    @Published private(set) var passes: [ISSPass] = []
    @Published private(set) var now: ISSNow?
    /// The ISS ground track around the present moment (roughly one orbit each side),
    /// recomputed with the live position so the world-map path slides with the orbit.
    @Published private(set) var track: [SubPoint] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorText: String?
    /// The moment the current TLE was issued, so the UI can show orbit freshness.
    @Published private(set) var tleEpoch: Date?

    private var sgp4: SGP4?
    /// When we last pulled a TLE — reused for up to `tleMaxAge` before refetching.
    private var tleFetchedAt: Date?
    private let tleMaxAge: TimeInterval = 6 * 3600
    /// The coordinate the published passes were computed for (rounded), so panning a
    /// few metres doesn't trigger a recompute.
    private var lastKey: String?

    private init() {}

    private static let tleURL = URL(string:
        "https://celestrak.org/NORAD/elements/gp.php?CATNR=25544&FORMAT=TLE")!

    /// Refresh the ISS position and passes for a coordinate. Re-fetches the TLE only
    /// when it's older than `tleMaxAge`; otherwise just re-propagates for the place.
    func load(latitude: Double, longitude: Double, force: Bool = false) async {
        let key = String(format: "%.2f,%.2f", latitude, longitude)
        let tleStale = tleFetchedAt.map { Date().timeIntervalSince($0) > tleMaxAge } ?? true
        if !force && key == lastKey && !tleStale && !passes.isEmpty { return }

        isLoading = true
        defer { isLoading = false }

        // (Re)fetch the orbit when we have none or it's gone stale.
        if sgp4 == nil || tleStale || force {
            do {
                let tle = try await Self.fetchTLE()
                guard let propagator = SGP4(tle: tle) else {
                    errorText = "Couldn't read the ISS orbit."
                    return
                }
                sgp4 = propagator
                tleEpoch = propagator.epoch
                tleFetchedAt = Date()
            } catch {
                // Keep any previously-loaded orbit; only surface the error if we have nothing.
                if sgp4 == nil { errorText = "Couldn't reach the orbit feed." ; return }
            }
        }
        guard let sgp4 else { return }
        errorText = nil
        lastKey = key

        // Propagate off the main actor — a couple of days at 30-second steps.
        let start = Date()
        let result = await Task.detached(priority: .userInitiated) {
            (SkyGeometry.currentPosition(sgp4, latitude: latitude, longitude: longitude, at: start),
             SkyGeometry.findPasses(sgp4, latitude: latitude, longitude: longitude,
                                    from: start, hours: 48, minPeakElevation: 10),
             SkyGeometry.groundTrack(sgp4, at: start))
        }.value

        now = result.0
        passes = result.1
        track = result.2
    }

    /// Frequent refresh of just the live "where is it now" dot and the ground track,
    /// without recomputing the whole pass list. The propagation (currentPosition + a
    /// full ~51-sample groundTrack) runs off the main actor — same as `load` — so the
    /// 3-second refresh loop can't stutter the UI while the Space tab is open.
    func refreshNow(latitude: Double, longitude: Double) async {
        guard let sgp4 else { return }
        let t = Date()
        let result = await Task.detached(priority: .userInitiated) {
            (SkyGeometry.currentPosition(sgp4, latitude: latitude, longitude: longitude, at: t),
             SkyGeometry.groundTrack(sgp4, at: t))
        }.value
        now = result.0
        track = result.1
    }

    /// The next pass that's actually naked-eye visible, else the next pass at all.
    var nextPass: ISSPass? {
        let upcoming = passes.filter { $0.setTime > Date() }
        return upcoming.first(where: { $0.visible }) ?? upcoming.first
    }

    private static func fetchTLE() async throws -> TLE {
        var req = URLRequest(url: tleURL)
        req.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else {
            throw URLError(.badServerResponse)
        }
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // CelesTrak returns "NAME / line1 / line2"; some mirrors omit the name.
        guard let l1 = lines.first(where: { $0.hasPrefix("1 ") }),
              let l2 = lines.first(where: { $0.hasPrefix("2 ") }) else {
            throw URLError(.cannotParseResponse)
        }
        let name = lines.first(where: { !$0.hasPrefix("1 ") && !$0.hasPrefix("2 ") }) ?? "ISS"
        return TLE(name: name, line1: l1, line2: l2)
    }
}

// MARK: - Geometry

/// The coordinate transforms that turn an SGP4 state vector into things the sky arc
/// can draw: the ground point beneath the ISS, its look angles from the observer,
/// and whether it's sunlit. Pure functions, so the manager can run them off-actor.
enum SkyGeometry {
    private static let a = 6378.137                 // WGS-84 equatorial radius, km
    private static let e2 = 0.00669437999014        // first eccentricity squared
    private static let deg = 180.0 / Double.pi
    private static let rad = Double.pi / 180.0

    // MARK: TEME → Earth-fixed

    /// Rotate a TEME position (km) into an Earth-fixed frame using GMST. Polar motion
    /// is ignored — irrelevant at the fraction-of-a-degree scale of a sky arc.
    static func ecef(from teme: SIMD3<Double>, at date: Date) -> SIMD3<Double> {
        let g = SGP4.gstime(SGP4.julianDate(date))
        let c = cos(g), s = sin(g)
        return SIMD3(c * teme.x + s * teme.y,
                     -s * teme.x + c * teme.y,
                     teme.z)
    }

    /// Geodetic sub-point (lat°, lon°, altitude km) of an Earth-fixed position.
    static func geodetic(_ p: SIMD3<Double>) -> (lat: Double, lon: Double, alt: Double) {
        let rxy = (p.x * p.x + p.y * p.y).squareRoot()
        var lat = atan2(p.z, rxy)
        var n = a
        for _ in 0..<8 {
            n = a / (1 - e2 * sin(lat) * sin(lat)).squareRoot()
            lat = atan2(p.z + n * e2 * sin(lat), rxy)
        }
        let alt = rxy / cos(lat) - n
        var lon = atan2(p.y, p.x) * deg
        if lon > 180 { lon -= 360 }; if lon < -180 { lon += 360 }
        return (lat * deg, lon, alt)
    }

    /// Earth-fixed position of an observer on the ellipsoid at sea level.
    static func observerECEF(latitude: Double, longitude: Double) -> SIMD3<Double> {
        let lat = latitude * rad, lon = longitude * rad
        let n = a / (1 - e2 * sin(lat) * sin(lat)).squareRoot()
        return SIMD3(n * cos(lat) * cos(lon),
                     n * cos(lat) * sin(lon),
                     n * (1 - e2) * sin(lat))
    }

    /// Look angles (az/el, °) of an Earth-fixed satellite position from an observer.
    static func lookAngles(sat: SIMD3<Double>, observer: SIMD3<Double>,
                           latitude: Double, longitude: Double) -> SkyPoint {
        let lat = latitude * rad, lon = longitude * rad
        let d = sat - observer
        let sinLat = sin(lat), cosLat = cos(lat), sinLon = sin(lon), cosLon = cos(lon)
        // ENU components.
        let east  = -sinLon * d.x + cosLon * d.y
        let north = -sinLat * cosLon * d.x - sinLat * sinLon * d.y + cosLat * d.z
        let up    =  cosLat * cosLon * d.x + cosLat * sinLon * d.y + sinLat * d.z
        let range = length(d)
        let el = asin(max(-1, min(1, up / range))) * deg
        var az = atan2(east, north) * deg
        if az < 0 { az += 360 }
        return SkyPoint(azimuth: az, elevation: el)
    }

    // MARK: Sun

    /// Sun direction as a unit vector in the Earth-fixed frame (low-precision, plenty
    /// for shadow and twilight tests).
    static func sunECEFUnit(at date: Date) -> SIMD3<Double> {
        let n = date.timeIntervalSince1970 / 86400.0 - 10957.5   // days since J2000
        let L = (280.460 + 0.9856474 * n) * rad
        let g = (357.528 + 0.9856003 * n) * rad
        let lambda = L + (1.915 * sin(g) + 0.020 * sin(2 * g)) * rad
        let eps = (23.439 - 0.0000004 * n) * rad
        // ECI unit vector.
        let eci = SIMD3(cos(lambda), cos(eps) * sin(lambda), sin(eps) * sin(lambda))
        return ecef(from: eci, at: date)   // same GMST rotation works on a direction
    }

    /// Whether a satellite at an Earth-fixed position is lit by the sun (i.e. not
    /// inside Earth's cylindrical shadow).
    static func isSunlit(sat: SIMD3<Double>, sunUnit: SIMD3<Double>) -> Bool {
        let alongSun = dot(sat, sunUnit)
        if alongSun > 0 { return true }             // sat is on the sunward side
        let perp = sat - alongSun * sunUnit
        return length(perp) > a                     // clears the shadow cylinder
    }

    /// Sun elevation (°) at the observer — used to decide the sky is dark enough.
    static func sunElevation(latitude: Double, longitude: Double, at date: Date) -> Double {
        let lat = latitude * rad, lon = longitude * rad
        let up = SIMD3(cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat))
        return asin(max(-1, min(1, dot(up, sunECEFUnit(at: date))))) * deg
    }

    // MARK: Live position

    static func currentPosition(_ sgp4: SGP4, latitude: Double, longitude: Double,
                                at date: Date) -> ISSNow? {
        guard let state = sgp4.propagate(date) else { return nil }
        let satE = ecef(from: state.r, at: date)
        let obs = observerECEF(latitude: latitude, longitude: longitude)
        let sky = lookAngles(sat: satE, observer: obs, latitude: latitude, longitude: longitude)
        let sub = geodetic(satE)
        let sunlit = isSunlit(sat: satE, sunUnit: sunECEFUnit(at: date))
        return ISSNow(sky: sky, subLatitude: sub.lat, subLongitude: sub.lon,
                      altitudeKm: sub.alt, speedKmh: length(state.v) * 3600.0, sunlit: sunlit)
    }

    /// The ground track over roughly one orbit centred on `date` — the geographic
    /// points beneath the ISS from `spanMinutes` in the past to `spanMinutes` ahead,
    /// sampled every `stepMinutes`. Used to draw the orbit path on the world map.
    static func groundTrack(_ sgp4: SGP4, at date: Date,
                            spanMinutes: Double = 50, stepMinutes: Double = 2) -> [SubPoint] {
        var out: [SubPoint] = []
        var m = -spanMinutes
        while m <= spanMinutes {
            let t = date.addingTimeInterval(m * 60)
            if let state = sgp4.propagate(t) {
                let sub = geodetic(ecef(from: state.r, at: t))
                out.append(SubPoint(latitude: sub.lat, longitude: sub.lon, minutesFromNow: m))
            }
            m += stepMinutes
        }
        return out
    }

    // MARK: Pass finding

    /// Predict every pass over `hours` that peaks above `minPeakElevation`, sampling
    /// the elevation on a coarse grid, then refining each horizon crossing.
    static func findPasses(_ sgp4: SGP4, latitude: Double, longitude: Double,
                           from start: Date, hours: Double,
                           minPeakElevation: Double) -> [ISSPass] {
        let obs = observerECEF(latitude: latitude, longitude: longitude)
        let step: TimeInterval = 30
        let total = hours * 3600

        func elevation(_ t: Date) -> Double {
            guard let s = sgp4.propagate(t) else { return -90 }
            return lookAngles(sat: ecef(from: s.r, at: t), observer: obs,
                              latitude: latitude, longitude: longitude).elevation
        }

        var passes: [ISSPass] = []
        var prev = elevation(start)
        var i = 1
        let count = Int(total / step)
        while i <= count {
            let t = start.addingTimeInterval(Double(i) * step)
            let el = elevation(t)
            // A rising crossing of the horizon opens a pass.
            if prev < 0 && el >= 0 {
                let rise = refineCrossing(sgp4, obs: obs, latitude: latitude, longitude: longitude,
                                          lo: t.addingTimeInterval(-step), hi: t, rising: true)
                // Walk forward to the setting crossing.
                var j = i + 1
                var pe = el
                while j <= count {
                    let tj = start.addingTimeInterval(Double(j) * step)
                    let ej = elevation(tj)
                    if pe >= 0 && ej < 0 {
                        let setT = refineCrossing(sgp4, obs: obs, latitude: latitude, longitude: longitude,
                                                  lo: tj.addingTimeInterval(-step), hi: tj, rising: false)
                        if let pass = buildPass(sgp4, obs: obs, latitude: latitude, longitude: longitude,
                                                rise: rise, set: setT, minPeakElevation: minPeakElevation) {
                            passes.append(pass)
                        }
                        break
                    }
                    pe = ej
                    j += 1
                }
                i = j + 1
                prev = -1
                continue
            }
            prev = el
            i += 1
        }
        return passes
    }

    /// Bisect a 30-second bracket down to ~1-second precision on the horizon crossing.
    private static func refineCrossing(_ sgp4: SGP4, obs: SIMD3<Double>,
                                       latitude: Double, longitude: Double,
                                       lo: Date, hi: Date, rising: Bool) -> Date {
        var lo = lo, hi = hi
        func el(_ t: Date) -> Double {
            guard let s = sgp4.propagate(t) else { return -90 }
            return lookAngles(sat: ecef(from: s.r, at: t), observer: obs,
                              latitude: latitude, longitude: longitude).elevation
        }
        for _ in 0..<6 {
            let mid = lo.addingTimeInterval(hi.timeIntervalSince(lo) / 2)
            let em = el(mid)
            let above = em >= 0
            if above == rising { hi = mid } else { lo = mid }
        }
        return lo.addingTimeInterval(hi.timeIntervalSince(lo) / 2)
    }

    /// Sample a pass between its rise and set: the sky track, peak, azimuths, and
    /// whether any sample is naked-eye visible. Returns nil below the elevation cut.
    private static func buildPass(_ sgp4: SGP4, obs: SIMD3<Double>,
                                  latitude: Double, longitude: Double,
                                  rise: Date, set: Date, minPeakElevation: Double) -> ISSPass? {
        let span = set.timeIntervalSince(rise)
        guard span > 0 else { return nil }
        let n = max(12, min(64, Int(span / 10)))    // ~10-second sampling
        var samples: [PassSample] = []
        samples.reserveCapacity(n + 1)
        for k in 0...n {
            let t = rise.addingTimeInterval(span * Double(k) / Double(n))
            guard let s = sgp4.propagate(t) else { continue }
            let satE = ecef(from: s.r, at: t)
            let sky = lookAngles(sat: satE, observer: obs, latitude: latitude, longitude: longitude)
            let sunlit = isSunlit(sat: satE, sunUnit: sunECEFUnit(at: t))
            let dark = sunElevation(latitude: latitude, longitude: longitude, at: t) < -6
            samples.append(PassSample(time: t, point: sky, sunlit: sunlit, darkSky: dark))
        }
        guard let peak = samples.max(by: { $0.point.elevation < $1.point.elevation }) else { return nil }
        guard peak.point.elevation >= minPeakElevation else { return nil }
        return ISSPass(rise: rise, peak: peak.time, setTime: set,
                       maxElevation: peak.point.elevation,
                       riseAzimuth: samples.first?.point.azimuth ?? 0,
                       setAzimuth: samples.last?.point.azimuth ?? 0,
                       samples: samples,
                       visible: samples.contains { $0.visible })
    }

    // MARK: SIMD helpers

    private static func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        a.x * b.x + a.y * b.y + a.z * b.z
    }
    private static func length(_ v: SIMD3<Double>) -> Double { dot(v, v).squareRoot() }
}
