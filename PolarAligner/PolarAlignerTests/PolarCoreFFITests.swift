import XCTest
import PolarCore

final class PolarCoreFFITests: XCTestCase {

    func testPolarCoreVersion() {
        let version = polarCoreVersion()
        XCTAssertFalse(version.isEmpty, "Version string should not be empty")
        XCTAssertTrue(version.contains("."), "Version should contain a dot separator")
    }

    func testJulianDateJ2000() {
        let jd = julianDate(year: 2000, month: 1, day: 1, hour: 12, min: 0, sec: 0.0)
        XCTAssertEqual(jd, 2451545.0, accuracy: 0.0001, "J2000.0 epoch should be JD 2451545.0")
    }

    func testLocalSiderealTime() {
        let jd = 2451545.0
        let lst = localSiderealTime(jd: jd, longitudeDeg: 0.0)
        // At Greenwich, LST should equal GMST
        XCTAssertEqual(lst, 280.46, accuracy: 0.1, "LST at Greenwich for J2000.0")
    }

    func testCelestialToAltaz() {
        // North celestial pole altitude should approximately equal observer latitude
        let pole = CelestialCoord(raDeg: 0.0, decDeg: 90.0)
        let lat = 60.17
        let jd = julianDate(year: 2024, month: 3, day: 20, hour: 0, min: 0, sec: 0.0)
        let altaz = celestialToAltaz(
            coord: pole,
            observerLatDeg: lat,
            observerLonDeg: 24.94,
            timestampJd: jd
        )
        XCTAssertEqual(altaz.altDeg, lat, accuracy: 0.1,
                       "Pole altitude should approximately equal latitude")
    }

    func testAngularSeparation() {
        let a = CelestialCoord(raDeg: 0.0, decDeg: 0.0)
        let b = CelestialCoord(raDeg: 0.0, decDeg: 90.0)
        let sep = angularSeparation(a: a, b: b)
        XCTAssertEqual(sep, 90.0, accuracy: 0.0001, "Should be 90 degrees apart")
    }

    func testPlateSolverCreation() {
        let solver = PlateSolver()
        XCTAssertNil(solver.databaseInfo(), "No database should be loaded initially")
    }

    func testPlateSolverNoDatabaseError() {
        let solver = PlateSolver()
        let centroids = [
            StarCentroid(x: 100, y: 100, brightness: 0.8),
            StarCentroid(x: 200, y: 150, brightness: 0.5),
            StarCentroid(x: 50, y: 200, brightness: 0.3),
            StarCentroid(x: 300, y: 50, brightness: 0.6),
        ]
        XCTAssertThrowsError(
            try solver.solve(
                centroids: centroids,
                imageWidth: 1920,
                imageHeight: 1080,
                fovDeg: 10.0,
                fovToleranceDeg: 2.0
            ),
            "Should throw when no database loaded"
        )
    }

    func testMountControllerCreation() {
        let mc = MountController()
        XCTAssertFalse(mc.isConnected(), "Should not be connected initially")
        XCTAssertNil(mc.backendName(), "No backend initially")
    }

    func testMountNotConnectedError() {
        let mc = MountController()
        XCTAssertThrowsError(try mc.getStatus(), "Should throw NotConnected")
        XCTAssertThrowsError(try mc.slewRaDegrees(degrees: 10.0), "Should throw NotConnected")
        XCTAssertThrowsError(try mc.abort(), "Should throw NotConnected")
    }

    func testDiscoverAlpaca() {
        // Just verify it doesn't crash; will be empty without real Alpaca devices
        let devices = discoverAlpaca(timeoutMs: 100)
        _ = devices
    }

    func testListSerialPorts() {
        // Just verify it returns without crashing
        let ports = listSerialPorts()
        _ = ports
    }

    func testComputePolarError() throws {
        // Simulate three observations with a slightly misaligned mount axis.
        // Mount axis pointing at Dec=89.5 instead of 90 → ~30 arcmin total error
        let jd = julianDate(year: 2024, month: 6, day: 15, hour: 22, min: 0, sec: 0.0)
        let lat = 60.17
        let lon = 24.94

        let pos1 = CelestialCoord(raDeg: 10.0, decDeg: 60.0)
        let pos2 = CelestialCoord(raDeg: 40.0, decDeg: 60.0)
        let pos3 = CelestialCoord(raDeg: 70.0, decDeg: 60.0)

        let error = try computePolarError(
            pos1: pos1, pos2: pos2, pos3: pos3,
            observerLatDeg: lat, observerLonDeg: lon,
            timestampJd: jd
        )

        // We just verify it returns without throwing and produces a reasonable result
        XCTAssertGreaterThan(error.totalErrorArcmin, 0.0,
                             "Total error should be positive for non-pole observations")
    }
}
