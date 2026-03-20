import SwiftUI
import PolarCore
import SwiftAA

// MARK: - Solar System Object

struct SolarSystemObject: Identifiable {
    let id: String
    let name: String
    var raDeg: Double
    var decDeg: Double
    var magnitude: Double
    var extra: String       // e.g. "16% illuminated"
    let color: Color
    let symbolSize: CGFloat

    var raHours: Double { raDeg / 15.0 }
}

// MARK: - View Model

@MainActor
final class SkyMapViewModel: ObservableObject {
    // Catalog data (loaded once)
    @Published var catalogStars: [CatalogStar] = []
    @Published var catalogLoaded = false

    // Solar system bodies (updated periodically)
    @Published var solarSystemObjects: [SolarSystemObject] = []
    @Published var sunAltitude: Double = 0
    @Published var moonIllumination: Double = 0
    @Published var twilightStatus: String = ""
    private var solarSystemTimer: Timer?

    /// Override for planning mode. When non-nil, sky map shows this time instead of live.
    @Published var referenceDate: Date? {
        didSet {
            updateLST()
            updateSolarSystem()
        }
    }

    /// The effective date for all time-dependent calculations.
    var effectiveDate: Date { referenceDate ?? Date() }

    // Projection center (RA/Dec in degrees)
    @Published var centerRA: Double = 0.0
    @Published var centerDec: Double = 0.0

    // Map orientation mode
    enum MapMode { case equatorial, altAz }
    @Published var mapMode: MapMode = .equatorial

    // Alt-Az projection center (altAz mode)
    @Published var centerAlt: Double = 45.0
    @Published var centerAz: Double = 180.0   // Face south (good default for N hemisphere)

    // Zoom: field of view shown on the map (degrees)
    @Published var mapFOV: Double = 60.0

    // Camera FOV from plate solver settings
    @Published var cameraFOVDeg: Double = 3.2
    @Published var cameraRollDeg: Double = 0.0

    // Mount pointing (nil if no mount)
    @Published var mountRA: Double?
    @Published var mountDec: Double?

    // Last plate solve (for GREEN actual FOV overlay)
    @Published var solvedRA: Double?
    @Published var solvedDec: Double?
    @Published var solvedRollDeg: Double?
    @Published var solvedFOVDeg: Double?

    // Target position (for RED target FOV overlay)
    @Published var targetRA: Double = 0.0    // degrees
    @Published var targetDec: Double = 90.0  // degrees — default to celestial pole

    // Selection for GoTo
    @Published var selectedTarget: (name: String, raHours: Double, decDeg: Double)?
    @Published var showGoToConfirm = false
    /// Whether a mount is connected (controls GoTo button visibility in target dialog).
    var mountConnected = false

    // Observer location for horizon cardinal directions
    @Published var observerLatDeg: Double = 60.17
    @Published var observerLonDeg: Double = 24.94

    /// Current sidereal time in radians, updated periodically.
    /// Being @Published, this triggers Canvas redraws so the horizon stays current.
    @Published var lstRadians: Double = 0.0
    private var lstTimer: Timer?

    // Sensor aspect ratio (width/height)
    var sensorAspect: Double = 16.0 / 9.0

    /// When true, the map auto-centers on mount position.
    /// Set to false when user drags the map; re-enabled by "Find Camera" button.
    @Published var followMount = true

    let minFOV: Double = 1.0
    let maxFOV: Double = 180.0

    deinit {
        lstTimer?.invalidate()
        solarSystemTimer?.invalidate()
    }

