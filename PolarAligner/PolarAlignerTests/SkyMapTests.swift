import XCTest
import PolarCore
@testable import PolarAligner

@MainActor
final class SkyMapTests: XCTestCase {

    // MARK: - Projection Tests

    func testProjectionCenter() {
        let vm = SkyMapViewModel()
        vm.centerRA = 180.0
        vm.centerDec = 45.0
        vm.mapFOV = 60.0

        // The center of the projection should map to (0, 0) in normalized coords
        let p = vm.project(raDeg: 180.0, decDeg: 45.0)
        XCTAssertNotNil(p)
        XCTAssertEqual(p!.x, 0.0, accuracy: 1e-6, "Center should project to x=0")
        XCTAssertEqual(p!.y, 0.0, accuracy: 1e-6, "Center should project to y=0")
    }

    func testProjectionNorthOfCenter() {
        let vm = SkyMapViewModel()
        vm.centerRA = 0.0
        vm.centerDec = 45.0
        vm.mapFOV = 60.0

        // A point north of center should have positive y in normalized coords
        let p = vm.project(raDeg: 0.0, decDeg: 50.0)
        XCTAssertNotNil(p)
        XCTAssertEqual(p!.x, 0.0, accuracy: 1e-4, "Same RA should project to x≈0")
        XCTAssertGreaterThan(p!.y, 0.0, "Higher Dec should have positive y (north is up)")
    }

    func testProjectionBackHemisphere() {
        let vm = SkyMapViewModel()
        vm.centerRA = 0.0
        vm.centerDec = 0.0
        vm.mapFOV = 60.0

        // Opposite side of the sky should return nil
        let p = vm.project(raDeg: 180.0, decDeg: 0.0)
        XCTAssertNil(p, "Antipodal point should not project")
    }

    func testScreenToRADecRoundtrip() {
        let vm = SkyMapViewModel()
        vm.centerRA = 100.0
        vm.centerDec = 30.0
        vm.mapFOV = 40.0

        let size = CGSize(width: 800, height: 600)
        let testRA = 105.0
        let testDec = 32.0

        guard let projected = vm.project(raDeg: testRA, decDeg: testDec) else {
            XCTFail("Should be able to project nearby point")
            return
        }
        let screenPt = vm.toScreen(projected, size: size)
        guard let result = vm.screenToRADec(screenPt, size: size) else {
            XCTFail("Should be able to inverse-project")
            return
        }

        XCTAssertEqual(result.raDeg, testRA, accuracy: 0.1, "RA should round-trip")
        XCTAssertEqual(result.decDeg, testDec, accuracy: 0.1, "Dec should round-trip")
    }

    func testScreenToRADecCenter() {
        let vm = SkyMapViewModel()
        vm.centerRA = 45.0
        vm.centerDec = -20.0
        vm.mapFOV = 60.0

        let size = CGSize(width: 800, height: 600)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        guard let result = vm.screenToRADec(center, size: size) else {
            XCTFail("Center should inverse-project")
            return
        }

        XCTAssertEqual(result.raDeg, 45.0, accuracy: 0.01, "Center screen should map to center RA")
        XCTAssertEqual(result.decDeg, -20.0, accuracy: 0.01, "Center screen should map to center Dec")
    }

    // MARK: - Zoom / Pan Tests

    func testZoomIn() {
        let vm = SkyMapViewModel()
        vm.mapFOV = 60.0
        vm.zoom(by: 0.5)
        XCTAssertEqual(vm.mapFOV, 30.0, accuracy: 0.01, "Zooming by 0.5 should halve FOV")
    }

    func testZoomLimits() {
        let vm = SkyMapViewModel()
        vm.mapFOV = 60.0

        // Zoom way in — should clamp to minFOV
        vm.zoom(by: 0.001)
        XCTAssertGreaterThanOrEqual(vm.mapFOV, vm.minFOV, "FOV should not go below minimum")

        // Zoom way out — should clamp to maxFOV
        vm.mapFOV = 60.0
        vm.zoom(by: 100.0)
        XCTAssertLessThanOrEqual(vm.mapFOV, vm.maxFOV, "FOV should not exceed maximum")
    }

    func testPanWrapsRA() {
        let vm = SkyMapViewModel()
        vm.centerRA = 350.0
        vm.pan(deltaRA: 20.0, deltaDec: 0.0)
        XCTAssertEqual(vm.centerRA, 10.0, accuracy: 0.01, "RA should wrap past 360")
    }

    func testPanClampsDec() {
        let vm = SkyMapViewModel()
        vm.centerDec = 85.0
        vm.pan(deltaRA: 0.0, deltaDec: 10.0)
        XCTAssertEqual(vm.centerDec, 90.0, accuracy: 0.01, "Dec should clamp at 90")
    }

    // MARK: - Catalog Tests

    func testMessierCatalogCount() {
        XCTAssertGreaterThanOrEqual(messierCatalog.count, 100, "Should have at least 100 Messier objects")
    }

    func testMessierCatalogCoordinates() {
        for obj in messierCatalog {
            XCTAssertGreaterThanOrEqual(obj.raDeg, 0.0, "\(obj.id) RA should be >= 0")
            XCTAssertLessThan(obj.raDeg, 360.0, "\(obj.id) RA should be < 360")
            XCTAssertGreaterThanOrEqual(obj.decDeg, -90.0, "\(obj.id) Dec should be >= -90")
            XCTAssertLessThanOrEqual(obj.decDeg, 90.0, "\(obj.id) Dec should be <= 90")
        }
    }

    func testMessierRAHoursConversion() {
        for obj in messierCatalog {
            XCTAssertEqual(obj.raHours, obj.raDeg / 15.0, accuracy: 1e-10,
                           "\(obj.id) raHours should equal raDeg/15")
        }
    }

    func testStarCatalogEmptyWithoutDatabase() {
        // PlateSolver.getStarCatalog() returns empty when no database loaded
        let solver = PlateSolver()
        let stars = solver.getStarCatalog()
        XCTAssertTrue(stars.isEmpty, "Should return empty catalog when no database loaded")
    }

    // MARK: - Mount sync

    func testSyncToMountUpdatesCenter() {
        let vm = SkyMapViewModel()
        vm.centerRA = 0.0
        vm.centerDec = 0.0

        let status = MountStatus(
            connected: true,
            raHours: 6.0,    // = 90°
            decDeg: 45.0,
            altDeg: 0,
            azDeg: 0,
            tracking: true,
            slewing: false,
            trackingRate: 0,
            atPark: false
        )
        vm.syncToMount(status: status)

        XCTAssertEqual(vm.centerRA, 90.0, accuracy: 0.01, "Should sync center RA to mount")
        XCTAssertEqual(vm.centerDec, 45.0, accuracy: 0.01, "Should sync center Dec to mount")
        XCTAssertEqual(vm.mountRA!, 90.0, accuracy: 0.01)
        XCTAssertEqual(vm.mountDec!, 45.0, accuracy: 0.01)
    }

    func testSyncToMountIgnoresDisconnected() {
        let vm = SkyMapViewModel()
        vm.centerRA = 10.0
        vm.centerDec = 20.0

        let status = MountStatus(
            connected: false,
            raHours: 12.0,
            decDeg: 60.0,
            altDeg: 0,
            azDeg: 0,
            tracking: false,
            slewing: false,
            trackingRate: 0,
            atPark: false
        )
        vm.syncToMount(status: status)

        XCTAssertEqual(vm.centerRA, 10.0, accuracy: 0.01, "Should not change when disconnected")
        XCTAssertEqual(vm.centerDec, 20.0, accuracy: 0.01)
    }
}
