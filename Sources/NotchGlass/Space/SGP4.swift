import Foundation

/// A parsed NORAD two-line element set — the compact orbit description we fetch for
/// the ISS and feed to ``SGP4``.
struct TLE: Equatable {
    let name: String
    let line1: String
    let line2: String

    /// NORAD catalog number from line 1 (25544 for the ISS), or nil if unparseable.
    var catalogNumber: Int? { Int(field(line1, 2, 7).trimmingCharacters(in: .whitespaces)) }

    private func field(_ s: String, _ a: Int, _ b: Int) -> String {
        let chars = Array(s)
        guard a < chars.count else { return "" }
        return String(chars[a..<min(b, chars.count)])
    }
}

/// A near-Earth SGP4 orbit propagator (WGS-72 constants), faithful to the canonical
/// Vallado reference. It turns a TLE into satellite position over time, which is
/// exactly what a pass predictor needs — everything else (look angles, rise/set,
/// the sky arc) is geometry on top of the position this returns.
///
/// Only the near-Earth branch is implemented: deep-space satellites (orbital period
/// ≥ 225 min) would need the SDP4 lunar/solar terms, which the ISS — a ~92-minute
/// low orbit — never uses. `init?` returns nil for a deep-space element set rather
/// than silently returning wrong numbers.
///
/// Positions come out in the TEME frame (true-equator, mean-equinox) in kilometres;
/// `subPoint` and `lookAngles` in ``ISSPassManager`` convert from there.
final class SGP4 {
    // MARK: WGS-72 gravity model
    private let radiusearthkm = 6378.135
    private let xke: Double
    private let j2 = 0.001082616
    private let j3oj2: Double
    private let x2o3 = 2.0 / 3.0

    /// The element-set epoch as an absolute date, so callers propagate by passing a
    /// `Date` rather than "minutes since epoch".
    let epoch: Date

    // MARK: Propagation state (the "satrec"), all set up once in init.
    private let no: Double            // mean motion (rad/min), un-Kozai'd
    private let ecco, inclo, argpo, mo, nodeo, bstar: Double
    private let gsto: Double

    private let aycof, con41, cc1, cc4, cc5, d2, d3, d4: Double
    private let delmo, eta, argpdot, omgcof, sinmao, t2cof, t3cof, t4cof, t5cof: Double
    private let x1mth2, x7thm1, mdot, nodedot, xlcof, xmcof, nodecf: Double
    private let isimp: Bool

    // MARK: - Init from a TLE