    /// Start periodic LST updates so the horizon overlay stays accurate.
    func startLSTTimer() {
        stopLSTTimer()
        updateLST()
        updateSolarSystem()
        lstTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateLST()
            }
        }
        solarSystemTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateSolarSystem()
            }
        }
    }

    func stopLSTTimer() {
        lstTimer?.invalidate()
        lstTimer = nil
        solarSystemTimer?.invalidate()
        solarSystemTimer = nil
    }

    /// Update solar system object positions using SwiftAA.
    func updateSolarSystem() {
        let geo = GeographicCoordinates(
            positivelyWestwardLongitude: Degree(-observerLonDeg),
            latitude: Degree(observerLatDeg)
        )
        let jd = JulianDay(effectiveDate)
        var objects: [SolarSystemObject] = []

        // Sun
        let sun = Sun(julianDay: jd)
        let sunEq = sun.equatorialCoordinates
        let sunHoriz = sun.makeHorizontalCoordinates(with: geo)
        sunAltitude = sunHoriz.altitude.value
        objects.append(SolarSystemObject(
            id: "sun", name: "Sun",
            raDeg: sunEq.alpha.value * 15.0, decDeg: sunEq.delta.value,
            magnitude: -26.7, extra: twilightLabel(sunAlt: sunHoriz.altitude.value),
            color: .yellow, symbolSize: 14
        ))

        // Moon
        let moon = Moon(julianDay: jd)
        let moonEq = moon.equatorialCoordinates
        let illum = moon.illuminatedFraction()
        moonIllumination = illum
        objects.append(SolarSystemObject(
            id: "moon", name: "Moon",
            raDeg: moonEq.alpha.value * 15.0, decDeg: moonEq.delta.value,
            magnitude: -12.0, extra: String(format: "%.0f%%", illum * 100),
            color: .init(white: 0.85), symbolSize: 12
        ))

        // Planets
        let planetDefs: [(Planet, String, Color)] = [
            (Mercury(julianDay: jd), "Mercury", .gray),
            (Venus(julianDay: jd), "Venus", .white),
            (Mars(julianDay: jd), "Mars", .red),
            (Jupiter(julianDay: jd), "Jupiter", .orange),
            (Saturn(julianDay: jd), "Saturn", .init(red: 0.9, green: 0.8, blue: 0.4)),
            (Uranus(julianDay: jd), "Uranus", .cyan),
            (Neptune(julianDay: jd), "Neptune", .blue),
        ]

        for (planet, name, color) in planetDefs {
            let eq = planet.equatorialCoordinates
            let mag = planet.magnitude.value
            let displayMag = mag.isNaN ? 99.0 : mag
            objects.append(SolarSystemObject(
                id: name.lowercased(), name: name,
                raDeg: eq.alpha.value * 15.0, decDeg: eq.delta.value,
                magnitude: displayMag,
                extra: displayMag < 99 ? String(format: "mag %.1f", displayMag) : "",
                color: color, symbolSize: 8
            ))
        }

        twilightStatus = twilightLabel(sunAlt: sunAltitude)
        solarSystemObjects = objects
    }

    private func twilightLabel(sunAlt: Double) -> String {
        if sunAlt > 0 { return "Daytime" }
        if sunAlt > -6 { return "Civil twilight" }
        if sunAlt > -12 { return "Nautical twilight" }
        if sunAlt > -18 { return "Astronomical twilight" }
        return "Night"
    }

    private func updateLST() {
        // When a mount is connected, syncToMount() derives LST from the mount's
        // own coordinates. Only fall back to clock-based LST when no mount.
        if mountRA == nil {
            lstRadians = computeLocalSiderealTime()
        }
    }

    func loadCatalog(from solver: PlateSolver) {
        guard !catalogLoaded else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let stars = solver.getStarCatalog()
            DispatchQueue.main.async {
                self?.catalogStars = stars
                self?.catalogLoaded = true
            }
        }
    }

    func zoom(by factor: Double) {
        mapFOV = max(minFOV, min(maxFOV, mapFOV * factor))
    }

    /// Center the sky map on an equatorial position, handling both map modes.
    /// Use this instead of setting centerRA/centerDec directly when the intent is to move the view.
    func centerMap(raDeg: Double, decDeg: Double) {
        centerRA = raDeg
        centerDec = decDeg
        if mapMode == .altAz {
            // Ensure lat/LST trig is current (updateProjectionCache runs each frame; safe after first render)
            if _cosLat == 0 { updateProjectionCache() }
            let aa = equatorialToAltAzFast(raDeg: raDeg, decDeg: decDeg)
            centerAlt = aa.altDeg
            centerAz = aa.azDeg
        }
    }

    func pan(deltaRA: Double, deltaDec: Double) {
        centerRA = (centerRA + deltaRA).truncatingRemainder(dividingBy: 360.0)
        if centerRA < 0 { centerRA += 360.0 }
        centerDec = max(-90, min(90, centerDec + deltaDec))
    }

    /// Follow mount position if connected.
    /// Near the celestial poles (|Dec| > 85°), RA is poorly defined and
    /// small physical movements cause RA to jump by 180°, flipping the
    /// entire map orientation. We lock the projection center RA in this zone
    /// so the view stays stable. The mount crosshair and FOV box still draw
    /// at the correct position because they use the actual mount RA/Dec.
    func syncToMount(status: MountStatus?) {
        guard let s = status, s.connected else {
            mountRA = nil
            mountDec = nil
            return
        }
        mountRA = s.raHours * 15.0  // hours → degrees
        mountDec = s.decDeg

        // Derive LST from mount's RA/Dec + Alt/Az for accurate horizon overlay.
        // The mount is the ground truth — its alt/az and RA/Dec are self-consistent,
        // so computing LST = RA + H from these avoids any clock discrepancy.
        if !s.altDeg.isNaN && !s.azDeg.isNaN {
            let lat = observerLatDeg * .pi / 180.0
            let alt = s.altDeg * .pi / 180.0
            let az = s.azDeg * .pi / 180.0
            let sinH = -sin(az) * cos(alt)
            let cosH = sin(alt) * cos(lat) - cos(alt) * sin(lat) * cos(az)
            let h = atan2(sinH, cosH)
            var lst = s.raHours * 15.0 * .pi / 180.0 + h
            lst = lst.truncatingRemainder(dividingBy: 2.0 * .pi)
            if lst < 0 { lst += 2.0 * .pi }
            lstRadians = lst
        }

        guard followMount else { return }

        if mapMode == .altAz {
            if !s.altDeg.isNaN && !s.azDeg.isNaN {
                centerAlt = s.altDeg
                centerAz = s.azDeg
            }
        } else {
            if abs(s.decDeg) < 85.0 {
                // Normal: follow mount RA
                centerRA = mountRA!
            }
            // Near pole: keep centerRA as-is (stable orientation)
            centerDec = mountDec!
        }
    }

    /// Re-center the map on the current mount position.
    func snapToMount() {
        followMount = true
        if mapMode == .altAz {
            if let ra = mountRA, let dec = mountDec {
                // updateProjectionCache() must have been called before (it's called each frame)
                let aa = equatorialToAltAzFast(raDeg: ra, decDeg: dec)
                centerAlt = aa.altDeg
                centerAz = aa.azDeg
            }
        } else {
            if let ra = mountRA {
                if abs(mountDec ?? 0) < 85.0 { centerRA = ra }
            }
            if let dec = mountDec { centerDec = dec }
        }
    }

    // MARK: - Horizon Coordinate Conversion

    /// Convert horizontal (alt/az) to equatorial (RA/Dec) for the current observer and time.
    ///
    /// Uses the standard astronomical convention: Az 0°=North, 90°=East, 180°=South, 270°=West.
    /// The conversion depends on observer latitude and current Local Sidereal Time (LST).
    /// When a mount is connected, LST is derived from the mount's own coordinates for accuracy.
    /// Otherwise falls back to computing from the computer's UTC clock.
    ///
    /// Formulas (Meeus, Astronomical Algorithms):
    ///   sin(Dec) = sin(Alt)*sin(φ) + cos(Alt)*cos(φ)*cos(Az)
    ///   H = atan2(-sin(Az)*cos(Alt), sin(Alt)*cos(φ) - cos(Alt)*sin(φ)*cos(Az))
    ///   RA = LST - H
    func altazToEquatorial(altDeg: Double, azDeg: Double) -> (raDeg: Double, decDeg: Double) {
        let lat = observerLatDeg * .pi / 180.0
        let alt = altDeg * .pi / 180.0
        let az = azDeg * .pi / 180.0

        // Declination
        let sinDec = sin(alt) * sin(lat) + cos(alt) * cos(lat) * cos(az)
        let dec = asin(max(-1, min(1, sinDec)))

        // Hour angle (Meeus formula — avoids division by cos(dec) near poles)
        let sinH = -sin(az) * cos(alt)
        let cosH = sin(alt) * cos(lat) - cos(alt) * sin(lat) * cos(az)
        let h = atan2(sinH, cosH)

        // RA = LST - H
        var ra = lstRadians - h
        // Normalize to [0, 2π)
        ra = ra.truncatingRemainder(dividingBy: 2.0 * .pi)
        if ra < 0 { ra += 2.0 * .pi }

        return (ra * 180.0 / .pi, dec * 180.0 / .pi)
    }

    /// Compute Local Sidereal Time from the computer's UTC clock and observer longitude.
    ///
    /// Uses the IAU formula for Greenwich Mean Sidereal Time (GMST),
    /// then adds observer longitude to get LST.
    /// Returns LST in radians.
    private func computeLocalSiderealTime() -> Double {
        let jd = currentJD()
        // Julian centuries since J2000.0
        let t = (jd - 2451545.0) / 36525.0
        // GMST in degrees (IAU formula, Meeus eq. 12.4)
        var gmstDeg = 280.46061837 + 360.98564736629 * (jd - 2451545.0)
            + 0.000387933 * t * t - t * t * t / 38710000.0
        gmstDeg = gmstDeg.truncatingRemainder(dividingBy: 360.0)
        if gmstDeg < 0 { gmstDeg += 360.0 }
        // LST = GMST + observer longitude (east positive)
        let lstDeg = gmstDeg + observerLonDeg
        return lstDeg * .pi / 180.0
    }

    private func currentJD() -> Double {
        // Direct conversion — avoids calendar/timezone extraction.
        // JD of Swift reference date (2001-01-01 00:00 UTC) = 2451910.5
        effectiveDate.timeIntervalSinceReferenceDate / 86400.0 + 2451910.5
    }

    // MARK: - Stereographic Projection

    /// Cached trig values for the projection center, recomputed when center changes.
    /// Call `updateProjectionCache()` before a batch of `projectFast()` calls.
    private(set) var _sinDec0: Double = 0
    private(set) var _cosDec0: Double = 1
    private(set) var _ra0Rad: Double = 0
    private(set) var _projScale: Double = 1
    private(set) var _sinLat: Double = 0
    private(set) var _cosLat: Double = 1
    private(set) var _cachedLST: Double = 0
    // Alt-az mode cache
    private(set) var _sinAlt0: Double = 0
    private(set) var _cosAlt0: Double = 1
    private(set) var _az0Rad: Double = 0

    /// Call once per render frame before calling projectFast / altazToEquatorialFast.
    func updateProjectionCache() {
        let dec0 = centerDec * .pi / 180.0
        _sinDec0 = sin(dec0)
        _cosDec0 = cos(dec0)
        _ra0Rad = centerRA * .pi / 180.0
        _projScale = 2.0 / (mapFOV * .pi / 180.0)
        let lat = observerLatDeg * .pi / 180.0
        _sinLat = sin(lat)
        _cosLat = cos(lat)
        _cachedLST = lstRadians
        // Alt-az mode cache
        let alt0 = centerAlt * .pi / 180.0
        _sinAlt0 = sin(alt0)
        _cosAlt0 = cos(alt0)
        _az0Rad = centerAz * .pi / 180.0
    }

    /// Project RA/Dec (degrees) to normalized coordinates [-1, 1] centered on projection center.
    /// Returns nil if the point is on the back hemisphere.
    func project(raDeg: Double, decDeg: Double) -> CGPoint? {
        let ra0 = centerRA * .pi / 180.0
        let dec0 = centerDec * .pi / 180.0
        let ra = raDeg * .pi / 180.0
        let dec = decDeg * .pi / 180.0

        let deltaRA = ra - ra0
        let cosc = sin(dec0) * sin(dec) + cos(dec0) * cos(dec) * cos(deltaRA)

        // Skip points on the back hemisphere
        if cosc < -0.1 { return nil }

        let k = 2.0 / (1.0 + cosc)
        // Limit k to avoid extreme distortion at edges
        let kClamped = min(k, 10.0)

        let x = kClamped * cos(dec) * sin(deltaRA)
        let y = kClamped * (cos(dec0) * sin(dec) - sin(dec0) * cos(dec) * cos(deltaRA))

        // Scale by FOV: mapFOV degrees should span ~2 units
        let scale = 2.0 / (mapFOV * .pi / 180.0)
        return CGPoint(x: -x * scale, y: y * scale)  // flip x so east is left (astronomical convention); y positive = north
    }

    /// Fast projection using cached center trig values. Call updateProjectionCache() first.
    /// In altAz mode, converts RA/Dec → Alt/Az first, then projects in alt-az space.
    func projectFast(raDeg: Double, decDeg: Double) -> CGPoint? {
        if mapMode == .altAz {
            let aa = equatorialToAltAzFast(raDeg: raDeg, decDeg: decDeg)
            return projectAltAzFast(altDeg: aa.altDeg, azDeg: aa.azDeg)
        }
        return projectEquatorialFast(raDeg: raDeg, decDeg: decDeg)
    }

    private func projectEquatorialFast(raDeg: Double, decDeg: Double) -> CGPoint? {
        let ra = raDeg * .pi / 180.0
        let dec = decDeg * .pi / 180.0

        let deltaRA = ra - _ra0Rad
        let sinDec = sin(dec)
        let cosDec = cos(dec)
        let cosDeltaRA = cos(deltaRA)
        let cosc = _sinDec0 * sinDec + _cosDec0 * cosDec * cosDeltaRA

        if cosc < -0.1 { return nil }

        let kClamped = min(2.0 / (1.0 + cosc), 10.0)

        let x = kClamped * cosDec * sin(deltaRA)
        let y = kClamped * (_cosDec0 * sinDec - _sinDec0 * cosDec * cosDeltaRA)

        return CGPoint(x: -x * _projScale, y: y * _projScale)
    }

    /// Project alt-az coordinates directly (alt-az mode). Call updateProjectionCache() first.
    func projectAltAzFast(altDeg: Double, azDeg: Double) -> CGPoint? {
        let alt = altDeg * .pi / 180.0
        var deltaAz = azDeg * .pi / 180.0 - _az0Rad
        // Normalize to [-π, π]
        if deltaAz > .pi { deltaAz -= 2 * .pi }
        if deltaAz < -.pi { deltaAz += 2 * .pi }

        let sinAlt = sin(alt)
        let cosAlt = cos(alt)
        let cosDeltaAz = cos(deltaAz)
        let cosc = _sinAlt0 * sinAlt + _cosAlt0 * cosAlt * cosDeltaAz

        if cosc < -0.1 { return nil }

        let kClamped = min(2.0 / (1.0 + cosc), 10.0)
        let x = kClamped * cosAlt * sin(deltaAz)
        let y = kClamped * (_cosAlt0 * sinAlt - _sinAlt0 * cosAlt * cosDeltaAz)

        return CGPoint(x: x * _projScale, y: y * _projScale)  // no flip: east naturally goes left in alt-az (az increases clockwise, so east=smaller deltaAz from south=negative x)
    }

    /// Fast equatorial→altaz using cached lat and LST trig values. Call updateProjectionCache() first.
    func equatorialToAltAzFast(raDeg: Double, decDeg: Double) -> (altDeg: Double, azDeg: Double) {
        let ra = raDeg * .pi / 180.0
        let dec = decDeg * .pi / 180.0
        let h = _cachedLST - ra   // hour angle
        let sinAlt = sin(dec) * _sinLat + cos(dec) * _cosLat * cos(h)
        let alt = asin(max(-1, min(1, sinAlt)))
        let az = atan2(-cos(dec) * sin(h),
                       sin(dec) * _cosLat - cos(dec) * _sinLat * cos(h))
        var azDeg = az * 180.0 / .pi
        if azDeg < 0 { azDeg += 360.0 }
        return (alt * 180.0 / .pi, azDeg)
    }

    /// Fast altaz→equatorial using cached lat trig values. Call updateProjectionCache() first.
    func altazToEquatorialFast(altDeg: Double, azDeg: Double) -> (raDeg: Double, decDeg: Double) {
        let alt = altDeg * .pi / 180.0
        let az = azDeg * .pi / 180.0

        let sinAlt = sin(alt)
        let cosAlt = cos(alt)
        let cosAz = cos(az)

        let sinDec = sinAlt * _sinLat + cosAlt * _cosLat * cosAz
        let dec = asin(max(-1, min(1, sinDec)))

        let sinH = -sin(az) * cosAlt
        let cosH = sinAlt * _cosLat - cosAlt * _sinLat * cosAz
        let h = atan2(sinH, cosH)

        var ra = _cachedLST - h
        ra = ra.truncatingRemainder(dividingBy: 2.0 * .pi)
        if ra < 0 { ra += 2.0 * .pi }

        return (ra * 180.0 / .pi, dec * 180.0 / .pi)
    }

    /// Convert normalized coordinates to screen coordinates.
    func toScreen(_ point: CGPoint, size: CGSize) -> CGPoint {
        let cx = size.width / 2.0
        let cy = size.height / 2.0
        let halfSize = min(size.width, size.height) / 2.0
        return CGPoint(
            x: cx + point.x * halfSize,
            y: cy - point.y * halfSize  // flip y: screen y goes down
        )
    }

    /// Inverse: screen point to RA/Dec. Returns (raDeg, decDeg) or nil.
    func screenToRADec(_ screenPoint: CGPoint, size: CGSize) -> (raDeg: Double, decDeg: Double)? {
        let cx = size.width / 2.0
        let cy = size.height / 2.0
        let halfSize = min(size.width, size.height) / 2.0

        let nx = (screenPoint.x - cx) / halfSize
        let ny = -(screenPoint.y - cy) / halfSize

        let scale = 2.0 / (mapFOV * .pi / 180.0)
        let x = -nx / scale  // undo the -x flip (east-left convention)
        let y = ny / scale

        let rho = sqrt(x * x + y * y)

        if mapMode == .altAz {
            if rho < 1e-10 { return altazToEquatorial(altDeg: centerAlt, azDeg: centerAz) }
            let c = 2.0 * atan(rho / 2.0)
            let alt0 = centerAlt * .pi / 180.0
            let az0 = centerAz * .pi / 180.0
            let altRad = asin(cos(c) * sin(alt0) + y * sin(c) * cos(alt0) / rho)
            let azRadRaw = az0 + atan2(x * sin(c), rho * cos(alt0) * cos(c) - y * sin(alt0) * sin(c))
            var azDeg = azRadRaw * 180.0 / .pi
            azDeg = azDeg.truncatingRemainder(dividingBy: 360.0)
            if azDeg < 0 { azDeg += 360.0 }
            return altazToEquatorial(altDeg: altRad * 180.0 / .pi, azDeg: azDeg)
        }

        if rho < 1e-10 { return (centerRA, centerDec) }

        let c = 2.0 * atan(rho / 2.0)
        let dec0 = centerDec * .pi / 180.0
        let ra0 = centerRA * .pi / 180.0

        let dec = asin(cos(c) * sin(dec0) + y * sin(c) * cos(dec0) / rho)
        let ra = ra0 + atan2(x * sin(c), rho * cos(dec0) * cos(c) - y * sin(dec0) * sin(c))

        let raDeg = (ra * 180.0 / .pi).truncatingRemainder(dividingBy: 360.0)
        return (raDeg < 0 ? raDeg + 360.0 : raDeg, dec * 180.0 / .pi)
    }
}

