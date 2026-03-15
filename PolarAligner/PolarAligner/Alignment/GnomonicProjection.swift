import Foundation
import PolarCore

/// Pure-math utilities for gnomonic projection, Rodrigues' rotation, and coordinate conversions.
/// Used by the polar alignment simulator to project catalog stars onto a virtual sensor
/// and simulate RA rotation around a misaligned axis.
enum GnomonicProjection {

    // MARK: - Celestial ↔ Cartesian (port from coordinates.rs)

    /// Convert RA/Dec (degrees) to unit Cartesian vector [x, y, z].
    static func celestialToCartesian(raDeg: Double, decDeg: Double) -> (x: Double, y: Double, z: Double) {
        let ra = raDeg * .pi / 180
        let dec = decDeg * .pi / 180
        return (cos(dec) * cos(ra), cos(dec) * sin(ra), sin(dec))
    }

    /// Convert unit Cartesian vector to RA/Dec (degrees).
    static func cartesianToCelestial(x: Double, y: Double, z: Double) -> (raDeg: Double, decDeg: Double) {
        let decDeg = asin(z) * 180 / .pi
        var raDeg = atan2(y, x) * 180 / .pi
        if raDeg < 0 { raDeg += 360 }
        return (raDeg, decDeg)
    }

    // MARK: - Vector Ops

    static func cross(
        _ a: (Double, Double, Double),
        _ b: (Double, Double, Double)
    ) -> (Double, Double, Double) {
        (a.1 * b.2 - a.2 * b.1,
         a.2 * b.0 - a.0 * b.2,
         a.0 * b.1 - a.1 * b.0)
    }

    static func dot(
        _ a: (Double, Double, Double),
        _ b: (Double, Double, Double)
    ) -> Double {
        a.0 * b.0 + a.1 * b.1 + a.2 * b.2
    }

    static func normalize(_ v: (Double, Double, Double)) -> (Double, Double, Double) {
        let len = sqrt(v.0 * v.0 + v.1 * v.1 + v.2 * v.2)
        guard len > 1e-15 else { return (0, 0, 1) }
        return (v.0 / len, v.1 / len, v.2 / len)
    }

    // MARK: - Gnomonic Forward Projection (celestial → pixel)

    /// Project a catalog star at (RA, Dec) onto a virtual sensor.
    ///
    /// - Parameters:
    ///   - starRA, starDec: star position in degrees
    ///   - centerRA, centerDec: camera pointing center in degrees
    ///   - rollDeg: camera roll angle in degrees
    ///   - fovDeg: horizontal field of view in degrees
    ///   - imageWidth, imageHeight: sensor dimensions in pixels
    /// - Returns: pixel coordinates (x, y) or nil if star is behind the camera
    static func projectToPixel(
        starRA: Double, starDec: Double,
        centerRA: Double, centerDec: Double,
        rollDeg: Double,
        fovDeg: Double,
        imageWidth: Int, imageHeight: Int
    ) -> (x: Double, y: Double)? {
        let ra0 = centerRA * .pi / 180
        let dec0 = centerDec * .pi / 180
        let ra = starRA * .pi / 180
        let dec = starDec * .pi / 180
        let deltaRA = ra - ra0

        // Gnomonic projection denominator
        let cosc = sin(dec0) * sin(dec) + cos(dec0) * cos(dec) * cos(deltaRA)
        guard cosc > 0.001 else { return nil } // behind camera

        // Tangent-plane coordinates (radians): xi=east, eta=north
        let xi  = cos(dec) * sin(deltaRA) / cosc
        let eta = (cos(dec0) * sin(dec) - sin(dec0) * cos(dec) * cos(deltaRA)) / cosc

        // Apply roll rotation
        let rollRad = rollDeg * .pi / 180
        let rx =  xi * cos(rollRad) + eta * sin(rollRad)
        let ry = -xi * sin(rollRad) + eta * cos(rollRad)

        // Scale: horizontal FOV spans imageWidth pixels
        let plateScale = (fovDeg * .pi / 180) / Double(imageWidth) // rad/pixel
        let px = Double(imageWidth) / 2.0 + rx / plateScale
        let py = Double(imageHeight) / 2.0 - ry / plateScale // flip Y for pixel coords

        return (px, py)
    }

    // MARK: - Rodrigues' Rotation

