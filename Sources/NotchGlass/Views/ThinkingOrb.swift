import SwiftUI

/// A native SwiftUI port of Jakub Antalik's "Thinking Orbs" — specifically the
/// `working` state: particles running on tilted orbits, with faint ghost paths
/// behind them. Honestly 3D — every dot is rotated, depth-shaded and z-sorted,
/// carrying depth by size and ink weight alone (no blur, no gradients), exactly
/// like the original canvas engine. Tuned for the dark notch substrate, where
/// near dots read bright.
///
/// The port mirrors the library's two purposeful presets rather than scaling one:
/// a fine 64pt build and a sparser, larger-dotted 20pt build that stays legible
/// at notch scale. See https://orbs.jakubantalik.com.
struct ThinkingOrb: View {
    /// Edge length of the square orb, in points.
    var size: CGFloat = 28
    /// Clock multiplier over the preset's baked speed.
    var speed: Double = 1
    /// Optional hue. `nil` renders the library's monochrome grayscale (near dots
    /// bright, ghost paths dim) which reads as white-on-dark in the notch.
    var tint: Color? = nil

    var body: some View {
        let preset = OrbPreset.forSize(size)
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate * preset.speed * speed
            Canvas { gc, canvasSize in
                let side = Double(min(canvasSize.width, canvasSize.height))
                for d in OrbPreset.orbitsFrame(side: side, t: t, p: preset) {
                    // Dark substrate: mirror the ink so near dots read bright.
                    let brightness = 1 - d.white
                    let color = (tint ?? .white).opacity(min(1, max(0, brightness)) * d.a)
                    let rect = CGRect(x: d.x - d.r, y: d.y - d.r, width: d.r * 2, height: d.r * 2)
                    gc.fill(Path(ellipseIn: rect), with: .color(color))
                }
            }
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }
}

/// One resolved (state × size) tuning for the `orbits` mode, baked from the
/// library's shipped presets so the render loop only ever sees plain numbers.
private struct OrbPreset {
    var speed: Double
    var orbitN: Int
    var ghostN: Int
    var particles: Int
    var ghostR: Double
    var ghostA: Double
    var partR: Double
    var partRDepth: Double

    /// The fine 64pt build (`orbits` base profile, no multipliers).
    static let large = OrbPreset(
        speed: 1.885, orbitN: 12, ghostN: 40, particles: 3,
        ghostR: 0.9, ghostA: 0.5, partR: 1.2, partRDepth: 1.6)

    /// The 20pt build: ~¼ the orbit/ghost count, dots 2.4× larger, faster clock —
    /// so the orb stays legible when it's only a couple of dozen points across.
    static let small = OrbPreset(
        speed: 3.9, orbitN: 3, ghostN: 10, particles: 3,
        ghostR: 2.16, ghostA: 0.5, partR: 2.88, partRDepth: 3.84)

    static func forSize(_ size: CGFloat) -> OrbPreset { size <= 40 ? small : large }

    /// Deterministic hash in [0, 1) — the engine's `hashD`.
    private static func hashD(_ a: Double, _ b: Double) -> Double {
        let h = sin(a * 12.9898 + b * 78.233) * 43758.5453
        return h - floor(h)
    }

    /// One finished, z-sorted draw list for `t`. A faithful port of `frameOrbits`
    /// + `finalizeFrame`: the caller just draws the list, it never re-derives.
    static func orbitsFrame(side: Double, t: Double, p: OrbPreset) -> [OrbDot] {
        let cx = side / 2, cy = side / 2
        let R = (side / 2) * 0.82
        let rs = pow(side / 300, 0.6)            // radiusScale(size, rsPow: 0.6)
        let rMin = 0.3

        // Shared spin + tilt + orthographic projection (makeProj), scale = 1.
        let yaw = t * 0.12, tilt = 0.3
        let st = sin(tilt), ct = cos(tilt), sy = sin(yaw), cyw = cos(yaw)
        func proj(_ x: Double, _ y: Double, _ z: Double) -> (Double, Double, Double) {
            let x1 = x * cyw + z * sy
            let z1 = -x * sy + z * cyw
            let y1 = y * ct - z1 * st
            let z2 = y * st + z1 * ct
            return (cx + x1, cy - y1, z2)
        }

        var dots: [OrbDot] = []
        for orb in 0..<p.orbitN {
            let h1 = hashD(Double(orb), 1.7)
            let h2 = hashD(Double(orb), 5.2)
            let h3 = hashD(Double(orb), 8.9)
            let ro = R * (0.45 + 0.52 * h1)
            let th = h1 * 2 * .pi
            let phi = acos(2 * h2 - 1)
            // Orbit-plane basis (u, v ⟂ normal n).
            let nx = sin(phi) * cos(th), ny = cos(phi), nz = sin(phi) * sin(th)
            var ux = -ny, uy = nx
            let uz = 0.0
            let ul = max(1e-6, (ux * ux + uy * uy).squareRoot())
            ux /= ul; uy /= ul
            let vx = ny * uz - nz * uy
            let vy = nz * ux - nx * uz
            let vz = nx * uy - ny * ux
            let orbSpeed = (0.25 + 0.55 * h3) * (h3 > 0.5 ? 1 : -1)

            // Ghost path.
            for k in 0..<p.ghostN {
                let a = (Double(k) / Double(p.ghostN)) * 2 * .pi
                let (px, py, z) = proj(
                    (ux * cos(a) + vx * sin(a)) * ro,
                    (uy * cos(a) + vy * sin(a)) * ro,
                    (uz * cos(a) + vz * sin(a)) * ro)
                let depth = (z / ro + 1) / 2
                dots.append(OrbDot(
                    x: px, y: py, z: z,
                    r: max(rMin, p.ghostR * rs),
                    white: 0.72,
                    a: p.ghostA * (0.4 + 0.6 * depth)))
            }
            // The particles doing the work.
            for m in 0..<p.particles {
                let a = t * orbSpeed + (Double(m) / Double(p.particles)) * 2 * .pi + h2 * 6
                let (px, py, z) = proj(
                    (ux * cos(a) + vx * sin(a)) * ro,
                    (uy * cos(a) + vy * sin(a)) * ro,
                    (uz * cos(a) + vz * sin(a)) * ro)
                let depth = (z / ro + 1) / 2
                dots.append(OrbDot(
                    x: px, y: py, z: z,
                    r: max(rMin, (p.partR + p.partRDepth * depth) * rs),
                    white: 0.3 - 0.22 * depth,
                    a: 1))
            }
        }
        // finalizeFrame: drop invisible marks, z-sort far→near.
        return dots.filter { $0.a >= 0.02 }.sorted { $0.z < $1.z }
    }
}

/// One rendered dot: already projected, radius-clamped and depth-shaded.
private struct OrbDot {
    let x, y, z, r, white, a: Double
}
