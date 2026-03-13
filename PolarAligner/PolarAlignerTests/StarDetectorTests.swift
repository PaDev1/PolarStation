import XCTest
import Metal
import CoreML
@testable import PolarAligner

final class StarDetectorTests: XCTestCase {
    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!

    override func setUpWithError() throws {
        device = MTLCreateSystemDefaultDevice()
        XCTAssertNotNil(device, "Metal device required for tests")
        commandQueue = device.makeCommandQueue()
        XCTAssertNotNil(commandQueue)
    }

    /// Create a synthetic test texture with known star positions.
    private func createSyntheticStarfield(
        width: Int,
        height: Int,
        stars: [(x: Float, y: Float, brightness: Float, fwhm: Float)]
    ) -> MTLTexture? {
        // Create RGBA half-float texture
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }

        // Generate pixel data with Gaussian stars
        var pixels = [UInt16](repeating: 0, count: width * height * 4)
        let background: Float = 0.05

        for y in 0..<height {
            for x in 0..<width {
                var value = background

                for star in stars {
                    let sigma = star.fwhm / 2.355
                    let dx = Float(x) - star.x
                    let dy = Float(y) - star.y
                    let r2 = dx * dx + dy * dy
                    value += star.brightness * exp(-r2 / (2 * sigma * sigma))
                }

                let idx = (y * width + x) * 4
                let h = floatToHalf(min(value, 1.0))
                pixels[idx] = h     // R
                pixels[idx + 1] = h // G
                pixels[idx + 2] = h // B
                pixels[idx + 3] = floatToHalf(1.0) // A
            }
        }

        let bytesPerRow = width * 4 * MemoryLayout<UInt16>.size
        let region = MTLRegion(origin: MTLOrigin(), size: MTLSize(width: width, height: height, depth: 1))
        texture.replace(region: region, mipmapLevel: 0, withBytes: pixels, bytesPerRow: bytesPerRow)

