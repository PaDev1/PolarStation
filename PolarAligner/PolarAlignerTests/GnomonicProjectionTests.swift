import XCTest
import PolarCore
@testable import PolarStation

/// Tests for GnomonicProjection utilities: Rodrigues' rotation, misaligned pole
/// computation, and gnomonic projection.
final class GnomonicProjectionTests: XCTestCase {

    // MARK: - Celestial ↔ Cartesian Round-trip

    func testCelestialCartesianRoundTrip() {
        let positions: [(ra: Double, dec: Double)] = [
            (0.0, 0.0),
            (90.0, 45.0),
            (180.0, -30.0),
            (270.0, 89.0),
            (0.0, -89.0),
            (123.456, 67.89),
        ]

        for pos in positions {
            let cart = GnomonicProjection.celestialToCartesian(raDeg: pos.ra, decDeg: pos.dec)
            let back = GnomonicProjection.cartesianToCelestial(x: cart.x, y: cart.y, z: cart.z)

            var raDiff = abs(back.raDeg - pos.ra)
            if raDiff > 180 { raDiff = 360 - raDiff }
            XCTAssertLessThan(raDiff, 1e-8,
                "RA round-trip failed for (\(pos.ra), \(pos.dec)): got \(back.raDeg)")
            XCTAssertEqual(back.decDeg, pos.dec, accuracy: 1e-8,
                "Dec round-trip failed for (\(pos.ra), \(pos.dec)): got \(back.decDeg)")
        }
    }

    // MARK: - Rodrigues' Rotation

    /// Rotate around the exact north celestial pole (0, 0, 1).
    /// RA should change by exactly the rotation angle; Dec should be unchanged.
    func testRotateAroundNorthPole() {
        let axisRA = 0.0   // RA doesn't matter at Dec=90
        let axisDec = 90.0 // Exact north pole

        let startRA = 100.0
        let startDec = 55.0

        for angle in [30.0, -30.0, 60.0, 90.0, 180.0] {
            let result = GnomonicProjection.rotateAroundAxis(
                pointingRA: startRA, pointingDec: startDec,
                axisRA: axisRA, axisDec: axisDec,
                angleDeg: angle
            )

            // RA should increase by angle (Rodrigues' = counterclockwise = +RA)
            var expectedRA = (startRA + angle).truncatingRemainder(dividingBy: 360)
            if expectedRA < 0 { expectedRA += 360 }
            var raDiff = abs(result.raDeg - expectedRA)
            if raDiff > 180 { raDiff = 360 - raDiff }

            XCTAssertLessThan(raDiff, 0.001,
                "Rotation by \(angle)°: RA should be \(expectedRA), got \(result.raDeg)")
            XCTAssertEqual(result.decDeg, startDec, accuracy: 0.001,
                "Rotation by \(angle)°: Dec should be unchanged (\(startDec)), got \(result.decDeg)")
        }
    }

    /// Two successive rotations of +30° should be equivalent to a single +60° rotation.
    func testRotationAccumulates() {
        let axisRA = 0.0
        let axisDec = 90.0

        let startRA = 200.0
        let startDec = 50.0

        // Single 60° rotation
        let single = GnomonicProjection.rotateAroundAxis(
            pointingRA: startRA, pointingDec: startDec,
            axisRA: axisRA, axisDec: axisDec,
            angleDeg: 60.0
        )

        // Two 30° rotations
        let step1 = GnomonicProjection.rotateAroundAxis(
            pointingRA: startRA, pointingDec: startDec,
            axisRA: axisRA, axisDec: axisDec,
            angleDeg: 30.0
        )
        let step2 = GnomonicProjection.rotateAroundAxis(
            pointingRA: step1.raDeg, pointingDec: step1.decDeg,
            axisRA: axisRA, axisDec: axisDec,
            angleDeg: 30.0
        )

        var raDiff = abs(single.raDeg - step2.raDeg)
        if raDiff > 180 { raDiff = 360 - raDiff }

        XCTAssertLessThan(raDiff, 0.001,
            "Two 30° rotations should equal one 60° rotation. " +
            "Single: RA=\(f(single.raDeg)), Two-step: RA=\(f(step2.raDeg))")
        XCTAssertEqual(single.decDeg, step2.decDeg, accuracy: 0.001,
            "Dec should match: single=\(f(single.decDeg)), two-step=\(f(step2.decDeg))")

        // Also verify the intermediate position is different from start
        var step1RaDiff = abs(step1.raDeg - startRA)
        if step1RaDiff > 180 { step1RaDiff = 360 - step1RaDiff }
        XCTAssertGreaterThan(step1RaDiff, 20,
            "Step 1 should have moved significantly from start RA. " +
            "Start: \(f(startRA)), Step1: \(f(step1.raDeg))")

        print("[Rotation] Start: RA=\(f(startRA)) Dec=\(f(startDec))")
        print("[Rotation] Step1: RA=\(f(step1.raDeg)) Dec=\(f(step1.decDeg))")
        print("[Rotation] Step2: RA=\(f(step2.raDeg)) Dec=\(f(step2.decDeg))")
        print("[Rotation] Single 60°: RA=\(f(single.raDeg)) Dec=\(f(single.decDeg))")
    }