// MARK: - Sky Map View

struct SkyMapView: View {
    @ObservedObject var viewModel: SkyMapViewModel
    @EnvironmentObject var dssTileService: DSSTileService
    var onAskAI: ((String, Double, Double) -> Void)?  // (name, raHours, decDeg)
    var onGoTo: ((Double, Double) -> Void)?  // (raHours, decDeg)

    @State private var dragStart: CGPoint?
    @State private var dragStartCenter: (ra: Double, dec: Double)?
    @State private var dragStartAltAz: (az: Double, alt: Double)?
    @State private var draggingTarget = false
    @State private var dragStartTarget: (ra: Double, dec: Double)?
    @State private var dragStartTargetScreen: CGPoint?
    /// Offset between mouse click position and target center at drag start
    @State private var dragTargetGrabOffset: CGSize = .zero
    @State private var isHovering = false
    @State private var scrollMonitor: Any?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Reference published properties so Canvas redraws when they change
                let _ = viewModel.lstRadians
                let _ = dssTileService.isEnabled
                let _ = dssTileService.tileLoadCount

                Canvas { context, size in
                    viewModel.updateProjectionCache()
                    drawBackground(context: context, size: size)
                    if dssTileService.isEnabled {
                        drawDSSLayer(context: context, size: size)
                    }
                    if viewModel.mapMode == .altAz {
                        drawAltAzGrid(context: context, size: size)
                    } else {
                        drawGrid(context: context, size: size)
                    }
                    drawStars(context: context, size: size)
                    drawMessierObjects(context: context, size: size)
                    drawSolarSystem(context: context, size: size)
                    drawCameraFOV(context: context, size: size)
                    drawMountCrosshair(context: context, size: size)
                    drawCardinals(context: context, size: size)
                    drawAltitudeLines(context: context, size: size)
                    drawLabels(context: context, size: size)
                    drawCompassIndicator(context: context, size: size)
                    drawSkyStatus(context: context, size: size)
                }
                .gesture(scrollGesture)
                .gesture(dragGesture(size: geo.size))
                .gesture(tapGesture(size: geo.size))
                .onHover { isHovering = $0 }