    /// Rotate a celestial pointing around an arbitrary axis by a given angle.
    /// Used to simulate RA rotation around a misaligned polar axis.
    ///
    /// - Parameters:
    ///   - pointingRA, pointingDec: current camera center (degrees)
    ///   - axisRA, axisDec: rotation axis (the misaligned pole, degrees)
    ///   - angleDeg: rotation angle (degrees)
    /// - Returns: new camera center (RA, Dec) in degrees
    static func rotateAroundAxis(
        pointingRA: Double, pointingDec: Double,
        axisRA: Double, axisDec: Double,
        angleDeg: Double
    ) -> (raDeg: Double, decDeg: Double) {
        let p = celestialToCartesian(raDeg: pointingRA, decDeg: pointingDec)
        let k = celestialToCartesian(raDeg: axisRA, decDeg: axisDec)
        let theta = angleDeg * .pi / 180

        // Rodrigues' formula: p_rot = p·cosθ + (k×p)·sinθ + k·(k·p)·(1-cosθ)
        let kxp = cross(k, p)
        let kdotp = dot(k, p)
        let cosT = cos(theta)
        let sinT = sin(theta)

        let rotated = normalize((
            p.0 * cosT + kxp.0 * sinT + k.0 * kdotp * (1 - cosT),
            p.1 * cosT + kxp.1 * sinT + k.1 * kdotp * (1 - cosT),
            p.2 * cosT + kxp.2 * sinT + k.2 * kdotp * (1 - cosT)
        ))

        return cartesianToCelestial(x: rotated.0, y: rotated.1, z: rotated.2)
    }

    // MARK: - Alt/Az ↔ Celestial (port from coordinates.rs:148-177)

    /// Convert horizontal (Alt/Az) to equatorial (RA/Dec) coordinates.
    /// Port of Rust `altaz_to_celestial` which is not exposed via FFI.
    static func altazToCelestial(
        altDeg: Double, azDeg: Double,
        observerLatDeg: Double, observerLonDeg: Double,
        jd: Double
    ) -> (raDeg: Double, decDeg: Double) {
        let alt = altDeg * .pi / 180
        let az = azDeg * .pi / 180
        let lat = observerLatDeg * .pi / 180

        let sinDec = sin(alt) * sin(lat) + cos(alt) * cos(lat) * cos(az)
        let dec = asin(sinDec)

        let cosDec = cos(dec)
        let ha: Double
        if abs(cosDec) < 1e-10 {
            ha = 0
        } else {
            let sinHa = -cos(alt) * sin(az) / cosDec
            let cosHa = (sin(alt) - sin(lat) * sinDec) / (cos(lat) * cosDec)
            ha = atan2(sinHa, cosHa)
        }

        let lst = localSiderealTime(jd: jd, longitudeDeg: observerLonDeg)
        var raDeg = (lst - ha * 180 / .pi).truncatingRemainder(dividingBy: 360)
        if raDeg < 0 { raDeg += 360 }

        return (raDeg, dec * 180 / .pi)
    }

    // MARK: - Misaligned Pole Computation

    /// Given an injected polar alignment error (in arcminutes), compute where the
    /// mount's RA axis actually points in RA/Dec.
    ///
    /// Inverts the logic in polar_error.rs:
    /// - `alt_error = (mount_alt - pole_alt) * 60`
    /// - `az_error = az_diff * 60 * cos(mount_alt)`
    static func computeMisalignedPole(
        altErrorArcmin: Double,
        azErrorArcmin: Double,
        observerLatDeg: Double,
        observerLonDeg: Double,
        jd: Double
    ) -> (raDeg: Double, decDeg: Double) {
        // True pole in Alt/Az
        let poleAlt: Double
        let poleAz: Double
        if observerLatDeg >= 0 {
            poleAlt = observerLatDeg
            poleAz = 0
        } else {
            poleAlt = -observerLatDeg
            poleAz = 180
        }

        // Misaligned pole: invert the error formulas
        let mountAlt = poleAlt + altErrorArcmin / 60.0
        let azDiffDeg = azErrorArcmin / 60.0 / cos(mountAlt * .pi / 180)
        var mountAz = poleAz + azDiffDeg
        mountAz = mountAz.truncatingRemainder(dividingBy: 360)
        if mountAz < 0 { mountAz += 360 }

        return altazToCelestial(
            altDeg: mountAlt, azDeg: mountAz,
            observerLatDeg: observerLatDeg, observerLonDeg: observerLonDeg,
            jd: jd
        )
    }

    // MARK: - Magnitude to Brightness

    /// Convert visual magnitude to PSF peak brightness (0–1 range).
    /// Brighter stars have lower magnitude numbers.
    /// Scaled so mag 10 ≈ 0.05 (visible above noise) and mag ≤5 saturates at 1.0.
    static func magnitudeToBrightness(_ magnitude: Double) -> Float {
        let mag = max(-1.0, min(magnitude, 11.0))
        let flux = pow(10.0, -0.4 * mag) // relative to mag 0
        // Scale factor: mag 10 → flux=1e-4 → brightness=0.05
        return Float(min(1.0, flux * 500.0))
    }
}
