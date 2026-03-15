import XCTest
import PolarCore
@testable import PolarAligner

/// Integration tests for the plate solver pipeline.
///
/// These tests load the real star catalog database, project catalog stars
/// onto a virtual sensor using gnomonic projection, and verify that the
/// plate solver correctly recovers the known camera pointing.
///
/// Requires `polar-core/data/star_catalog.rkyv` to be present (skipped otherwise).
final class PlateSolverTests: XCTestCase {

    // Shared solver — loaded once for all tests (992MB database).
    private static var solver: PlateSolver?
    private static var catalog: [CatalogStar] = []
    private static var catalogPath: String = ""

    override class func setUp() {
        super.setUp()

        // Compute path: test file → PolarAlignerTests/ → PolarAligner/ → project root
        let testDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectRoot = testDir
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        catalogPath = projectRoot
            .appendingPathComponent("polar-core/data/star_catalog.rkyv")
            .path

        guard FileManager.default.fileExists(atPath: catalogPath) else { return }

        let s = PlateSolver()
        do {
            try s.loadDatabase(path: catalogPath)
            solver = s
            catalog = s.getStarCatalog()
        } catch {
            print("[PlateSolverTests] Failed to load database: \(error)")
        }
    }

    private func requireSolver() throws -> PlateSolver {
        guard let s = Self.solver else {
            throw XCTSkip("Star catalog not available at \(Self.catalogPath)")
        }
        return s
    }

    // MARK: - Database Tests

    func testLoadDatabaseAndInfo() throws {
        let solver = try requireSolver()
        let info = solver.databaseInfo()
        XCTAssertNotNil(info, "Database info should be available")

        let catalog = solver.getStarCatalog()
        XCTAssertGreaterThan(catalog.count, 10_000,
            "Catalog should have >10k stars (got \(catalog.count))")
    }

    func testCatalogStarsHaveValidCoordinates() throws {
        _ = try requireSolver()

        for star in Self.catalog.prefix(1000) {
            XCTAssertGreaterThanOrEqual(star.raDeg, 0, "RA should be >= 0")
            XCTAssertLessThan(star.raDeg, 360, "RA should be < 360")
            XCTAssertGreaterThanOrEqual(star.decDeg, -90, "Dec should be >= -90")
            XCTAssertLessThanOrEqual(star.decDeg, 90, "Dec should be <= 90")
            XCTAssertLessThanOrEqual(star.magnitude, 12, "Magnitude should be reasonable")
        }
    }

    // MARK: - Plate Solve Tests

    /// Solve at a known position with perfect centroids (no noise).
    func testSolveKnownPosition() throws {
        let solver = try requireSolver()

        let targetRA = 180.0
        let targetDec = 45.0
        let fovDeg = 3.2
        let w = 1920, h = 1080

        let centroids = projectCatalogToCentroids(
            cameraRA: targetRA, cameraDec: targetDec,
            rollDeg: 0, fovDeg: fovDeg, imageWidth: w, imageHeight: h
        )

        XCTAssertGreaterThanOrEqual(centroids.count, 4,
            "Need >= 4 stars in FOV (got \(centroids.count))")

        let result = try solver.solve(
            centroids: centroids,
            imageWidth: UInt32(w), imageHeight: UInt32(h),
            fovDeg: fovDeg, fovToleranceDeg: 1.0
        )

        XCTAssertTrue(result.success, "Plate solve should succeed")
        assertPositionClose(result: result, expectedRA: targetRA, expectedDec: targetDec,
                            toleranceDeg: 0.1, message: "RA=180, Dec=45")
        XCTAssertGreaterThan(result.matchedStars, 0, "Should have matched stars")
        print("[Solve] RA=\(f(result.raDeg)) Dec=\(f(result.decDeg)) " +
              "matched=\(result.matchedStars) time=\(f(result.solveTimeMs))ms " +
              "RMSE=\(f(result.rmseArcsec))\"  centroids=\(centroids.count)")
    }