    init?(tle: TLE) {
        xke = 60.0 / sqrt(radiusearthkm * radiusearthkm * radiusearthkm / 398600.8)
        j3oj2 = -0.00000253881 / j2

        let l1 = Array(tle.line1), l2 = Array(tle.line2)
        guard l1.count >= 63, l2.count >= 63 else { return nil }
        func sub(_ a: [Character], _ i: Int, _ j: Int) -> String {
            String(a[i..<min(j, a.count)])
        }
        func dbl(_ s: String) -> Double? { Double(s.trimmingCharacters(in: .whitespaces)) }

        // Epoch: two-digit year + fractional day-of-year (line 1, cols 19–32).
        guard let yy = Int(sub(l1, 18, 20).trimmingCharacters(in: .whitespaces)),
              let dayFrac = dbl(sub(l1, 20, 32)) else { return nil }
        let year = yy < 57 ? 2000 + yy : 1900 + yy

        // B* drag term (cols 54–61): a sign, 5 assumed-decimal digits, then ±exponent.
        let bstarField = sub(l1, 53, 61)
        guard let bstar = SGP4.assumedDecimal(bstarField) else { return nil }
        self.bstar = bstar

        // Line 2 orbital elements.
        guard let inclDeg = dbl(sub(l2, 8, 16)),
              let raanDeg = dbl(sub(l2, 17, 25)),
              let eccRaw  = dbl("0." + sub(l2, 26, 33).trimmingCharacters(in: .whitespaces)),
              let argpDeg = dbl(sub(l2, 34, 42)),
              let maDeg   = dbl(sub(l2, 43, 51)),
              let revsDay = dbl(sub(l2, 52, 63)) else { return nil }

        let deg2rad = Double.pi / 180
        ecco = eccRaw
        inclo = inclDeg * deg2rad
        nodeo = raanDeg * deg2rad
        argpo = argpDeg * deg2rad
        mo = maDeg * deg2rad
        // rev/day → rad/min.
        let noKozai = revsDay * (2 * Double.pi / 1440.0)

        // Absolute epoch date and its Julian day (for GMST at epoch).
        var comps = DateComponents()
        comps.year = year; comps.month = 1; comps.day = 1
        comps.hour = 0; comps.minute = 0; comps.second = 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let jan1 = cal.date(from: comps) else { return nil }
        let epochDate = jan1.addingTimeInterval((dayFrac - 1.0) * 86400.0)
        epoch = epochDate
        let jd = SGP4.julianDate(epochDate)

        // ---- initl: un-Kozai the mean motion and derive base quantities ----
        let cosio = cos(inclo)
        let cosio2 = cosio * cosio
        let eccsq = ecco * ecco
        let omeosq = 1.0 - eccsq
        let rteosq = sqrt(omeosq)

        let ak = pow(xke / noKozai, x2o3)
        let d1 = 0.75 * j2 * (3.0 * cosio2 - 1.0) / (rteosq * omeosq)
        var delPrime = d1 / (ak * ak)
        let adel = ak * (1.0 - delPrime * delPrime
                         - delPrime * (1.0 / 3.0 + 134.0 * delPrime * delPrime / 81.0))
        delPrime = d1 / (adel * adel)
        no = noKozai / (1.0 + delPrime)

        let ao = pow(xke / no, x2o3)
        let sinio = sin(inclo)
        let po = ao * omeosq
        let con42 = 1.0 - 5.0 * cosio2
        con41 = -con42 - cosio2 - cosio2
        let posq = po * po
        let rp = ao * (1.0 - ecco)

        gsto = SGP4.gstime(jd)

        // Deep-space? ISS never is; bail rather than mispropagate.
        let twoPi = 2 * Double.pi
        if twoPi / no >= 225.0 { return nil }
        // Sub-orbital / decayed elements are meaningless to propagate.
        if rp < 1.0 { return nil }

        // ---- sgp4init: secular gravity & drag coefficients ----
        let ss = 78.0 / radiusearthkm + 1.0
        let qzms2t = pow((120.0 - 78.0) / radiusearthkm, 4.0)

        x1mth2 = 1.0 - cosio2
        x7thm1 = 7.0 * cosio2 - 1.0

        var sfour = ss
        var qzms24 = qzms2t
        let perige = (rp - 1.0) * radiusearthkm

        // Adjust the atmospheric drag shell for low perigees.
        if perige < 156.0 {
            sfour = perige - 78.0
            if perige < 98.0 { sfour = 20.0 }
            qzms24 = pow((120.0 - sfour) / radiusearthkm, 4.0)
            sfour = sfour / radiusearthkm + 1.0
        }
        let pinvsq = 1.0 / posq

        let tsi = 1.0 / (ao - sfour)
        eta = ao * ecco * tsi
        let etasq = eta * eta
        let eeta = ecco * eta
        let psisq = abs(1.0 - etasq)
        let coef = qzms24 * pow(tsi, 4.0)
        let coef1 = coef / pow(psisq, 3.5)
        let cc2 = coef1 * no * (ao * (1.0 + 1.5 * etasq + eeta * (4.0 + etasq))
                    + 0.375 * j2 * tsi / psisq * con41 * (8.0 + 3.0 * etasq * (8.0 + etasq)))
        cc1 = bstar * cc2
        var cc3 = 0.0
        if ecco > 1.0e-4 {
            cc3 = -2.0 * coef * tsi * j3oj2 * no * sinio / ecco
        }
        cc4 = 2.0 * no * coef1 * ao * omeosq
            * (eta * (2.0 + 0.5 * etasq) + ecco * (0.5 + 2.0 * etasq)
               - j2 * tsi / (ao * psisq)
               * (-3.0 * con41 * (1.0 - 2.0 * eeta + etasq * (1.5 - 0.5 * eeta))
                  + 0.75 * x1mth2 * (2.0 * etasq - eeta * (1.0 + etasq)) * cos(2.0 * argpo)))
        cc5 = 2.0 * coef1 * ao * omeosq * (1.0 + 2.75 * (etasq + eeta) + eeta * etasq)

        let cosio4 = cosio2 * cosio2
        let temp1 = 1.5 * j2 * pinvsq * no
        let temp2 = 0.5 * temp1 * j2 * pinvsq
        let temp3 = -0.46875 * -0.00000165597 * pinvsq * pinvsq * no
        mdot = no + 0.5 * temp1 * rteosq * con41
             + 0.0625 * temp2 * rteosq * (13.0 - 78.0 * cosio2 + 137.0 * cosio4)
        argpdot = -0.5 * temp1 * con42
                + 0.0625 * temp2 * (7.0 - 114.0 * cosio2 + 395.0 * cosio4)
                + temp3 * (3.0 - 36.0 * cosio2 + 49.0 * cosio4)
        let xhdot1 = -temp1 * cosio
        nodedot = xhdot1 + (0.5 * temp2 * (4.0 - 19.0 * cosio2)
                            + 2.0 * temp3 * (3.0 - 7.0 * cosio2)) * cosio
        omgcof = bstar * cc3 * cos(argpo)
        xmcof = ecco > 1.0e-4 ? -x2o3 * coef * bstar / eeta : 0.0
        nodecf = 3.5 * omeosq * xhdot1 * cc1
        t2cof = 1.5 * cc1

        // Guard the divide when inclination → π (cosio → −1).
        if abs(cosio + 1.0) > 1.5e-12 {
            xlcof = -0.25 * j3oj2 * sinio * (3.0 + 5.0 * cosio) / (1.0 + cosio)
        } else {
            xlcof = -0.25 * j3oj2 * sinio * (3.0 + 5.0 * cosio) / 1.5e-12
        }
        aycof = -0.5 * j3oj2 * sinio

        let temp = 1.0 + eta * cos(mo)
        delmo = temp * temp * temp
        sinmao = sin(mo)

        isimp = rp < (220.0 / radiusearthkm + 1.0)

        if !isimp {
            let cc1sq = cc1 * cc1
            d2 = 4.0 * ao * tsi * cc1sq
            let temp = d2 * tsi * cc1 / 3.0
            d3 = (17.0 * ao + sfour) * temp
            d4 = 0.5 * temp * ao * tsi * (221.0 * ao + 31.0 * sfour) * cc1
            t3cof = d2 + 2.0 * cc1sq
            t4cof = 0.25 * (3.0 * d3 + cc1 * (12.0 * d2 + 10.0 * cc1sq))
            t5cof = 0.2 * (3.0 * d4 + 12.0 * cc1 * d3
                           + 6.0 * d2 * d2 + 15.0 * cc1sq * (2.0 * d2 + cc1sq))
        } else {
            d2 = 0; d3 = 0; d4 = 0
            t3cof = 0; t4cof = 0; t5cof = 0
        }
    }