    /// Rotate around a slightly misaligned axis (near the NCP).
    /// Verify that 3 successive rotations produce 3 distinct positions that
    /// are NOT returning to the start.
    func testRotateAroundMisalignedPole() {
        // Axis at Dec=89.8° (0.2° off from NCP)
        let axisRA = 45.0
        let axisDec = 89.8

        let startRA = 200.0
        let startDec = 55.0

        var cameraRA = startRA
        var cameraDec = startDec
        var positions: [(ra: Double, dec: Double)] = [(cameraRA, cameraDec)]

        for _ in 1...3 {
            let result = GnomonicProjection.rotateAroundAxis(
                pointingRA: cameraRA, pointingDec: cameraDec,
                axisRA: axisRA, axisDec: axisDec,
                angleDeg: 30.0
            )
            cameraRA = result.raDeg
            cameraDec = result.decDeg
            positions.append((cameraRA, cameraDec))
        }

        // All 4 positions should be distinct in RA
        for i in 0..<positions.count {
            for j in (i+1)..<positions.count {
                var raDiff = abs(positions[i].ra - positions[j].ra)
                if raDiff > 180 { raDiff = 360 - raDiff }
                XCTAssertGreaterThan(raDiff, 5.0,
                    "Positions \(i) and \(j) should be distinct. " +
                    "P\(i): RA=\(f(positions[i].ra)), P\(j): RA=\(f(positions[j].ra))")
            }
        }

        print("[MisalignedRotation] Positions:")
        for (i, pos) in positions.enumerated() {
            print("  P\(i): RA=\(f(pos.ra)) Dec=\(f(pos.dec))")
        }
    }

    // MARK: - Misaligned Pole Computation

    /// computeMisalignedPole with zero error should return NCP (Dec≈90°).
    func testMisalignedPoleZeroError() {
        let jd = julianDate(year: 2026, month: 3, day: 10, hour: 22, min: 0, sec: 0)
        let pole = GnomonicProjection.computeMisalignedPole(
            altErrorArcmin: 0,
            azErrorArcmin: 0,
            observerLatDeg: 60.17,
            observerLonDeg: 24.94,
            jd: jd
        )

        XCTAssertGreaterThan(pole.decDeg, 89.9,
            "Zero error should give NCP (Dec≈90°), got Dec=\(pole.decDeg)")
    }

    /// computeMisalignedPole with small errors should return near-NCP axis.
    func testMisalignedPoleSmallError() {
        let jd = julianDate(year: 2026, month: 3, day: 10, hour: 22, min: 0, sec: 0)
        let pole = GnomonicProjection.computeMisalignedPole(
            altErrorArcmin: 10,
            azErrorArcmin: 5,
            observerLatDeg: 60.17,
            observerLonDeg: 24.94,
            jd: jd
        )

        // With 10' alt + 5' az error, the pole should be ~11.2' (0.19°) from NCP
        // So Dec should be > 89°
        XCTAssertGreaterThan(pole.decDeg, 89.0,
            "Small error pole should be close to NCP, got Dec=\(pole.decDeg)")

        print("[MisalignedPole] Error(10', 5') → RA=\(f(pole.raDeg)) Dec=\(f(pole.decDeg))")
    }

    // MARK: - Simulated Alignment Round-trip