    /// Solve at several positions across the sky to verify coverage.
    func testSolveMultiplePositions() throws {
        let solver = try requireSolver()

        let positions: [(ra: Double, dec: Double, label: String)] = [
            (0.0,    60.0,  "RA=0, Dec=60 (near NCP)"),
            (90.0,   30.0,  "RA=90, Dec=30"),
            (180.0,  0.0,   "RA=180, Dec=0 (equator)"),
            (270.0, -30.0,  "RA=270, Dec=-30"),
            (45.0,   80.0,  "RA=45, Dec=80 (high dec)"),
            (315.0,  45.0,  "RA=315, Dec=45"),
        ]

        let fovDeg = 3.2
        let w = 1920, h = 1080
        var solvedCount = 0

        for pos in positions {
            let centroids = projectCatalogToCentroids(
                cameraRA: pos.ra, cameraDec: pos.dec,
                rollDeg: 0, fovDeg: fovDeg, imageWidth: w, imageHeight: h
            )

            guard centroids.count >= 4 else {
                print("[Skip] \(pos.label): only \(centroids.count) stars in FOV")
                continue
            }

            do {
                let result = try solver.solve(
                    centroids: centroids,
                    imageWidth: UInt32(w), imageHeight: UInt32(h),
                    fovDeg: fovDeg, fovToleranceDeg: 1.0
                )

                if result.success {
                    assertPositionClose(result: result, expectedRA: pos.ra, expectedDec: pos.dec,
                                        toleranceDeg: 0.15, message: pos.label)
                    solvedCount += 1
                    print("[OK]   \(pos.label): RA=\(f(result.raDeg)) Dec=\(f(result.decDeg)) " +
                          "matched=\(result.matchedStars) time=\(f(result.solveTimeMs))ms")
                } else {
                    print("[FAIL] \(pos.label): solve returned success=false")
                }
            } catch {
                print("[ERR]  \(pos.label): \(error)")
            }
        }

        XCTAssertGreaterThanOrEqual(solvedCount, 4,
            "Should solve at least 4 of \(positions.count) positions (got \(solvedCount))")
    }

    /// Solve with camera roll applied — the solver should still find the correct RA/Dec.
    func testSolveWithCameraRoll() throws {
        let solver = try requireSolver()

        let targetRA = 120.0
        let targetDec = 50.0
        let fovDeg = 3.2
        let w = 1920, h = 1080

        for roll in [0.0, 45.0, 90.0, 180.0, 270.0] {
            let centroids = projectCatalogToCentroids(
                cameraRA: targetRA, cameraDec: targetDec,
                rollDeg: roll, fovDeg: fovDeg, imageWidth: w, imageHeight: h
            )

            guard centroids.count >= 4 else { continue }

            let result = try solver.solve(
                centroids: centroids,
                imageWidth: UInt32(w), imageHeight: UInt32(h),
                fovDeg: fovDeg, fovToleranceDeg: 1.0
            )

            XCTAssertTrue(result.success, "Should solve at roll=\(roll)°")
            if result.success {
                assertPositionClose(result: result, expectedRA: targetRA, expectedDec: targetDec,
                                    toleranceDeg: 0.15, message: "roll=\(roll)°")
                print("[Roll \(Int(roll))°] RA=\(f(result.raDeg)) Dec=\(f(result.decDeg)) " +
                      "solved_roll=\(f(result.rollDeg)) matched=\(result.matchedStars)")
            }
        }
    }

    /// Solve with small random offsets added to centroids (simulating detection noise).
    func testSolveWithNoisyCentroids() throws {
        let solver = try requireSolver()

        let targetRA = 200.0
        let targetDec = 35.0
        let fovDeg = 3.2
        let w = 1920, h = 1080

        let cleanCentroids = projectCatalogToCentroids(
            cameraRA: targetRA, cameraDec: targetDec,
            rollDeg: 15, fovDeg: fovDeg, imageWidth: w, imageHeight: h
        )
        XCTAssertGreaterThanOrEqual(cleanCentroids.count, 4)

        // Add 1-pixel RMS noise to each centroid
        let noisyPixels = 1.0
        let noisyCentroids = cleanCentroids.map { c in
            StarCentroid(
                x: c.x + Double.random(in: -noisyPixels...noisyPixels),
                y: c.y + Double.random(in: -noisyPixels...noisyPixels),
                brightness: c.brightness
            )
        }

        let result = try solver.solve(
            centroids: noisyCentroids,
            imageWidth: UInt32(w), imageHeight: UInt32(h),
            fovDeg: fovDeg, fovToleranceDeg: 1.0
        )

        XCTAssertTrue(result.success, "Should solve with 1px noise")
        if result.success {
            assertPositionClose(result: result, expectedRA: targetRA, expectedDec: targetDec,
                                toleranceDeg: 0.2, message: "noisy centroids")
            print("[Noisy] RA=\(f(result.raDeg)) Dec=\(f(result.decDeg)) " +
                  "RMSE=\(f(result.rmseArcsec))\" matched=\(result.matchedStars)")
        }
    }