    // MARK: - Propagation

    /// Position (km) and velocity (km/s) in the TEME frame at an absolute date, or
    /// nil if the orbit has decayed / the propagation diverged.
    func propagate(_ date: Date) -> (r: SIMD3<Double>, v: SIMD3<Double>)? {
        let tsince = date.timeIntervalSince(epoch) / 60.0   // minutes
        return sgp4(tsince: tsince)
    }

    private func sgp4(tsince: Double) -> (r: SIMD3<Double>, v: SIMD3<Double>)? {
        let twoPi = 2 * Double.pi
        let vkmpersec = radiusearthkm * xke / 60.0

        // --- secular gravity & atmospheric drag ---
        let xmdf = mo + mdot * tsince
        let argpdf = argpo + argpdot * tsince
        let nodedf = nodeo + nodedot * tsince
        var argpm = argpdf
        var mm = xmdf
        let t2 = tsince * tsince
        var nodem = nodedf + nodecf * t2
        var tempa = 1.0 - cc1 * tsince
        var tempe = bstar * cc4 * tsince
        var templ = t2cof * t2

        if !isimp {
            let delomg = omgcof * tsince
            let delmtemp = 1.0 + eta * cos(xmdf)
            let delm = xmcof * (delmtemp * delmtemp * delmtemp - delmo)
            let temp = delomg + delm
            mm = xmdf + temp
            argpm = argpdf - temp
            let t3 = t2 * tsince
            let t4 = t3 * tsince
            tempa = tempa - d2 * t2 - d3 * t3 - d4 * t4
            tempe = tempe + bstar * cc5 * (sin(mm) - sinmao)
            templ = templ + t3cof * t3 + t4 * (t4cof + tsince * t5cof)
        }

        let nm = no
        let em = ecco - tempe
        let inclm = inclo

        if em >= 1.0 || em < -0.001 { return nil }
        let emClamped = max(em, 1.0e-6)

        let am = pow(xke / nm, x2o3) * tempa * tempa
        var mmNew = mm + no * templ
        var xlm = mmNew + argpm + nodem
        nodem = nodem.truncatingRemainder(dividingBy: twoPi)
        argpm = argpm.truncatingRemainder(dividingBy: twoPi)
        xlm = xlm.truncatingRemainder(dividingBy: twoPi)
        mmNew = (xlm - argpm - nodem).truncatingRemainder(dividingBy: twoPi)

        let sinim = sin(inclm)
        let cosim = cos(inclm)

        // --- long-period periodics ---
        let axnl = emClamped * cos(argpm)
        let temp = 1.0 / (am * (1.0 - emClamped * emClamped))
        let aynl = emClamped * sin(argpm) + temp * aycof
        let xl = mmNew + argpm + nodem + temp * xlcof * axnl

        // --- solve Kepler's equation ---
        let u = (xl - nodem).truncatingRemainder(dividingBy: twoPi)
        var eo1 = u
        var tem5 = 9999.9
        var ktr = 0
        var sineo1 = 0.0, coseo1 = 0.0
        while abs(tem5) >= 1.0e-12 && ktr <= 10 {
            sineo1 = sin(eo1)
            coseo1 = cos(eo1)
            tem5 = 1.0 - coseo1 * axnl - sineo1 * aynl
            tem5 = (u - aynl * coseo1 + axnl * sineo1 - eo1) / tem5
            if abs(tem5) >= 0.95 { tem5 = tem5 > 0 ? 0.95 : -0.95 }
            eo1 += tem5
            ktr += 1
        }

        // --- short-period periodics → position and velocity ---
        let ecose = axnl * coseo1 + aynl * sineo1
        let esine = axnl * sineo1 - aynl * coseo1
        let el2 = axnl * axnl + aynl * aynl
        let pl = am * (1.0 - el2)
        if pl < 0.0 { return nil }

        let rl = am * (1.0 - ecose)
        let rdotl = sqrt(am) * esine / rl
        let rvdotl = sqrt(pl) / rl
        let betal = sqrt(1.0 - el2)
        let tempA = esine / (1.0 + betal)
        let sinu = am / rl * (sineo1 - aynl - axnl * tempA)
        let cosu = am / rl * (coseo1 - axnl + aynl * tempA)
        var su = atan2(sinu, cosu)
        let sin2u = (cosu + cosu) * sinu
        let cos2u = 1.0 - 2.0 * sinu * sinu
        let tempP = 1.0 / pl
        let temp1 = 0.5 * j2 * tempP
        let temp2 = temp1 * tempP

        let mrt = rl * (1.0 - 1.5 * temp2 * betal * con41)
                  + 0.5 * temp1 * x1mth2 * cos2u
        su = su - 0.25 * temp2 * x7thm1 * sin2u
        let xnode = nodem + 1.5 * temp2 * cosim * sin2u
        let xinc = inclm + 1.5 * temp2 * cosim * sinim * cos2u
        let mvt = rdotl - nm * temp1 * x1mth2 * sin2u / xke
        let rvdot = rvdotl + nm * temp1 * (x1mth2 * cos2u + 1.5 * con41) / xke

        // --- orientation vectors ---
        let sinsu = sin(su), cossu = cos(su)
        let snod = sin(xnode), cnod = cos(xnode)
        let sini = sin(xinc), cosi = cos(xinc)
        let xmx = -snod * cosi
        let xmy = cnod * cosi
        let ux = xmx * sinsu + cnod * cossu
        let uy = xmy * sinsu + snod * cossu
        let uz = sini * sinsu
        let vx = xmx * cossu - cnod * sinsu
        let vy = xmy * cossu - snod * sinsu
        let vz = sini * cossu

        let r = SIMD3(mrt * ux, mrt * uy, mrt * uz) * radiusearthkm
        let v = SIMD3(mvt * ux + rvdot * vx,
                      mvt * uy + rvdot * vy,
                      mvt * uz + rvdot * vz) * vkmpersec
        if mrt < 1.0 { return nil }   // decayed below the surface
        return (r, v)
    }