                // Overlay controls
                VStack {
                    HStack {
                        Spacer()
                        VStack(spacing: 6) {
                            // Map orientation toggle (Alt-Az / Equatorial)
                            Button {
                                if viewModel.mapMode == .altAz {
                                    // Carry the current alt-az center to equatorial
                                    let eq = viewModel.altazToEquatorial(altDeg: viewModel.centerAlt, azDeg: viewModel.centerAz)
                                    viewModel.centerRA = eq.raDeg
                                    viewModel.centerDec = eq.decDeg
                                    viewModel.mapMode = .equatorial
                                } else {
                                    // Carry the current equatorial center to alt-az
                                    viewModel.updateProjectionCache()
                                    let aa = viewModel.equatorialToAltAzFast(raDeg: viewModel.centerRA, decDeg: viewModel.centerDec)
                                    viewModel.centerAlt = aa.altDeg
                                    viewModel.centerAz = aa.azDeg
                                    viewModel.mapMode = .altAz
                                }
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(.black.opacity(0.6))
                                        .frame(width: 29, height: 29)
                                    Text(viewModel.mapMode == .altAz ? "ALT" : "EQ")
                                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.85))
                                }
                            }
                            .buttonStyle(.plain)
                            .help(viewModel.mapMode == .altAz ? "Switch to equatorial (RA/Dec)" : "Switch to alt-az (horizon up)")

                            // DSS imagery toggle
                            Button {
                                dssTileService.isEnabled.toggle()
                                if !dssTileService.isEnabled {
                                    dssTileService.cancelAllFetches()
                                }
                            } label: {
                                Image(systemName: "photo.stack")
                                    .font(.system(size: 13))
                                    .padding(8)
                                    .background(.black.opacity(0.6))
                                    .clipShape(Circle())
                                    .foregroundStyle(dssTileService.isEnabled ? .cyan : .white.opacity(0.5))
                            }
                            .buttonStyle(.plain)
                            .help(dssTileService.isEnabled ? "Hide sky imagery" : "Show DSS sky imagery")