    /// Solve with different FOV values.
    func testSolveWithDifferentFOV() throws {
        let solver = try requireSolver()

        let targetRA = 150.0
        let targetDec = 55.0
        let w = 1920, h = 1080

        // Test with wider and narrower FOVs
        let fovs: [(fov: Double, tolerance: Double, label: String)] = [
            (1.5, 0.5, "narrow 1.5°"),
            (3.2, 1.0, "standard 3.2°"),
            (5.0, 1.5, "wide 5.0°"),
            (10.0, 3.0, "very wide 10.0°"),
        ]

        for fovSpec in fovs {
            let centroids = projectCatalogToCentroids(
                cameraRA: targetRA, cameraDec: targetDec,
                rollDeg: 0, fovDeg: fovSpec.fov, imageWidth: w, imageHeight: h
            )

            guard centroids.count >= 4 else {
                print("[Skip] \(fovSpec.label): only \(centroids.count) stars")
                continue
            }

            do {
                let result = try solver.solve(
                    centroids: centroids,
                    imageWidth: UInt32(w), imageHeight: UInt32(h),
                    fovDeg: fovSpec.fov, fovToleranceDeg: fovSpec.tolerance
                )

                if result.success {
                    assertPositionClose(result: result, expectedRA: targetRA, expectedDec: targetDec,
                                        toleranceDeg: 0.2, message: fovSpec.label)
                    print("[FOV \(fovSpec.label)] RA=\(f(result.raDeg)) Dec=\(f(result.decDeg)) " +
                          "solved_fov=\(f(result.fovDeg))° matched=\(result.matchedStars) " +
                          "centroids=\(centroids.count)")
                } else {
                    print("[FAIL] \(fovSpec.label): solve returned success=false")
                }
            } catch {
                print("[ERR]  \(fovSpec.label): \(error) (\(centroids.count) centroids)")
            }
        }
    }

    /// Garbage centroids should fail gracefully (NoMatch, not crash).
    func testSolveFailsWithRandomCentroids() throws {
        let solver = try requireSolver()

        var randomCentroids: [StarCentroid] = []
        for _ in 0..<20 {
            randomCentroids.append(StarCentroid(
                x: Double.random(in: 0...1920),
                y: Double.random(in: 0...1080),
                brightness: Double.random(in: 0.1...1.0)
            ))
        }

        XCTAssertThrowsError(
            try solver.solve(
                centroids: randomCentroids,
                imageWidth: 1920, imageHeight: 1080,
                fovDeg: 3.2, fovToleranceDeg: 1.0
            ),
            "Random centroids should not produce a valid solve"
        )
    }

    /// Too few centroids should throw TooFewCentroids.
    func testSolveFailsWithTooFewCentroids() throws {
        let solver = try requireSolver()

        let centroids = [
            StarCentroid(x: 100, y: 100, brightness: 0.8),
            StarCentroid(x: 500, y: 300, brightness: 0.5),
        ]

        XCTAssertThrowsError(
            try solver.solve(
                centroids: centroids,
                imageWidth: 1920, imageHeight: 1080,
                fovDeg: 3.2, fovToleranceDeg: 1.0
            ),
            "Should throw with < 4 centroids"
        )
    }

    /// Full pipeline: project → detect (via detector) → solve.
    /// This tests the same path as SimulatedAlignmentEngine.
    func testFullPipelineProjectDetectSolve() throws {
        let solver = try requireSolver()

        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw XCTSkip("No Metal device available")
        }

        let targetRA = 160.0
        let targetDec = 40.0
        let fovDeg = 3.2
        let w = 1920, h = 1080

        // 1. Project catalog stars
        let visibleStars = projectVisibleStars(
            cameraRA: targetRA, cameraDec: targetDec,
            rollDeg: 15, fovDeg: fovDeg, imageWidth: w, imageHeight: h
        )
        XCTAssertGreaterThanOrEqual(visibleStars.count, 4,
            "Need visible stars for detection")