    // MARK: - Static helpers

    /// Parse a TLE "assumed decimal" exponential field like "-11606-4" → −0.11606e-4.
    static func assumedDecimal(_ raw: String) -> Double? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return 0 }
        var str = s
        var sign = 1.0
        if str.hasPrefix("-") { sign = -1; str.removeFirst() }
        else if str.hasPrefix("+") { str.removeFirst() }
        // Split mantissa from a trailing signed exponent.
        guard let expSignIdx = str.lastIndex(where: { $0 == "+" || $0 == "-" }),
              expSignIdx != str.startIndex else {
            // No exponent — treat as an assumed-decimal mantissa.
            return Double("0." + str).map { $0 * sign }
        }
        let mant = String(str[str.startIndex..<expSignIdx])
        let expPart = String(str[expSignIdx...])
        guard let mantissa = Double("0." + mant), let exp = Int(expPart) else { return nil }
        return sign * mantissa * pow(10.0, Double(exp))
    }

    /// Julian date (UT) for a calendar instant.
    static func julianDate(_ date: Date) -> Double {
        date.timeIntervalSince1970 / 86400.0 + 2440587.5
    }

    /// Greenwich mean sidereal time (radians) from a Julian date — IAU-82 series,
    /// the same expression SGP4 uses internally.
    static func gstime(_ jd: Double) -> Double {
        let twoPi = 2 * Double.pi
        let tut1 = (jd - 2451545.0) / 36525.0
        var temp = -6.2e-6 * tut1 * tut1 * tut1
            + 0.093104 * tut1 * tut1
            + (876600.0 * 3600.0 + 8640184.812866) * tut1
            + 67310.54841
        temp = (temp * (Double.pi / 180.0) / 240.0).truncatingRemainder(dividingBy: twoPi)
        if temp < 0 { temp += twoPi }
        return temp
    }
}