                            // "Go to target" button — slews mount to RED target (mount connected), or centers map on RED target
                            Button {
                                if viewModel.mountConnected {
                                    onGoTo?(viewModel.targetRA / 15.0, viewModel.targetDec)
                                }
                                viewModel.centerMap(raDeg: viewModel.targetRA, decDeg: viewModel.targetDec)
                            } label: {
                                Image(systemName: "target")
                                    .font(.system(size: 14))
                                    .padding(8)
                                    .background(.black.opacity(0.6))
                                    .clipShape(Circle())
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .help(viewModel.mountConnected ? "Slew mount to target" : "Center map on target")

                            // "Find Camera" button
                            if !viewModel.followMount, viewModel.mountRA != nil {
                                Button {
                                    viewModel.snapToMount()
                                } label: {
                                    Image(systemName: "scope")
                                        .font(.system(size: 14))
                                        .padding(8)
                                        .background(.black.opacity(0.6))
                                        .clipShape(Circle())
                                        .foregroundStyle(.white)
                                }
                                .buttonStyle(.plain)
                                .help("Center on camera")
                            }
                        }
                    }
                    Spacer()
                }
                .padding(8)
            }
        }
        .background(Color.black)
        .onAppear {
            viewModel.startLSTTimer()
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                guard isHovering else { return event }
                let delta = event.scrollingDeltaY
                guard abs(delta) > 0.1 else { return event }
                viewModel.zoom(by: exp(-delta * 0.04))
                return nil  // consume so scroll doesn't propagate to window
            }
        }
        .onDisappear {
            viewModel.stopLSTTimer()
            if let monitor = scrollMonitor {
                NSEvent.removeMonitor(monitor)
                scrollMonitor = nil
            }
        }
        .alert("Target", isPresented: $viewModel.showGoToConfirm) {
            Button("Set Target") {
                if let target = viewModel.selectedTarget {
                    viewModel.targetRA = target.raHours * 15.0
                    viewModel.targetDec = target.decDeg
                }
            }
            if viewModel.mountConnected {
                Button("GoTo") {
                    if let target = viewModel.selectedTarget {
                        viewModel.targetRA = target.raHours * 15.0
                        viewModel.targetDec = target.decDeg
                        onGoTo?(target.raHours, target.decDeg)
                    }
                }
            }
            Button("Ask AI") {
                if let target = viewModel.selectedTarget {
                    onAskAI?(target.name, target.raHours, target.decDeg)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let target = viewModel.selectedTarget {
                Text("RA: \(String(format: "%.4f", target.raHours))h  Dec: \(String(format: "%+.3f", target.decDeg))°")
            }
        }
    }

    // MARK: - Drawing

    private func drawBackground(context: GraphicsContext, size: CGSize) {
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .color(Color(white: 0.05))
        )
    }

    private func drawDSSLayer(context: GraphicsContext, size: CGSize) {
        let fov = viewModel.mapFOV
        guard fov <= DSSTileService.minFOV else { return }

        // In alt-az mode derive tile center from the current alt-az position; in equatorial
        // mode use centerRA/centerDec directly.  Using the alt-az→equatorial conversion
        // here means tiles load for wherever the view is actually pointing, even after panning.
        let tileEq: (raDeg: Double, decDeg: Double)
        if viewModel.mapMode == .altAz {
            tileEq = viewModel.altazToEquatorialFast(altDeg: viewModel.centerAlt, azDeg: viewModel.centerAz)
        } else {
            tileEq = (viewModel.centerRA, viewModel.centerDec)
        }
        let tiles = dssTileService.visibleTiles(
            centerRA: tileEq.raDeg,
            centerDec: tileEq.decDeg,
            fov: fov)
        dssTileService.requestTiles(tiles)

        let halfView  = min(size.width, size.height) / 2.0
        let pixPerDeg = halfView / (fov / 2.0 * .pi / 180.0) * (.pi / 180.0)

        let isAltAz = viewModel.mapMode == .altAz

        for tile in tiles {
            guard let cgImage = dssTileService.cachedCGImage(key: tile.key) else { continue }
            guard let proj = viewModel.projectFast(raDeg: tile.raDeg, decDeg: tile.decDeg)
            else { continue }
            let center = viewModel.toScreen(proj, size: size)
            let half   = tile.sizeDeg * pixPerDeg / 2.0
            guard center.x + half >= 0, center.x - half <= size.width,
                  center.y + half >= 0, center.y - half <= size.height else { continue }

            var tileCtx = context
            tileCtx.opacity = 0.85
            tileCtx.addFilter(.colorMultiply(Color(red: 0.55, green: 0.75, blue: 1.0)))

            if isAltAz {
                // Project the four edge midpoints of this tile in equatorial coords so that
                // adjacent tiles share identical projected boundary points, eliminating seams.
                let hSz = tile.sizeDeg / 2.0
                guard let pN = viewModel.projectFast(raDeg: tile.raDeg,          decDeg: min(tile.decDeg + hSz, 89.9)),
                      let pS = viewModel.projectFast(raDeg: tile.raDeg,          decDeg: max(tile.decDeg - hSz, -89.9)),
                      let pE = viewModel.projectFast(raDeg: tile.raDeg - hSz,    decDeg: tile.decDeg),
                      let pW = viewModel.projectFast(raDeg: tile.raDeg + hSz,    decDeg: tile.decDeg)
                else { continue }
                let sN = viewModel.toScreen(pN, size: size)
                let sS = viewModel.toScreen(pS, size: size)
                let sE = viewModel.toScreen(pE, size: size)
                let sW = viewModel.toScreen(pW, size: size)
                let pixH = hypot(sN.x - sS.x, sN.y - sS.y)
                let pixW = hypot(sE.x - sW.x, sE.y - sW.y)
                // Angle of equatorial north on the alt-az screen at this tile position
                let northAngle = CGFloat(atan2(sN.x - sS.x, sS.y - sN.y))
                let centredRect = CGRect(x: -pixW / 2, y: -pixH / 2, width: pixW, height: pixH)
                // Both projections and DSS images share the same east-left sky convention.
                // Just translate to tile center and rotate by the parallactic angle so the
                // image's north (v=0) aligns with the celestial north direction on screen.
                tileCtx.transform = tileCtx.transform
                    .translatedBy(x: center.x, y: center.y)
                    .rotated(by: northAngle)
                tileCtx.draw(Image(cgImage, scale: 1.0, orientation: .up, label: Text("")),
                             in: centredRect)
            } else {
                let rect = CGRect(x: center.x - half, y: center.y - half,
                                  width: half * 2, height: half * 2)
                tileCtx.draw(Image(cgImage, scale: 1.0, orientation: .up, label: Text("")), in: rect)
            }
        }
    }

    private func drawGrid(context: GraphicsContext, size: CGSize) {
        let gridColor = Color.white.opacity(0.07)

        // RA lines (every 15° = 1 hour, or finer depending on zoom)
        let raStep: Double = {
            if viewModel.mapFOV < 10 { return 1.0 }     // every 1°
            if viewModel.mapFOV < 30 { return 5.0 }     // every 5°
            if viewModel.mapFOV < 90 { return 15.0 }    // every 15° (1h)
            return 30.0                                   // every 30° (2h)
        }()

        let decStep: Double = {
            if viewModel.mapFOV < 10 { return 1.0 }
            if viewModel.mapFOV < 30 { return 5.0 }
            if viewModel.mapFOV < 90 { return 10.0 }
            return 30.0
        }()

        // Curve resolution: coarser at wide FOV
        let curveStep: Double = viewModel.mapFOV < 15 ? 1.0 : (viewModel.mapFOV < 60 ? 2.0 : 4.0)

        // Draw RA lines
        var ra: Double = 0
        while ra < 360 {
            var path = Path()
            var firstPoint = true
            var dec: Double = -90
            while dec <= 90 {
                if let p = viewModel.projectFast(raDeg: ra, decDeg: dec) {
                    let sp = viewModel.toScreen(p, size: size)
                    if sp.x >= -50 && sp.x <= size.width + 50 && sp.y >= -50 && sp.y <= size.height + 50 {
                        if firstPoint { path.move(to: sp); firstPoint = false }
                        else { path.addLine(to: sp) }
                    } else {
                        firstPoint = true
                    }
                } else {
                    firstPoint = true
                }
                dec += curveStep
            }
            context.stroke(path, with: .color(gridColor), lineWidth: 0.5)
            ra += raStep
        }

        // Draw Dec lines
        var decLine: Double = -80
        while decLine <= 80 {
            var path = Path()
            var firstPoint = true
            var raPos: Double = 0
            while raPos <= 360 {
                if let p = viewModel.projectFast(raDeg: raPos, decDeg: decLine) {
                    let sp = viewModel.toScreen(p, size: size)
                    if sp.x >= -50 && sp.x <= size.width + 50 && sp.y >= -50 && sp.y <= size.height + 50 {
                        if firstPoint { path.move(to: sp); firstPoint = false }
                        else { path.addLine(to: sp) }
                    } else {
                        firstPoint = true
                    }
                } else {
                    firstPoint = true
                }
                raPos += curveStep
            }
            context.stroke(path, with: .color(gridColor), lineWidth: 0.5)
            decLine += decStep
        }

        // Celestial equator (Dec=0) slightly brighter
        var eqPath = Path()
        var firstPoint = true
        var raPos: Double = 0
        while raPos <= 360 {
            if let p = viewModel.projectFast(raDeg: raPos, decDeg: 0) {
                let sp = viewModel.toScreen(p, size: size)
                if sp.x >= -50 && sp.x <= size.width + 50 && sp.y >= -50 && sp.y <= size.height + 50 {
                    if firstPoint { eqPath.move(to: sp); firstPoint = false }
                    else { eqPath.addLine(to: sp) }
                } else {
                    firstPoint = true
                }
            }
            raPos += curveStep
        }
        context.stroke(eqPath, with: .color(Color.blue.opacity(0.18)), lineWidth: 1.0)
    }

    // Alt-az grid: altitude rings + azimuth radials, drawn directly in alt-az coordinates.
    private func drawAltAzGrid(context: GraphicsContext, size: CGSize) {
        let gridColor = Color.white.opacity(0.10)
        let fov = viewModel.mapFOV

        let altStep: Double = fov < 10 ? 2.0 : fov < 30 ? 5.0 : 10.0
        let azStep: Double  = fov < 10 ? 5.0 : fov < 30 ? 10.0 : fov < 90 ? 15.0 : 30.0
        let curveStep: Double = fov < 15 ? 1.0 : 2.0

        // Altitude rings
        var alt = -80.0
        while alt <= 90.0 {
            var path = Path()
            var first = true
            var az = 0.0
            while az <= 360.0 {
                if let p = viewModel.projectAltAzFast(altDeg: alt, azDeg: az) {
                    let sp = viewModel.toScreen(p, size: size)
                    if sp.x >= -50 && sp.x <= size.width + 50 && sp.y >= -50 && sp.y <= size.height + 50 {
                        if first { path.move(to: sp); first = false }
                        else { path.addLine(to: sp) }
                    } else { first = true }
                } else { first = true }
                az += curveStep
            }
            context.stroke(path, with: .color(gridColor), lineWidth: 0.5)
            alt += altStep
        }

        // Azimuth radials
        var az = 0.0
        while az < 360.0 {
            var path = Path()
            var first = true
            var a = -80.0
            while a <= 90.0 {
                if let p = viewModel.projectAltAzFast(altDeg: a, azDeg: az) {
                    let sp = viewModel.toScreen(p, size: size)
                    if sp.x >= -50 && sp.x <= size.width + 50 && sp.y >= -50 && sp.y <= size.height + 50 {
                        if first { path.move(to: sp); first = false }
                        else { path.addLine(to: sp) }
                    } else { first = true }
                } else { first = true }
                a += curveStep
            }
            context.stroke(path, with: .color(gridColor), lineWidth: 0.5)
            az += azStep
        }

        // Celestial equator as a faint blue curve (Dec=0)
        var eqPath = Path()
        var first = true
        var ra = 0.0
        while ra <= 360.0 {
            if let p = viewModel.projectFast(raDeg: ra, decDeg: 0) {
                let sp = viewModel.toScreen(p, size: size)
                if sp.x >= -50 && sp.x <= size.width + 50 && sp.y >= -50 && sp.y <= size.height + 50 {
                    if first { eqPath.move(to: sp); first = false }
                    else { eqPath.addLine(to: sp) }
                } else { first = true }
            } else { first = true }
            ra += curveStep
        }
        context.stroke(eqPath, with: .color(Color.blue.opacity(0.25)), lineWidth: 1.0)
    }

    private func drawStars(context: GraphicsContext, size: CGSize) {
        // Limit magnitude based on zoom (show more stars when zoomed in)
        let magLimit: Double = {
            if viewModel.mapFOV < 5 { return 9.0 }
            if viewModel.mapFOV < 15 { return 7.5 }
            if viewModel.mapFOV < 45 { return 6.5 }
            return 5.5
        }()

        for star in viewModel.catalogStars {
            if star.magnitude > magLimit { continue }

            guard let p = viewModel.projectFast(raDeg: star.raDeg, decDeg: star.decDeg) else { continue }
            let sp = viewModel.toScreen(p, size: size)

            // Off-screen culling
            guard sp.x >= -5 && sp.x <= size.width + 5 && sp.y >= -5 && sp.y <= size.height + 5 else { continue }

            // Size: bright stars larger
            let radius = max(0.5, 3.5 - star.magnitude * 0.4)
            let brightness = max(0.2, min(1.0, 1.0 - (star.magnitude - 1.0) / 8.0))

            let rect = CGRect(
                x: sp.x - radius, y: sp.y - radius,
                width: radius * 2, height: radius * 2
            )
            context.fill(
                Path(ellipseIn: rect),
                with: .color(Color.white.opacity(brightness))
            )
        }
    }

    private func drawMessierObjects(context: GraphicsContext, size: CGSize) {
        let fov = viewModel.mapFOV

        // Magnitude limit based on zoom: wider view = only bright objects.
        // At FOV ≤ 20° DSS imagery is active, so show the full catalog for context.
        let magLimit: Double
        if fov > 180 { magLimit = 7.0 }
        else if fov > 90 { magLimit = 9.0 }
        else if fov > 30 { magLimit = 11.0 }
        else if fov > 20 { magLimit = 13.0 }
        else { magLimit = 99.0 }  // DSS zone: show all catalog objects

        let showLabels = fov < 60
        let showAllLabels = fov < 20

        for obj in messierCatalog {
            // Skip faint objects at wide FOV
            if obj.magnitude > magLimit { continue }
            // Skip named stars on the map (they clutter)
            if obj.type == .star { continue }

            guard let p = viewModel.projectFast(raDeg: obj.raDeg, decDeg: obj.decDeg) else { continue }
            let sp = viewModel.toScreen(p, size: size)

            guard sp.x >= -10 && sp.x <= size.width + 10 && sp.y >= -10 && sp.y <= size.height + 10 else { continue }

            let color: Color = {
                switch obj.type {
                case .galaxy: return .yellow
                case .nebula: return .red
                case .cluster: return .cyan
                case .planetary: return .green
                case .globular: return .orange
                case .star: return .white
                case .other: return .gray
                }
            }()

            // Draw symbol
            let symbolSize: CGFloat = 8
            let rect = CGRect(x: sp.x - symbolSize/2, y: sp.y - symbolSize/2, width: symbolSize, height: symbolSize)

            switch obj.type {
            case .galaxy:
                // Ellipse for galaxies
                let ellipse = CGRect(x: sp.x - symbolSize/2, y: sp.y - symbolSize/3, width: symbolSize, height: symbolSize * 0.66)
                context.stroke(Path(ellipseIn: ellipse), with: .color(color), lineWidth: 1.2)
            case .globular:
                // Circle with cross for globulars
                context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: 1.0)
                var cross = Path()
                cross.move(to: CGPoint(x: sp.x - symbolSize/2, y: sp.y))
                cross.addLine(to: CGPoint(x: sp.x + symbolSize/2, y: sp.y))
                cross.move(to: CGPoint(x: sp.x, y: sp.y - symbolSize/2))
                cross.addLine(to: CGPoint(x: sp.x, y: sp.y + symbolSize/2))
                context.stroke(cross, with: .color(color), lineWidth: 0.8)
            case .cluster:
                // Dashed circle for open clusters
                context.stroke(
                    Path(ellipseIn: rect),
                    with: .color(color),
                    style: StrokeStyle(lineWidth: 1.0, dash: [2, 2])
                )
            default:
                // Filled circle for nebulae/planetary
                context.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.4)))
                context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: 1.0)
            }

            // Label: show for bright objects or when deeply zoomed
            if showLabels && (showAllLabels || obj.magnitude < 10 || obj.id.hasPrefix("M")) {
                let label = obj.name != obj.id && !obj.name.isEmpty ? obj.name : obj.id
                let text = Text(label).font(.system(size: 9)).foregroundColor(color)
                context.draw(text, at: CGPoint(x: sp.x + symbolSize/2 + 2, y: sp.y - 6), anchor: .leading)
            }
        }
    }

    private func drawSolarSystem(context: GraphicsContext, size: CGSize) {
        let showLabels = viewModel.mapFOV < 120

        for obj in viewModel.solarSystemObjects {
            guard let p = viewModel.projectFast(raDeg: obj.raDeg, decDeg: obj.decDeg) else { continue }
            let sp = viewModel.toScreen(p, size: size)

            guard sp.x >= -20 && sp.x <= size.width + 20 &&
                  sp.y >= -20 && sp.y <= size.height + 20 else { continue }

            let r = obj.symbolSize / 2.0

            if obj.id == "sun" {
                // Sun: filled yellow circle with rays
                let sunRect = CGRect(x: sp.x - r, y: sp.y - r, width: r * 2, height: r * 2)
                context.fill(Path(ellipseIn: sunRect), with: .color(obj.color))
                // Rays
                for angle in stride(from: 0.0, through: 315.0, by: 45.0) {
                    let rad = CGFloat(angle * .pi / 180.0)
                    var ray = Path()
                    ray.move(to: CGPoint(x: sp.x + CoreGraphics.cos(rad) * (r + 2), y: sp.y + CoreGraphics.sin(rad) * (r + 2)))
                    ray.addLine(to: CGPoint(x: sp.x + CoreGraphics.cos(rad) * (r + 5), y: sp.y + CoreGraphics.sin(rad) * (r + 5)))
                    context.stroke(ray, with: .color(obj.color), lineWidth: 1.2)
                }
            } else if obj.id == "moon" {
                // Moon: circle with illumination hint
                let moonRect = CGRect(x: sp.x - r, y: sp.y - r, width: r * 2, height: r * 2)
                context.stroke(Path(ellipseIn: moonRect), with: .color(obj.color), lineWidth: 1.5)
                // Partial fill to show phase
                let fillRect = CGRect(x: sp.x - r, y: sp.y - r,
                                      width: r * 2 * viewModel.moonIllumination, height: r * 2)
                context.fill(Path(ellipseIn: fillRect), with: .color(obj.color.opacity(0.6)))
            } else {
                // Planets: colored filled circle
                let planetRect = CGRect(x: sp.x - r, y: sp.y - r, width: r * 2, height: r * 2)
                context.fill(Path(ellipseIn: planetRect), with: .color(obj.color))
                context.stroke(Path(ellipseIn: planetRect), with: .color(obj.color.opacity(0.8)), lineWidth: 0.8)
            }

            // Label
            if showLabels {
                let label: String
                if obj.id == "moon" {
                    label = "Moon \(obj.extra)"
                } else if obj.id == "sun" {
                    label = "Sun"
                } else {
                    label = obj.extra.isEmpty ? obj.name : "\(obj.name) \(obj.extra)"
                }
                let text = Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(obj.color)
                context.draw(text, at: CGPoint(x: sp.x + r + 4, y: sp.y - 2), anchor: .leading)
            }
        }
    }

    private func drawSkyStatus(context: GraphicsContext, size: CGSize) {
        // Bottom-left: twilight status + moon info
        guard !viewModel.twilightStatus.isEmpty else { return }
        let moonPct = Int(viewModel.moonIllumination * 100)
        let status = "\(viewModel.twilightStatus)  •  Moon \(moonPct)%"
        let text = Text(status)
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(.white.opacity(0.5))
        context.draw(text, at: CGPoint(x: 8, y: size.height - 8), anchor: .bottomLeading)
    }

    private func drawCameraFOV(context: GraphicsContext, size: CGSize) {
        // RED = target FOV (where we want to point)
        drawFOVRect(context: context, size: size,
                    raDeg: viewModel.targetRA, decDeg: viewModel.targetDec,
                    rollDeg: 0.0, fovDeg: viewModel.cameraFOVDeg,
                    strokeColor: .red, fillColor: .red)

        // GREEN = actual camera position
        // Priority: mount position (live) → plate solve result (last known)
        let roll = viewModel.solvedRollDeg ?? 0.0
        let fov = viewModel.solvedFOVDeg ?? viewModel.cameraFOVDeg
        if let mRA = viewModel.mountRA, let mDec = viewModel.mountDec {
            drawFOVRect(context: context, size: size,
                        raDeg: mRA, decDeg: mDec,
                        rollDeg: roll, fovDeg: fov,
                        strokeColor: .green, fillColor: .green)
            // CYAN = plate solve result if it differs from mount (shows pointing error)
            if let sRA = viewModel.solvedRA, let sDec = viewModel.solvedDec {
                drawFOVRect(context: context, size: size,
                            raDeg: sRA, decDeg: sDec,
                            rollDeg: roll, fovDeg: fov,
                            strokeColor: .cyan, fillColor: .cyan)
            }
        } else if let sRA = viewModel.solvedRA, let sDec = viewModel.solvedDec {
            // No mount — use plate solve as green
            drawFOVRect(context: context, size: size,
                        raDeg: sRA, decDeg: sDec,
                        rollDeg: roll, fovDeg: fov,
                        strokeColor: .green, fillColor: .green)
        }
    }

    private func drawFOVRect(
        context: GraphicsContext, size: CGSize,
        raDeg: Double, decDeg: Double,
        rollDeg: Double, fovDeg: Double,
        strokeColor: Color, fillColor: Color
    ) {
        let halfW = fovDeg / 2.0 * .pi / 180.0
        let halfH = halfW / viewModel.sensorAspect
        let rollRad = rollDeg * .pi / 180.0
        let ra0 = raDeg * .pi / 180.0
        let dec0 = decDeg * .pi / 180.0

        let corners: [(xi: Double, eta: Double)] = [
            (-halfW, -halfH), (halfW, -halfH),
            (halfW, halfH), (-halfW, halfH)
        ]

        var path = Path()
        var first = true
        let edgeSteps = 16
        for i in 0..<4 {
            let c1 = corners[i]
            let c2 = corners[(i + 1) % 4]
            for step in 0...edgeSteps {
                let t = Double(step) / Double(edgeSteps)
                let xi = c1.xi + (c2.xi - c1.xi) * t
                let eta = c1.eta + (c2.eta - c1.eta) * t

                let rx = xi * cos(rollRad) - eta * sin(rollRad)
                let ry = xi * sin(rollRad) + eta * cos(rollRad)

                let rho = sqrt(rx * rx + ry * ry)
                let c = atan(rho)
                let dec: Double
                let ra: Double
                if rho < 1e-12 {
                    dec = dec0
                    ra = ra0
                } else {
                    dec = asin(cos(c) * sin(dec0) + ry * sin(c) * cos(dec0) / rho)
                    ra = ra0 + atan2(rx * sin(c), rho * cos(dec0) * cos(c) - ry * sin(dec0) * sin(c))
                }

                let cornerRA = ra * 180.0 / .pi
                let cornerDec = dec * 180.0 / .pi

                guard let p = viewModel.projectFast(raDeg: cornerRA, decDeg: cornerDec) else { continue }
                let sp = viewModel.toScreen(p, size: size)

                if first { path.move(to: sp); first = false }
                else { path.addLine(to: sp) }
            }
        }
        path.closeSubpath()

        context.stroke(path, with: .color(strokeColor.opacity(0.8)), lineWidth: 1.5)
        context.fill(path, with: .color(fillColor.opacity(0.05)))
    }

    private func drawMountCrosshair(context: GraphicsContext, size: CGSize) {
        guard let mRA = viewModel.mountRA, let mDec = viewModel.mountDec else { return }
        guard let p = viewModel.projectFast(raDeg: mRA, decDeg: mDec) else { return }
        let sp = viewModel.toScreen(p, size: size)

        let len: CGFloat = 12
        var cross = Path()
        cross.move(to: CGPoint(x: sp.x - len, y: sp.y))
        cross.addLine(to: CGPoint(x: sp.x - 4, y: sp.y))
        cross.move(to: CGPoint(x: sp.x + 4, y: sp.y))
        cross.addLine(to: CGPoint(x: sp.x + len, y: sp.y))
        cross.move(to: CGPoint(x: sp.x, y: sp.y - len))
        cross.addLine(to: CGPoint(x: sp.x, y: sp.y - 4))
        cross.move(to: CGPoint(x: sp.x, y: sp.y + 4))
        cross.addLine(to: CGPoint(x: sp.x, y: sp.y + len))

        context.stroke(cross, with: .color(.red), lineWidth: 1.5)
    }

    private func drawCardinals(context: GraphicsContext, size: CGSize) {
        // Named labels for cardinal and intercardinal azimuths
        let namedAz: [Double: (label: String, isMain: Bool)] = [
            0: ("N", true), 45: ("NE", false), 90: ("E", true), 135: ("SE", false),
            180: ("S", true), 225: ("SW", false), 270: ("W", true), 315: ("NW", false),
        ]

        // Draw the horizon line (alt=0) and collect on-screen azimuth positions
        var horizonPath = Path()
        var firstPoint = true
        for azStep in stride(from: 0.0, through: 360.0, by: 2.0) {
            let eq = viewModel.altazToEquatorialFast(altDeg: 0, azDeg: azStep)
            guard let p = viewModel.projectFast(raDeg: eq.raDeg, decDeg: eq.decDeg) else {
                firstPoint = true
                continue
            }
            let sp = viewModel.toScreen(p, size: size)
            if sp.x < -200 || sp.x > size.width + 200 || sp.y < -200 || sp.y > size.height + 200 {
                firstPoint = true
                continue
            }
            if firstPoint { horizonPath.move(to: sp); firstPoint = false }
            else { horizonPath.addLine(to: sp) }
        }
        let horizonOpacity: Double = viewModel.mapMode == .altAz ? 0.6 : 0.3
        let horizonWidth: CGFloat  = viewModel.mapMode == .altAz ? 1.5 : 1.0
        context.stroke(
            horizonPath,
            with: .color(Color.orange.opacity(horizonOpacity)),
            style: StrokeStyle(lineWidth: horizonWidth, dash: [6, 4])
        )

        // Place labels every 10° along the horizon for dense coverage
        for azInt in stride(from: 0, through: 350, by: 10) {
            let az = Double(azInt)
            let eq = viewModel.altazToEquatorialFast(altDeg: 0, azDeg: az)
            guard let p = viewModel.projectFast(raDeg: eq.raDeg, decDeg: eq.decDeg) else { continue }
            let sp = viewModel.toScreen(p, size: size)

            guard sp.x >= -10 && sp.x <= size.width + 10 &&
                  sp.y >= -10 && sp.y <= size.height + 10 else { continue }

            if let named = namedAz[az] {
                // Cardinal or intercardinal label
                let color: Color = named.label == "N" ? .red : .orange
                let fontSize: CGFloat = named.isMain ? 13 : 10
                let opacity: Double = named.isMain ? 0.85 : 0.6
                let text = Text(named.label)
                    .font(.system(size: fontSize, weight: named.isMain ? .bold : .medium, design: .monospaced))
                    .foregroundColor(color.opacity(opacity))
                context.draw(text, at: sp, anchor: .center)
            } else {
                // Degree tick mark for every other 10° step
                let eq2 = viewModel.altazToEquatorialFast(altDeg: 1.0, azDeg: az)
                guard let p2 = viewModel.projectFast(raDeg: eq2.raDeg, decDeg: eq2.decDeg) else { continue }
                let sp2 = viewModel.toScreen(p2, size: size)

                // Short tick perpendicular to horizon (toward zenith)
                let dx = sp2.x - sp.x
                let dy = sp2.y - sp.y
                let d = hypot(dx, dy)
                guard d > 0.5 else { continue }
                let tickLen: CGFloat = 4
                let tx = dx / d * tickLen
                let ty = dy / d * tickLen

                var tick = Path()
                tick.move(to: sp)
                tick.addLine(to: CGPoint(x: sp.x + tx, y: sp.y + ty))
                context.stroke(tick, with: .color(Color.orange.opacity(0.35)), lineWidth: 1.0)

                // Degree label every 30° (that isn't a named cardinal)
                if azInt % 30 == 0 {
                    let text = Text("\(azInt)°")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Color.orange.opacity(0.45))
                    context.draw(text, at: CGPoint(x: sp.x + tx * 3, y: sp.y + ty * 3), anchor: .center)
                }
            }
        }
    }

    private func drawAltitudeLines(context: GraphicsContext, size: CGSize) {
        // Draw altitude circles at 30° and 60° above horizon
        for alt in [30.0, 60.0] {
            var path = Path()
            var firstPoint = true
            for az in stride(from: 0.0, through: 360.0, by: 2.0) {
                let eq = viewModel.altazToEquatorialFast(altDeg: alt, azDeg: az)
                guard let p = viewModel.projectFast(raDeg: eq.raDeg, decDeg: eq.decDeg) else {
                    firstPoint = true
                    continue
                }
                let sp = viewModel.toScreen(p, size: size)
                if sp.x < -100 || sp.x > size.width + 100 || sp.y < -100 || sp.y > size.height + 100 {
                    firstPoint = true
                    continue
                }
                if firstPoint { path.move(to: sp); firstPoint = false }
                else { path.addLine(to: sp) }
            }
            context.stroke(
                path,
                with: .color(Color.orange.opacity(0.15)),
                style: StrokeStyle(lineWidth: 0.5, dash: [4, 6])
            )
        }

        // Draw azimuth lines from horizon to zenith every 45° (N, NE, E, etc.)
        for az in stride(from: 0.0, through: 315.0, by: 45.0) {
            var path = Path()
            var firstPoint = true
            for alt in stride(from: 0.0, through: 90.0, by: 2.0) {
                let eq = viewModel.altazToEquatorialFast(altDeg: alt, azDeg: az)
                guard let p = viewModel.projectFast(raDeg: eq.raDeg, decDeg: eq.decDeg) else {
                    firstPoint = true
                    continue
                }
                let sp = viewModel.toScreen(p, size: size)
                if sp.x < -100 || sp.x > size.width + 100 || sp.y < -100 || sp.y > size.height + 100 {
                    firstPoint = true
                    continue
                }
                if firstPoint { path.move(to: sp); firstPoint = false }
                else { path.addLine(to: sp) }
            }
            let color: Color = az == 0 ? .red.opacity(0.2) : .orange.opacity(0.12)
            context.stroke(path, with: .color(color), lineWidth: 0.5)
        }
    }

    private func drawLabels(context: GraphicsContext, size: CGSize) {
        // FOV info at top-left
        let centerStr: String
        if viewModel.mapMode == .altAz {
            centerStr = "Az \(String(format: "%.1f", viewModel.centerAz))°  Alt \(String(format: "%+.1f", viewModel.centerAlt))°"
        } else {
            centerStr = "RA \(String(format: "%.1f", viewModel.centerRA / 15.0))h  Dec \(String(format: "%+.1f", viewModel.centerDec))°"
        }
        let infoText = Text("FOV: \(String(format: "%.1f", viewModel.mapFOV))°  \(centerStr)")
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(.white.opacity(0.6))
        context.draw(infoText, at: CGPoint(x: 8, y: 8), anchor: .topLeading)

        // RA labels on grid intersections (Dec=0)
        if viewModel.mapFOV >= 15 {
            let raStep: Double = viewModel.mapFOV < 90 ? 15.0 : 30.0
            var ra: Double = 0
            while ra < 360 {
                if let p = viewModel.projectFast(raDeg: ra, decDeg: 0) {
                    let sp = viewModel.toScreen(p, size: size)
                    if sp.x > 20 && sp.x < size.width - 20 && sp.y > 10 && sp.y < size.height - 10 {
                        let label = Text("\(Int(ra / 15))h").font(.system(size: 9)).foregroundColor(.white.opacity(0.4))
                        context.draw(label, at: CGPoint(x: sp.x + 4, y: sp.y - 8), anchor: .leading)
                    }
                }
                ra += raStep
            }
        }
    }

    private func drawCompassIndicator(context: GraphicsContext, size: CGSize) {
        // In alt-az mode the horizon + cardinal labels already provide orientation; skip this indicator
        guard viewModel.mapMode == .equatorial else { return }

        // Convert view center RA/Dec → Alt/Az to get the azimuth
        let lat = viewModel.observerLatDeg * .pi / 180.0
        let dec = viewModel.centerDec * .pi / 180.0
        let ra = viewModel.centerRA * .pi / 180.0
        let h = viewModel.lstRadians - ra  // hour angle

        let az = atan2(-cos(dec) * sin(h),
                       sin(dec) * cos(lat) - cos(dec) * sin(lat) * cos(h))
        var azDeg = az * 180.0 / .pi
        if azDeg < 0 { azDeg += 360.0 }

        // Triangle: small inverted (tip pointing down) at top center
        let cx = size.width / 2.0
        let triSize: CGFloat = 8
        let topY: CGFloat = 24  // leave room for text above

        var tri = Path()
        tri.move(to: CGPoint(x: cx, y: topY + triSize))          // tip (bottom)
        tri.addLine(to: CGPoint(x: cx - triSize, y: topY))       // top-left
        tri.addLine(to: CGPoint(x: cx + triSize, y: topY))       // top-right
        tri.closeSubpath()
        context.fill(tri, with: .color(.red))

        // Azimuth text above triangle
        let azText = Text(String(format: "%.1f°", azDeg))
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundColor(.red)
        context.draw(azText, at: CGPoint(x: cx, y: topY - 4), anchor: .bottom)
    }

    // MARK: - Gestures

    private var scrollGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                viewModel.zoom(by: 1.0 / value.magnification)
            }
    }


    /// Check if a screen point is inside the RED target FOV rectangle.
    private func isInsideTargetFOV(_ point: CGPoint, size: CGSize) -> Bool {
        guard let projected = viewModel.projectFast(raDeg: viewModel.targetRA, decDeg: viewModel.targetDec) else { return false }
        let center = viewModel.toScreen(projected, size: size)

        // Estimate FOV rectangle size on screen
        let halfSize = min(size.width, size.height) / 2.0
        let pxPerDeg = halfSize / (viewModel.mapFOV / 2.0)
        let fovW = viewModel.cameraFOVDeg * pxPerDeg
        let fovH = fovW / viewModel.sensorAspect

        let dx = abs(point.x - center.x)
        let dy = abs(point.y - center.y)
        return dx < fovW / 2.0 && dy < fovH / 2.0
    }

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height
                let halfSize = min(size.width, size.height) / 2.0
                let degPerPx = viewModel.mapFOV / 2.0 / halfSize

                // On first move, decide: drag target FOV or pan map
                if dragStart == nil && dragStartTarget == nil {
                    if isInsideTargetFOV(value.startLocation, size: size) {
                        draggingTarget = true
                        dragStartTarget = (viewModel.targetRA, viewModel.targetDec)
                        // Store screen position of target center and grab offset
                        if let proj = viewModel.projectFast(raDeg: viewModel.targetRA, decDeg: viewModel.targetDec) {
                            let targetScreen = viewModel.toScreen(proj, size: size)
                            dragStartTargetScreen = targetScreen
                            dragTargetGrabOffset = CGSize(
                                width: value.startLocation.x - targetScreen.x,
                                height: value.startLocation.y - targetScreen.y
                            )
                        }
                    } else {
                        draggingTarget = false
                        dragStart = value.startLocation
                        viewModel.followMount = false
                    }
                }

                if draggingTarget {
                    guard let origScreen = dragStartTargetScreen else { return }
                    // Current mouse position minus grab offset = new target center
                    let mouseX = value.startLocation.x + dx
                    let mouseY = value.startLocation.y + dy
                    let targetX = mouseX - dragTargetGrabOffset.width
                    let targetY = mouseY - dragTargetGrabOffset.height
                    // Alt-az projection has opposite X convention from screenToRADec
                    let cx = size.width / 2.0
                    let adjustedX = viewModel.mapMode == .altAz ? (2 * cx - targetX) : targetX
                    let newScreen = CGPoint(x: adjustedX, y: targetY)
                    if let newCoord = viewModel.screenToRADec(newScreen, size: size) {
                        var newRA = newCoord.raDeg.truncatingRemainder(dividingBy: 360.0)
                        if newRA < 0 { newRA += 360.0 }
                        viewModel.targetRA = newRA
                        viewModel.targetDec = max(-90, min(90, newCoord.decDeg))
                    }
                } else if viewModel.mapMode == .altAz {
                    if dragStartAltAz == nil {
                        dragStartAltAz = (viewModel.centerAz, viewModel.centerAlt)
                    }
                    guard let start = dragStartAltAz else { return }
                    let cosAlt = max(cos(viewModel.centerAlt * .pi / 180.0), 0.1)
                    var newAz = (start.az - dx * degPerPx / cosAlt)
                        .truncatingRemainder(dividingBy: 360.0)
                    if newAz < 0 { newAz += 360.0 }
                    viewModel.centerAz = newAz
                    viewModel.centerAlt = max(-5, min(90, start.alt + dy * degPerPx))
                } else {
                    if dragStartCenter == nil {
                        dragStartCenter = (viewModel.centerRA, viewModel.centerDec)
                    }
                    guard let startCenter = dragStartCenter else { return }
                    let deltaRA = dx * degPerPx
                    let deltaDec = dy * degPerPx
                    viewModel.centerRA = (startCenter.ra + deltaRA).truncatingRemainder(dividingBy: 360.0)
                    if viewModel.centerRA < 0 { viewModel.centerRA += 360.0 }
                    viewModel.centerDec = max(-90, min(90, startCenter.dec + deltaDec))
                }
            }
            .onEnded { _ in
                dragStart = nil
                dragStartCenter = nil
                dragStartAltAz = nil
                draggingTarget = false
                dragStartTarget = nil
                dragStartTargetScreen = nil
                dragTargetGrabOffset = .zero
            }
    }

    private func tapGesture(size: CGSize) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                let point = value.location

                // Check solar system objects first (planets, sun, moon — within ~20px)
                for obj in viewModel.solarSystemObjects {
                    guard let p = viewModel.projectFast(raDeg: obj.raDeg, decDeg: obj.decDeg) else { continue }
                    let sp = viewModel.toScreen(p, size: size)
                    let dist = hypot(sp.x - point.x, sp.y - point.y)
                    if dist < 20 {
                        viewModel.selectedTarget = (name: obj.name, raHours: obj.raHours, decDeg: obj.decDeg)
                        viewModel.showGoToConfirm = true
                        return
                    }
                }

                // Check catalog objects (within ~15px, same mag filter as drawing)
                let tapMagLimit: Double = viewModel.mapFOV > 180 ? 7.0 : viewModel.mapFOV > 90 ? 9.0 : viewModel.mapFOV > 30 ? 11.0 : viewModel.mapFOV > 10 ? 13.0 : 99.0
                for obj in messierCatalog {
                    if obj.magnitude > tapMagLimit || obj.type == .star { continue }
                    guard let p = viewModel.projectFast(raDeg: obj.raDeg, decDeg: obj.decDeg) else { continue }
                    let sp = viewModel.toScreen(p, size: size)
                    let dist = hypot(sp.x - point.x, sp.y - point.y)
                    if dist < 15 {
                        let displayName = obj.name != obj.id ? "\(obj.id) \(obj.name)" : obj.id
                        viewModel.selectedTarget = (name: displayName, raHours: obj.raHours, decDeg: obj.decDeg)
                        viewModel.showGoToConfirm = true
                        return
                    }
                }

                // Generic sky position
                if let coord = viewModel.screenToRADec(point, size: size) {
                    let raH = coord.raDeg / 15.0
                    viewModel.selectedTarget = (
                        name: String(format: "RA %.3fh Dec %+.2f°", raH, coord.decDeg),
                        raHours: raH,
                        decDeg: coord.decDeg
                    )
                    viewModel.showGoToConfirm = true
                }
            }
    }
}