    /// Simulate the full 3-point alignment flow:
    /// 1. Compute misaligned pole from injected error
    /// 2. Rotate camera 3 times around misaligned pole
    /// 3. Feed the 3 positions to compute_polar_error
    /// 4. Verify the computed error matches the injected error
    func testSimulatedAlignmentRoundTrip() {
        let injectedAltError = 10.0  // arcminutes
        let injectedAzError = 5.0    // arcminutes
        let observerLat = 60.17
        let observerLon = 24.94

        let jd = julianDate(year: 2026, month: 3, day: 10, hour: 22, min: 0, sec: 0)

        // Step 1: Compute misaligned pole
        let pole = GnomonicProjection.computeMisalignedPole(
            altErrorArcmin: injectedAltError,
            azErrorArcmin: injectedAzError,
            observerLatDeg: observerLat,
            observerLonDeg: observerLon,
            jd: jd
        )

        print("[RoundTrip] Misaligned pole: RA=\(f(pole.raDeg)) Dec=\(f(pole.decDeg))")

        // Step 2: Generate 3 camera positions by rotating around misaligned pole
        let startRA = 200.0
        let startDec = 55.0
        let slewDeg = 30.0

        var cameraRA = startRA
        var cameraDec = startDec
        var solvedCoords: [CelestialCoord] = []

        for step in 1...3 {
            // Record this position (as if plate-solved)
            solvedCoords.append(CelestialCoord(raDeg: cameraRA, decDeg: cameraDec))
            print("[RoundTrip] Step \(step): RA=\(f(cameraRA)) Dec=\(f(cameraDec))")

            // Rotate for next step
            if step < 3 {
                let newPointing = GnomonicProjection.rotateAroundAxis(
                    pointingRA: cameraRA, pointingDec: cameraDec,
                    axisRA: pole.raDeg, axisDec: pole.decDeg,
                    angleDeg: slewDeg
                )
                cameraRA = newPointing.raDeg
                cameraDec = newPointing.decDeg
            }
        }

        // Step 3: All 3 positions should be distinct
        for i in 0..<3 {
            for j in (i+1)..<3 {
                var raDiff = abs(solvedCoords[i].raDeg - solvedCoords[j].raDeg)
                if raDiff > 180 { raDiff = 360 - raDiff }
                XCTAssertGreaterThan(raDiff, 5.0,
                    "Positions \(i+1) and \(j+1) should be distinct. " +
                    "P\(i+1): RA=\(f(solvedCoords[i].raDeg)), " +
                    "P\(j+1): RA=\(f(solvedCoords[j].raDeg))")
            }
        }

        // Step 4: Compute polar error from the 3 positions
        do {
            let error = try computePolarError(
                pos1: solvedCoords[0],
                pos2: solvedCoords[1],
                pos3: solvedCoords[2],
                observerLatDeg: observerLat,
                observerLonDeg: observerLon,
                timestampJd: jd
            )

            print("[RoundTrip] Computed error: Alt=\(f(error.altErrorArcmin))' " +
                  "Az=\(f(error.azErrorArcmin))' Total=\(f(error.totalErrorArcmin))'")
            print("[RoundTrip] Injected error: Alt=\(injectedAltError)' " +
                  "Az=\(injectedAzError)' Total=\(f(sqrt(injectedAltError*injectedAltError + injectedAzError*injectedAzError)))'")

            // The computed error should be close to the injected error
            XCTAssertEqual(error.altErrorArcmin, injectedAltError, accuracy: 2.0,
                "Alt error should match injected (\(injectedAltError)'): got \(f(error.altErrorArcmin))'")
            XCTAssertEqual(error.azErrorArcmin, injectedAzError, accuracy: 2.0,
                "Az error should match injected (\(injectedAzError)'): got \(f(error.azErrorArcmin))'")
        } catch {
            XCTFail("Polar error computation failed: \(error)")
        }
    }

    /// Same round-trip but with perfect alignment (zero error).
    /// The computed error should be near zero.
    func testPerfectAlignmentRoundTrip() {
        let observerLat = 60.17
        let observerLon = 24.94
        let jd = julianDate(year: 2026, month: 3, day: 10, hour: 22, min: 0, sec: 0)

        // Perfect alignment: pole is exactly at NCP
        // Rotate around Dec=90° (NCP)
        let startRA = 200.0
        let startDec = 55.0

        var solvedCoords: [CelestialCoord] = []
        var cameraRA = startRA

        for step in 1...3 {
            solvedCoords.append(CelestialCoord(raDeg: cameraRA, decDeg: startDec))
            if step < 3 {
                cameraRA += 30.0  // Perfect rotation = simple RA change
            }
        }

        do {
            let error = try computePolarError(
                pos1: solvedCoords[0],
                pos2: solvedCoords[1],
                pos3: solvedCoords[2],
                observerLatDeg: observerLat,
                observerLonDeg: observerLon,
                timestampJd: jd
            )

            print("[PerfectAlignment] Error: Alt=\(f(error.altErrorArcmin))' " +
                  "Az=\(f(error.azErrorArcmin))' Total=\(f(error.totalErrorArcmin))'")

            XCTAssertLessThan(error.totalErrorArcmin, 1.0,
                "Perfect alignment should have near-zero error, got \(f(error.totalErrorArcmin))'")
        } catch {
            XCTFail("Polar error computation failed: \(error)")
        }
    }

    // MARK: - Gnomonic Projection

    /// Center of FOV should project to image center.
    func testProjectCenterToImageCenter() {
        let result = GnomonicProjection.projectToPixel(
            starRA: 180.0, starDec: 45.0,
            centerRA: 180.0, centerDec: 45.0,
            rollDeg: 0,
            fovDeg: 3.2,
            imageWidth: 1920, imageHeight: 1080
        )

        XCTAssertNotNil(result, "Center star should project")
        if let r = result {
            XCTAssertEqual(r.x, 960, accuracy: 0.001, "X should be image center")
            XCTAssertEqual(r.y, 540, accuracy: 0.001, "Y should be image center")
        }
    }

    /// Star behind the camera should return nil.
    func testProjectStarBehindCamera() {
        let result = GnomonicProjection.projectToPixel(
            starRA: 0.0, starDec: -45.0,     // Opposite hemisphere
            centerRA: 180.0, centerDec: 45.0, // Camera points elsewhere
            rollDeg: 0,
            fovDeg: 3.2,
            imageWidth: 1920, imageHeight: 1080
        )

        XCTAssertNil(result, "Star behind camera should not project")
    }

    // MARK: - Helpers

    private func f(_ v: Double) -> String { String(format: "%.4f", v) }
}
