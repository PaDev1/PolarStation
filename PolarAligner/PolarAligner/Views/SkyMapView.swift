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

    // Zoom: field of view shown on the map (degrees)
    @Published var mapFOV: Double = 60.0

    // Camera FOV from plate solver settings
    @Published var cameraFOVDeg: Double = 3.2
    @Published var cameraRollDeg: Double = 0.0

    // Mount pointing (nil if no mount)
    @Published var mountRA: Double?
    @Published var mountDec: Double?

    // Last plate solve (for FOV overlay)
    @Published var solvedRA: Double?
    @Published var solvedDec: Double?
    @Published var solvedRollDeg: Double?
    @Published var solvedFOVDeg: Double?

    // Selection for GoTo
    @Published var selectedTarget: (name: String, raHours: Double, decDeg: Double)?
    @Published var showGoToConfirm = false

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

    let minFOV: Double = 2.0
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

        if abs(s.decDeg) < 85.0 {
            // Normal: follow mount RA
            centerRA = mountRA!
        }
        // Near pole: keep centerRA as-is (stable orientation)
        centerDec = mountDec!
    }

    /// Re-center the map on the current mount position.
    func snapToMount() {
        followMount = true
        if let ra = mountRA {
            if abs(mountDec ?? 0) < 85.0 {
                centerRA = ra
            }
        }
        if let dec = mountDec { centerDec = dec }
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
    func projectFast(raDeg: Double, decDeg: Double) -> CGPoint? {
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
        let y = ny / scale   // y was not flipped in project

        let rho = sqrt(x * x + y * y)
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
    var onGoTo: ((Double, Double) -> Void)?  // (raHours, decDeg)

    @State private var dragStart: CGPoint?
    @State private var dragStartCenter: (ra: Double, dec: Double)?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Reference lstRadians so Canvas redraws when sidereal time updates
                let _ = viewModel.lstRadians

                Canvas { context, size in
                    viewModel.updateProjectionCache()
                    drawBackground(context: context, size: size)
                    drawGrid(context: context, size: size)
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

                // Overlay controls
                VStack {
                    HStack {
                        Spacer()
                        // "Find Camera" button — re-center map on mount
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
                    Spacer()
                }
                .padding(8)
            }
        }
        .background(Color.black)
        .onAppear {
            viewModel.startLSTTimer()
        }
        .onDisappear {
            viewModel.stopLSTTimer()
        }
        .alert("GoTo Target", isPresented: $viewModel.showGoToConfirm) {
            Button("GoTo") {
                if let target = viewModel.selectedTarget {
                    onGoTo?(target.raHours, target.decDeg)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let target = viewModel.selectedTarget {
                Text("Slew to \(target.name)?\nRA: \(String(format: "%.4f", target.raHours))h  Dec: \(String(format: "%+.3f", target.decDeg))°")
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

    private func drawGrid(context: GraphicsContext, size: CGSize) {
        let gridColor = Color.white.opacity(0.12)

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
        context.stroke(eqPath, with: .color(Color.blue.opacity(0.3)), lineWidth: 1.0)
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
        // Only show labels when zoomed in enough
        let showLabels = viewModel.mapFOV < 90

        for obj in messierCatalog {
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

            // Label
            if showLabels {
                let text = Text(obj.id).font(.system(size: 9)).foregroundColor(color)
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
        // Use solved position if available, otherwise mount position
        let cRA: Double
        let cDec: Double
        let roll: Double
        let fov: Double

        if let sRA = viewModel.solvedRA, let sDec = viewModel.solvedDec {
            cRA = sRA
            cDec = sDec
            roll = viewModel.solvedRollDeg ?? 0.0
            fov = viewModel.solvedFOVDeg ?? viewModel.cameraFOVDeg
        } else if let mRA = viewModel.mountRA, let mDec = viewModel.mountDec {
            cRA = mRA
            cDec = mDec
            roll = 0.0
            fov = viewModel.cameraFOVDeg
        } else {
            return
        }

        let halfW = fov / 2.0 * .pi / 180.0   // radians
        let halfH = halfW / viewModel.sensorAspect
        let rollRad = roll * .pi / 180.0
        let ra0 = cRA * .pi / 180.0
        let dec0 = cDec * .pi / 180.0

        // 4 corners in tangent-plane coordinates (xi=east, eta=north) in radians
        let corners: [(xi: Double, eta: Double)] = [
            (-halfW, -halfH), (halfW, -halfH),
            (halfW, halfH), (-halfW, halfH)
        ]

        // Draw each edge with interpolated points for correct curvature
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

                // Apply roll rotation in tangent plane
                let rx = xi * cos(rollRad) - eta * sin(rollRad)
                let ry = xi * sin(rollRad) + eta * cos(rollRad)

                // Gnomonic inverse: tangent-plane (rx, ry) → celestial (ra, dec)
                // This works correctly at all declinations including the pole
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

        context.stroke(path, with: .color(Color.green.opacity(0.8)), lineWidth: 1.5)
        context.fill(path, with: .color(Color.green.opacity(0.05)))
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
        context.stroke(
            horizonPath,
            with: .color(Color.orange.opacity(0.3)),
            style: StrokeStyle(lineWidth: 1.0, dash: [6, 4])
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
        let infoText = Text("FOV: \(String(format: "%.1f", viewModel.mapFOV))°  Center: \(String(format: "%.1f", viewModel.centerRA / 15.0))h \(String(format: "%+.1f", viewModel.centerDec))°")
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

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                if dragStart == nil {
                    dragStart = value.startLocation
                    dragStartCenter = (viewModel.centerRA, viewModel.centerDec)
                    viewModel.followMount = false  // detach from mount
                }
                guard let startCenter = dragStartCenter else { return }

                let dx = value.translation.width
                let dy = value.translation.height
                let halfSize = min(size.width, size.height) / 2.0

                // RA increases left, so dx>0 means RA increases
                let deltaRA = dx / halfSize * viewModel.mapFOV / 2.0
                let deltaDec = dy / halfSize * viewModel.mapFOV / 2.0

                viewModel.centerRA = (startCenter.ra + deltaRA).truncatingRemainder(dividingBy: 360.0)
                if viewModel.centerRA < 0 { viewModel.centerRA += 360.0 }
                viewModel.centerDec = max(-90, min(90, startCenter.dec + deltaDec))
            }
            .onEnded { _ in
                dragStart = nil
                dragStartCenter = nil
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

                // Check Messier objects (within ~15px)
                for obj in messierCatalog {
                    guard let p = viewModel.projectFast(raDeg: obj.raDeg, decDeg: obj.decDeg) else { continue }
                    let sp = viewModel.toScreen(p, size: size)
                    let dist = hypot(sp.x - point.x, sp.y - point.y)
                    if dist < 15 {
                        viewModel.selectedTarget = (name: "\(obj.id) \(obj.name)", raHours: obj.raHours, decDeg: obj.decDeg)
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