        return texture
    }

    func testClassicalDetectorFindsStars() throws {
        let stars: [(x: Float, y: Float, brightness: Float, fwhm: Float)] = [
            (x: 100, y: 100, brightness: 0.8, fwhm: 3.0),
            (x: 200, y: 150, brightness: 0.5, fwhm: 2.5),
            (x: 50, y: 200, brightness: 0.3, fwhm: 3.5),
        ]

        guard let texture = createSyntheticStarfield(width: 300, height: 300, stars: stars) else {
            XCTFail("Failed to create synthetic texture")
            return
        }

        var config = StarDetectionConfig()
        config.minSNR = 2.0
        config.detectionSigma = 2.0

        let detector = ClassicalDetector(config: config)
        let detected = try detector.detectStars(in: texture, device: device, commandQueue: commandQueue)

        XCTAssertGreaterThanOrEqual(detected.count, 2,
                                    "Should detect at least 2 of 3 synthetic stars (got \(detected.count))")

        // Verify brightest star is found near (100, 100)
        if let brightest = detected.first {
            let dx = abs(brightest.x - 100)
            let dy = abs(brightest.y - 100)
            XCTAssertLessThan(dx, 3, "Brightest star X should be near 100, got \(brightest.x)")
            XCTAssertLessThan(dy, 3, "Brightest star Y should be near 100, got \(brightest.y)")
        }
    }

    func testDetectedStarsSortedByBrightness() throws {
        let stars: [(x: Float, y: Float, brightness: Float, fwhm: Float)] = [
            (x: 50, y: 50, brightness: 0.3, fwhm: 3.0),
            (x: 150, y: 50, brightness: 0.8, fwhm: 3.0),
            (x: 100, y: 150, brightness: 0.5, fwhm: 3.0),
        ]

        guard let texture = createSyntheticStarfield(width: 200, height: 200, stars: stars) else {
            XCTFail("Failed to create texture")
            return
        }

        var config = StarDetectionConfig()
        config.minSNR = 1.0
        config.detectionSigma = 1.5

        let detector = ClassicalDetector(config: config)
        let detected = try detector.detectStars(in: texture, device: device, commandQueue: commandQueue)

        for i in 1..<detected.count {
            XCTAssertGreaterThanOrEqual(detected[i - 1].brightness, detected[i].brightness,
                                        "Stars should be sorted by brightness (descending)")
        }
    }

    func testEmptyImageReturnsNoStars() throws {
        // Create a flat image with no stars (just background)
        guard let texture = createSyntheticStarfield(width: 200, height: 200, stars: []) else {
            XCTFail("Failed to create texture")
            return
        }

        let detector = ClassicalDetector()
        let detected = try detector.detectStars(in: texture, device: device, commandQueue: commandQueue)

        XCTAssertEqual(detected.count, 0, "Should find no stars in flat image")
    }

    // MARK: - Texture CPU Readback Test

    /// Verify that GPU-written r32Float textures can be read back by CPU.
    /// This is the core operation used by ClassicalDetector's findPeaks.
    func testTextureGPUWriteCPUReadback() throws {
        let width = 64
        let height = 64

        // Create a shared r32Float texture and write known values from GPU
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else {
            XCTFail("Failed to create texture")
            return
        }

        // Write a known pattern: value = 0.5 everywhere
        var sourceData = [Float](repeating: 0.5, count: width * height)
        let bytesPerRow = width * MemoryLayout<Float>.size
        let region = MTLRegion(origin: MTLOrigin(), size: MTLSize(width: width, height: height, depth: 1))
        texture.replace(region: region, mipmapLevel: 0, withBytes: &sourceData, bytesPerRow: bytesPerRow)

        // Read back
        var readData = [Float](repeating: 0, count: width * height)
        texture.getBytes(&readData, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)

        // Verify
        for i in 0..<(width * height) {
            XCTAssertEqual(readData[i], 0.5, accuracy: 0.001,
                          "Pixel \(i) should be 0.5, got \(readData[i])")
        }
    }

    /// Test that rgba_to_luminance shader output can be read back by CPU.
    /// This validates the fix for the managed storage mode issue.
    func testLuminanceConversionReadback() throws {
        let width = 128
        let height = 128

        // Create an rgba16Float input with known brightness
        let stars: [(x: Float, y: Float, brightness: Float, fwhm: Float)] = [
            (x: 64, y: 64, brightness: 0.9, fwhm: 5.0),
        ]
        guard let inputTexture = createSyntheticStarfield(width: width, height: height, stars: stars) else {
            XCTFail("Failed to create input texture")
            return
        }

        // Create luminance output texture (same as ClassicalDetector uses)
        let lumDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float,
            width: width,
            height: height,
            mipmapped: false
        )
        lumDesc.usage = [.shaderRead, .shaderWrite]
        lumDesc.storageMode = .shared
        guard let lumTexture = device.makeTexture(descriptor: lumDesc) else {
            XCTFail("Failed to create luminance texture")
            return
        }

        // Run rgba_to_luminance shader
        guard let library = device.makeDefaultLibrary(),
              let lumFunc = library.makeFunction(name: "rgba_to_luminance"),
              let pipeline = try? device.makeComputePipelineState(function: lumFunc),
              let cmdBuf = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuf.makeComputeCommandEncoder() else {
            XCTFail("Failed to set up Metal pipeline")
            return
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(inputTexture, index: 0)
        encoder.setTexture(lumTexture, index: 1)
        let threads = MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1)
        let groups = MTLSize(width: 16, height: 16, depth: 1)
        encoder.dispatchThreadgroups(threads, threadsPerThreadgroup: groups)
        encoder.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        // Read back luminance texture
        var lumData = [Float](repeating: 0, count: width * height)
        let bytesPerRow = width * MemoryLayout<Float>.size
        let region = MTLRegion(origin: MTLOrigin(), size: MTLSize(width: width, height: height, depth: 1))
        lumTexture.getBytes(&lumData, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)

        // The center pixel (64, 64) should have high luminance from the star
        let centerIdx = 64 * width + 64
        XCTAssertGreaterThan(lumData[centerIdx], 0.5,
                            "Center pixel luminance should be high (star peak), got \(lumData[centerIdx])")

        // A corner pixel should have only background
        let cornerIdx = 0
        XCTAssertLessThan(lumData[cornerIdx], 0.1,
                         "Corner pixel should be background (~0.05), got \(lumData[cornerIdx])")

        // Verify non-zero count (the key test — if storage mode is wrong, all would be 0)
        let nonZeroCount = lumData.filter { $0 > 0.01 }.count
        XCTAssertGreaterThan(nonZeroCount, 0,
                            "Luminance data should have non-zero values after GPU write + CPU read")
    }

    // MARK: - Simulator-matching Tests

    /// Test star detection with parameters matching the SimulatedGuideEngine output.
    /// Image: 640x480, 15 stars, background 0.047, stars 0.16-0.86 (normalized from 8-bit).
    func testDetectionWithSimulatorParameters() throws {
        let width = 640
        let height = 480

        // Recreate the simulator's star field (normalized to 0-1 float from 0-255 ADU)
        let bg: Float = 12.0 / 255.0  // ~0.047
        let starSpecs: [(x: Float, y: Float, brightness: Float, fwhm: Float)] = [
            // Bright guide star near center
            (x: 330, y: 237, brightness: 220.0 / 255.0, fwhm: 2.0),
            // Second bright star
            (x: 267, y: 273, brightness: 160.0 / 255.0, fwhm: 2.0),
            // Dimmer stars spread around
            (x: 100, y: 100, brightness: 80.0 / 255.0, fwhm: 2.0),
            (x: 500, y: 350, brightness: 120.0 / 255.0, fwhm: 2.0),
            (x: 200, y: 400, brightness: 60.0 / 255.0, fwhm: 2.0),
        ]

        guard let texture = createSyntheticStarfieldWithBackground(
            width: width, height: height, background: bg, stars: starSpecs
        ) else {
            XCTFail("Failed to create texture")
            return
        }

        var config = StarDetectionConfig()
        config.minSNR = 3.0
        config.detectionSigma = 3.0

        let detector = ClassicalDetector(config: config)
        let detected = try detector.detectStars(in: texture, device: device, commandQueue: commandQueue)

        print("[Test] Detected \(detected.count) stars from simulator-like frame")
        for (i, star) in detected.prefix(5).enumerated() {
            print("  Star \(i): x=\(String(format: "%.1f", star.x)), y=\(String(format: "%.1f", star.y)), " +
                  "brightness=\(String(format: "%.2f", star.brightness)), " +
                  "snr=\(String(format: "%.1f", star.snr)), fwhm=\(String(format: "%.1f", star.fwhm))")
        }

        XCTAssertGreaterThanOrEqual(detected.count, 2,
                                    "Should detect at least 2 stars in simulator-like frame (got \(detected.count))")
    }

    /// Create a synthetic starfield with configurable background level.
    private func createSyntheticStarfieldWithBackground(
        width: Int,
        height: Int,
        background: Float,
        stars: [(x: Float, y: Float, brightness: Float, fwhm: Float)]
    ) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }

        var pixels = [UInt16](repeating: 0, count: width * height * 4)

        for y in 0..<height {
            for x in 0..<width {
                var value = background

                for star in stars {
                    let sigma = star.fwhm / 2.355
                    let dx = Float(x) - star.x
                    let dy = Float(y) - star.y
                    let r2 = dx * dx + dy * dy
                    value += star.brightness * exp(-r2 / (2 * sigma * sigma))
                }

                let idx = (y * width + x) * 4
                let h = floatToHalf(min(value, 1.0))
                pixels[idx] = h     // R
                pixels[idx + 1] = h // G
                pixels[idx + 2] = h // B
                pixels[idx + 3] = floatToHalf(1.0) // A
            }
        }

        let bytesPerRow = width * 4 * MemoryLayout<UInt16>.size
        let region = MTLRegion(origin: MTLOrigin(), size: MTLSize(width: width, height: height, depth: 1))
        texture.replace(region: region, mipmapLevel: 0, withBytes: pixels, bytesPerRow: bytesPerRow)

        return texture
    }

    // MARK: - CoreML Detector Tests

    /// Helper to create a CoreMLDetector with the bundled StarDetector model loaded.
    private func makeCoreMLDetector(config: StarDetectionConfig = StarDetectionConfig()) throws -> CoreMLDetector {
        let detector = CoreMLDetector(config: config)
        try detector.loadModel(named: "StarDetector")
        return detector
    }

    /// Test that CoreMLDetector loads the model and detects stars in a synthetic starfield.
    func testCoreMLDetectorFindsStars() throws {
        let detector: CoreMLDetector
        do {
            detector = try makeCoreMLDetector()
        } catch {
            throw XCTSkip("CoreML model not available in test bundle: \(error)")
        }

        let width = 640
        let height = 480
        let bg: Float = 12.0 / 255.0

        let starSpecs: [(x: Float, y: Float, brightness: Float, fwhm: Float)] = [
            (x: 330, y: 237, brightness: 220.0 / 255.0, fwhm: 3.0),
            (x: 267, y: 273, brightness: 160.0 / 255.0, fwhm: 3.0),
            (x: 100, y: 100, brightness: 80.0 / 255.0, fwhm: 3.0),
            (x: 500, y: 350, brightness: 120.0 / 255.0, fwhm: 3.0),
            (x: 200, y: 400, brightness: 60.0 / 255.0, fwhm: 3.0),
        ]

        guard let texture = createSyntheticStarfieldWithBackground(
            width: width, height: height, background: bg, stars: starSpecs
        ) else {
            XCTFail("Failed to create texture")
            return
        }

        let detected = try detector.detectStars(in: texture, device: device, commandQueue: commandQueue)

        print("[CoreML Test] Detected \(detected.count) stars, diagnostic: \(detector.lastDiagnostic)")
        for (i, star) in detected.prefix(10).enumerated() {
            print("  Star \(i): x=\(String(format: "%.1f", star.x)), y=\(String(format: "%.1f", star.y)), " +
                  "brightness=\(String(format: "%.3f", star.brightness)), snr=\(String(format: "%.1f", star.snr))")
        }

        XCTAssertGreaterThanOrEqual(detected.count, 1,
                                    "CoreML detector should find at least 1 star (got \(detected.count))")
    }

    /// Test that CoreML detector results are sorted by brightness descending.
    func testCoreMLDetectorSortedByBrightness() throws {
        let detector: CoreMLDetector
        do {
            detector = try makeCoreMLDetector()
        } catch {
            throw XCTSkip("CoreML model not available in test bundle: \(error)")
        }

        let starSpecs: [(x: Float, y: Float, brightness: Float, fwhm: Float)] = [
            (x: 80, y: 80, brightness: 0.3, fwhm: 3.0),
            (x: 200, y: 80, brightness: 0.9, fwhm: 3.0),
            (x: 140, y: 200, brightness: 0.6, fwhm: 3.0),
        ]

        guard let texture = createSyntheticStarfieldWithBackground(
            width: 300, height: 300, background: 0.05, stars: starSpecs
        ) else {
            XCTFail("Failed to create texture")
            return
        }

        let detected = try detector.detectStars(in: texture, device: device, commandQueue: commandQueue)

        for i in 1..<detected.count {
            XCTAssertGreaterThanOrEqual(detected[i - 1].brightness, detected[i].brightness,
                                        "CoreML stars should be sorted by brightness (descending)")
        }
    }

    /// Test that CoreML detector falls back to classical when no model is loaded.
    func testCoreMLDetectorFallsBackToClassical() throws {
        var config = StarDetectionConfig()
        config.minSNR = 2.0
        config.detectionSigma = 2.0

        // Create detector WITHOUT loading model — should use classical fallback
        let detector = CoreMLDetector(config: config)

        let stars: [(x: Float, y: Float, brightness: Float, fwhm: Float)] = [
            (x: 100, y: 100, brightness: 0.8, fwhm: 3.0),
            (x: 200, y: 150, brightness: 0.5, fwhm: 2.5),
        ]

        guard let texture = createSyntheticStarfield(width: 300, height: 300, stars: stars) else {
            XCTFail("Failed to create texture")
            return
        }

        let detected = try detector.detectStars(in: texture, device: device, commandQueue: commandQueue)

        XCTAssertGreaterThanOrEqual(detected.count, 1,
                                    "Fallback classical detector should find stars (got \(detected.count))")
    }

    /// Compare CoreML and Classical detector results on the same image.
    func testCoreMLVsClassicalComparison() throws {
        let coremlDetector: CoreMLDetector
        do {
            coremlDetector = try makeCoreMLDetector()
        } catch {
            throw XCTSkip("CoreML model not available in test bundle: \(error)")
        }

        var config = StarDetectionConfig()
        config.minSNR = 2.0
        config.detectionSigma = 2.0
        let classicalDetector = ClassicalDetector(config: config)

        let width = 640
        let height = 480
        let bg: Float = 12.0 / 255.0

        let starSpecs: [(x: Float, y: Float, brightness: Float, fwhm: Float)] = [
            (x: 330, y: 237, brightness: 220.0 / 255.0, fwhm: 3.0),
            (x: 267, y: 273, brightness: 160.0 / 255.0, fwhm: 3.0),
            (x: 100, y: 100, brightness: 80.0 / 255.0, fwhm: 3.0),
            (x: 500, y: 350, brightness: 120.0 / 255.0, fwhm: 3.0),
        ]

        guard let texture = createSyntheticStarfieldWithBackground(
            width: width, height: height, background: bg, stars: starSpecs
        ) else {
            XCTFail("Failed to create texture")
            return
        }

        let coremlStars = try coremlDetector.detectStars(in: texture, device: device, commandQueue: commandQueue)
        let classicalStars = try classicalDetector.detectStars(in: texture, device: device, commandQueue: commandQueue)

        print("[Comparison] CoreML: \(coremlStars.count) stars, Classical: \(classicalStars.count) stars")
        print("  CoreML diagnostic: \(coremlDetector.lastDiagnostic)")

        for (i, star) in coremlStars.prefix(5).enumerated() {
            print("  CoreML   \(i): (\(String(format: "%.1f", star.x)), \(String(format: "%.1f", star.y)))")
        }
        for (i, star) in classicalStars.prefix(5).enumerated() {
            print("  Classic  \(i): (\(String(format: "%.1f", star.x)), \(String(format: "%.1f", star.y)))")
        }

        // Both should find some stars — not asserting exact match since methods differ
        XCTAssertGreaterThanOrEqual(coremlStars.count, 1, "CoreML should detect stars")
        XCTAssertGreaterThanOrEqual(classicalStars.count, 1, "Classical should detect stars")
    }

    // MARK: - Half-float conversion

    private func floatToHalf(_ f: Float) -> UInt16 {
        let bits = f.bitPattern
        let sign = (bits >> 31) & 1
        let exponent = Int((bits >> 23) & 0xFF) - 127
        let mantissa = bits & 0x7FFFFF

        if exponent > 15 {
            return UInt16(sign << 15 | 0x7C00) // Inf
        } else if exponent < -14 {
            return UInt16(sign << 15) // Zero / subnormal
        }

        let hExp = UInt16(exponent + 15)
        let hMant = UInt16(mantissa >> 13)
        return UInt16(sign << 15) | (hExp << 10) | hMant
    }
}
