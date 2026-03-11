import XCTest
import Metal
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