        // 2. Render star field to Metal texture
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false
        )
        texDesc.usage = [.shaderRead, .shaderWrite]
        texDesc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: texDesc) else {
            XCTFail("Failed to create Metal texture")
            return
        }

        let pixelBuffer = renderStarFieldToBuffer(
            stars: visibleStars, width: w, height: h,
            fovDeg: fovDeg, seeingFWHM: 2.5
        )

        let bytesPerRow = w * 4 * MemoryLayout<UInt16>.size
        let region = MTLRegion(origin: MTLOrigin(), size: MTLSize(width: w, height: h, depth: 1))
        texture.replace(region: region, mipmapLevel: 0, withBytes: pixelBuffer, bytesPerRow: bytesPerRow)

        // 3. Detect stars using classical detector
        let detector = ClassicalDetector()
        let detected = try detector.detectStars(in: texture, device: device, commandQueue: commandQueue)

        print("[Pipeline] Visible catalog stars: \(visibleStars.count), Detected: \(detected.count)")
        XCTAssertGreaterThanOrEqual(detected.count, 4,
            "Detector should find >= 4 stars (found \(detected.count))")

        // 4. Plate solve
        let centroids = detected.map { StarCentroid(x: $0.x, y: $0.y, brightness: $0.brightness) }
        let result = try solver.solve(
            centroids: centroids,
            imageWidth: UInt32(w), imageHeight: UInt32(h),
            fovDeg: fovDeg, fovToleranceDeg: 1.0
        )

        XCTAssertTrue(result.success, "Full pipeline solve should succeed")
        if result.success {
            assertPositionClose(result: result, expectedRA: targetRA, expectedDec: targetDec,
                                toleranceDeg: 0.2, message: "full pipeline")
            print("[Pipeline] Solved: RA=\(f(result.raDeg)) Dec=\(f(result.decDeg)) " +
                  "matched=\(result.matchedStars) RMSE=\(f(result.rmseArcsec))\" " +
                  "time=\(f(result.solveTimeMs))ms")
        }
    }

    // MARK: - Helpers

    /// Project catalog stars to pixel centroids at a given camera pointing.
    private func projectCatalogToCentroids(
        cameraRA: Double, cameraDec: Double,
        rollDeg: Double, fovDeg: Double,
        imageWidth: Int, imageHeight: Int
    ) -> [StarCentroid] {
        var centroids: [StarCentroid] = []

        for star in Self.catalog {
            guard star.magnitude <= 10.0 else { continue }

            guard let pixel = GnomonicProjection.projectToPixel(
                starRA: star.raDeg, starDec: star.decDeg,
                centerRA: cameraRA, centerDec: cameraDec,
                rollDeg: rollDeg,
                fovDeg: fovDeg,
                imageWidth: imageWidth, imageHeight: imageHeight
            ) else { continue }

            // Only include stars within the sensor bounds
            guard pixel.x >= 0 && pixel.x < Double(imageWidth) &&
                  pixel.y >= 0 && pixel.y < Double(imageHeight) else { continue }

            let brightness = Double(GnomonicProjection.magnitudeToBrightness(star.magnitude))
            centroids.append(StarCentroid(x: pixel.x, y: pixel.y, brightness: brightness))
        }

        return centroids
    }

    /// Project catalog stars and return visible star tuples (for rendering).
    private func projectVisibleStars(
        cameraRA: Double, cameraDec: Double,
        rollDeg: Double, fovDeg: Double,
        imageWidth: Int, imageHeight: Int
    ) -> [(x: Double, y: Double, brightness: Float)] {
        var visible: [(x: Double, y: Double, brightness: Float)] = []

        for star in Self.catalog {
            guard star.magnitude <= 10.5 else { continue }

            guard let pixel = GnomonicProjection.projectToPixel(
                starRA: star.raDeg, starDec: star.decDeg,
                centerRA: cameraRA, centerDec: cameraDec,
                rollDeg: rollDeg,
                fovDeg: fovDeg,
                imageWidth: imageWidth, imageHeight: imageHeight
            ) else { continue }

            guard pixel.x >= -20 && pixel.x < Double(imageWidth) + 20 &&
                  pixel.y >= -20 && pixel.y < Double(imageHeight) + 20 else { continue }

            let brightness = GnomonicProjection.magnitudeToBrightness(star.magnitude)
            guard brightness > 0.003 else { continue }
            visible.append((x: pixel.x, y: pixel.y, brightness: brightness))
        }

        return visible
    }

    /// Render star field into a half-float pixel buffer (same as SimulatedAlignmentEngine).
    private func renderStarFieldToBuffer(
        stars: [(x: Double, y: Double, brightness: Float)],
        width: Int, height: Int,
        fovDeg: Double, seeingFWHM: Double
    ) -> [UInt16] {
        var buffer = [UInt16](repeating: 0, count: width * height * 4)

        let bgLevel: Float = 0.04
        let noiseStd: Float = 0.012
        let oneHalf = floatToHalf(1.0)

        // Fill background + noise
        for y in 0..<height {
            for x in 0..<width {
                let u1 = Double.random(in: 0.0001...1.0)
                let u2 = Double.random(in: 0.0...1.0)
                let noise = Float(sqrt(-2.0 * log(u1)) * cos(2.0 * .pi * u2)) * noiseStd
                let val = max(0, bgLevel + noise)
                let hval = floatToHalf(val)
                let idx = (y * width + x) * 4
                buffer[idx] = hval
                buffer[idx + 1] = hval
                buffer[idx + 2] = hval
                buffer[idx + 3] = oneHalf
            }
        }

        // Render stars as Gaussian PSFs
        let pixelScaleArcsec = (fovDeg * 3600.0) / Double(width)
        let sigmaPix = max(1.5, (seeingFWHM / pixelScaleArcsec) / 2.35)

        for star in stars {
            let radius = Int(ceil(sigmaPix * 4))
            let x0 = max(0, Int(star.x) - radius)
            let x1 = min(width - 1, Int(star.x) + radius)
            let y0 = max(0, Int(star.y) - radius)
            let y1 = min(height - 1, Int(star.y) + radius)
            guard x0 <= x1 && y0 <= y1 else { continue }
            let twoSigmaSq = 2.0 * sigmaPix * sigmaPix

            for y in y0...y1 {
                let dy = Double(y) - star.y
                let dySq = dy * dy
                for x in x0...x1 {
                    let dx = Double(x) - star.x
                    let distSq = dx * dx + dySq
                    let intensity = Float(Double(star.brightness) * exp(-distSq / twoSigmaSq))

                    if intensity > 0.001 {
                        let idx = (y * width + x) * 4
                        let current = halfToFloat(buffer[idx])
                        let newVal = min(current + intensity, 1.0)
                        let hval = floatToHalf(newVal)
                        buffer[idx] = hval
                        buffer[idx + 1] = hval
                        buffer[idx + 2] = hval
                    }
                }
            }
        }

        return buffer
    }

    /// Assert solved position is close to expected, handling RA wraparound.
    private func assertPositionClose(
        result: SolveResult,
        expectedRA: Double, expectedDec: Double,
        toleranceDeg: Double,
        message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        // Handle RA wraparound (e.g., solved=359.9 vs expected=0.1)
        var raDiff = abs(result.raDeg - expectedRA)
        if raDiff > 180 { raDiff = 360 - raDiff }

        XCTAssertLessThan(raDiff, toleranceDeg,
            "\(message): RA off by \(f(raDiff))° (solved=\(f(result.raDeg)), expected=\(f(expectedRA)))",
            file: file, line: line)
        XCTAssertEqual(result.decDeg, expectedDec, accuracy: toleranceDeg,
            "\(message): Dec off (solved=\(f(result.decDeg)), expected=\(f(expectedDec)))",
            file: file, line: line)
    }

    private func f(_ v: Double) -> String { String(format: "%.3f", v) }

    // MARK: - Half-float Conversion

    private func floatToHalf(_ f: Float) -> UInt16 {
        let bits = f.bitPattern
        let sign = (bits >> 31) & 1
        let exponent = Int((bits >> 23) & 0xFF) - 127
        let mantissa = bits & 0x7FFFFF
        if exponent > 15 { return UInt16(sign << 15 | 0x7C00) }
        if exponent < -14 { return UInt16(sign << 15) }
        let hExp = UInt16(exponent + 15)
        let hMant = UInt16(mantissa >> 13)
        return UInt16(sign << 15) | (hExp << 10) | hMant
    }

    private func halfToFloat(_ h: UInt16) -> Float {
        let sign = (h >> 15) & 1
        let exponent = (h >> 10) & 0x1F
        let mantissa = h & 0x3FF
        if exponent == 0 {
            if mantissa == 0 { return sign == 0 ? 0.0 : -0.0 }
            var m = Float(mantissa) / 1024.0
            m *= pow(2.0, -14.0)
            return sign == 0 ? m : -m
        } else if exponent == 31 {
            return mantissa == 0 ? (sign == 0 ? .infinity : -.infinity) : .nan
        }
        return Float(sign == 0 ? 1 : -1) * pow(2.0, Float(Int(exponent) - 15)) * (1.0 + Float(mantissa) / 1024.0)
    }
}
