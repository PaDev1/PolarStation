import XCTest
@testable import PolarStation

final class FrameSaverTests: XCTestCase {

    // MARK: - Debayer Tests

    /// Create a 4x4 RGGB Bayer pattern with known values (16-bit).
    /// Pattern:
    ///   R  G  R  G       100  50 100  50
    ///   G  B  G  B        50  30  50  30
    ///   R  G  R  G       100  50 100  50
    ///   G  B  G  B        50  30  50  30
    private func rggbTestData16() -> (Data, Int, Int) {
        let w = 4, h = 4
        var pixels = [UInt16](repeating: 0, count: w * h)
        let rVal: UInt16 = 10000
        let gVal: UInt16 = 5000
        let bVal: UInt16 = 3000

        for y in 0..<h {
            for x in 0..<w {
                let px = x % 2
                let py = y % 2
                if px == 0 && py == 0 { pixels[y * w + x] = rVal }       // R
                else if px == 1 && py == 1 { pixels[y * w + x] = bVal }  // B
                else { pixels[y * w + x] = gVal }                         // G
            }
        }

        let data = pixels.withUnsafeBytes { Data($0) }
        return (data, w, h)
    }

    /// Create a 4x4 RGGB Bayer pattern with known values (8-bit).
    private func rggbTestData8() -> (Data, Int, Int) {
        let w = 4, h = 4
        var pixels = [UInt8](repeating: 0, count: w * h)
        let rVal: UInt8 = 200
        let gVal: UInt8 = 100
        let bVal: UInt8 = 60

        for y in 0..<h {
            for x in 0..<w {
                let px = x % 2
                let py = y % 2
                if px == 0 && py == 0 { pixels[y * w + x] = rVal }
                else if px == 1 && py == 1 { pixels[y * w + x] = bVal }
                else { pixels[y * w + x] = gVal }
            }
        }

        return (Data(pixels), w, h)
    }

    func testDebayerInterleavedProduces3Channels16() {
        let (data, w, h) = rggbTestData16()
        let rgb = FrameSaver.debayerToRGBInterleaved(data, width: w, height: h, bytesPerPixel: 2, bayerPattern: "RGGB")

        // Output should be w*h*3 UInt16 values
        XCTAssertEqual(rgb.count, w * h * 3 * 2, "RGB interleaved 16-bit should be \(w*h*3*2) bytes")

        // Check center pixel (1,1) which is a B pixel in RGGB.
        // Its R value should be interpolated from 4 diagonal R neighbors.
        rgb.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: UInt16.self)
            let idx = (1 * w + 1) * 3
            let r = ptr[idx]
            let g = ptr[idx + 1]
            let b = ptr[idx + 2]

            // At (1,1) blue pixel: R comes from 4 diagonals (all 10000), G from 4 neighbors
            XCTAssertEqual(r, 10000, "R at blue pixel should be average of diagonal R neighbors")
            XCTAssertEqual(b, 3000, "B at blue pixel should be the pixel's own value")
            XCTAssertEqual(g, 5000, "G at blue pixel should be average of 4 G neighbors")
        }
    }

    func testDebayerInterleavedProduces3Channels8() {
        let (data, w, h) = rggbTestData8()
        let rgb = FrameSaver.debayerToRGBInterleaved(data, width: w, height: h, bytesPerPixel: 1, bayerPattern: "RGGB")

        XCTAssertEqual(rgb.count, w * h * 3, "RGB interleaved 8-bit should be \(w*h*3) bytes")

        rgb.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: UInt8.self)
            let idx = (1 * w + 1) * 3
            let r = ptr[idx]
            let b = ptr[idx + 2]
            XCTAssertEqual(r, 200, "R at blue pixel from diagonal R neighbors")
            XCTAssertEqual(b, 60, "B at blue pixel is own value")
        }
    }

    func testDebayerPlanarLayout16() {
        let (data, w, h) = rggbTestData16()
        let planar = FrameSaver.debayerToRGBPlanar(data, width: w, height: h, bytesPerPixel: 2, bayerPattern: "RGGB")

        let planeSize = w * h * 2  // bytes per plane
        XCTAssertEqual(planar.count, planeSize * 3, "Planar output should be 3 planes")

        planar.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: UInt16.self)
            let pixelsPerPlane = w * h

            // Check pixel (1,1) in each plane
            let rVal = ptr[1 * w + 1]                     // R plane
            let gVal = ptr[pixelsPerPlane + 1 * w + 1]     // G plane
            let bVal = ptr[2 * pixelsPerPlane + 1 * w + 1] // B plane

            XCTAssertEqual(rVal, 10000)
            XCTAssertEqual(gVal, 5000)
            XCTAssertEqual(bVal, 3000)
        }
    }

    func testLuminanceConversion16() {
        // Create simple interleaved RGB: one pixel with R=10000, G=5000, B=3000
        let r: UInt16 = 10000, g: UInt16 = 5000, b: UInt16 = 3000
        var rgb = [r, g, b]
        let data = rgb.withUnsafeBytes { Data($0) }

        let lum = FrameSaver.rgbInterleavedToLuminance(data, width: 1, height: 1, bytesPerPixel: 2)
        XCTAssertEqual(lum.count, 2)

        lum.withUnsafeBytes { raw in
            let val = raw.bindMemory(to: UInt16.self)[0]
            // Expected: 0.299*10000 + 0.587*5000 + 0.114*3000 = 2990 + 2935 + 342 = 6267
            XCTAssertEqual(val, 6267, "Luminance should match BT.601 formula")
        }
    }

    func testLuminanceConversion8() {
        let r: UInt8 = 200, g: UInt8 = 100, b: UInt8 = 60
        let data = Data([r, g, b])

        let lum = FrameSaver.rgbInterleavedToLuminance(data, width: 1, height: 1, bytesPerPixel: 1)
        XCTAssertEqual(lum.count, 1)

        // Expected: 0.299*200 + 0.587*100 + 0.114*60 = 59.8 + 58.7 + 6.84 = 125.34 → 125
        XCTAssertEqual(lum[0], 125, "Luminance should match BT.601 formula")
    }

    // MARK: - Bayer Pattern Tests

    func testBGGRDebayer() {
        // 4x4 BGGR: blue at (0,0)
        let w = 4, h = 4
        var pixels = [UInt16](repeating: 0, count: w * h)
        let rVal: UInt16 = 10000
        let gVal: UInt16 = 5000
        let bVal: UInt16 = 3000

        for y in 0..<h {
            for x in 0..<w {
                let px = x % 2, py = y % 2
                if px == 0 && py == 0 { pixels[y * w + x] = bVal }       // B
                else if px == 1 && py == 1 { pixels[y * w + x] = rVal }  // R
                else { pixels[y * w + x] = gVal }                         // G
            }
        }
        let data = pixels.withUnsafeBytes { Data($0) }

        let rgb = FrameSaver.debayerToRGBInterleaved(data, width: w, height: h, bytesPerPixel: 2, bayerPattern: "BGGR")

        // Pixel (1,1) is red in BGGR
        rgb.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: UInt16.self)
            let idx = (1 * w + 1) * 3
            XCTAssertEqual(ptr[idx], 10000, "R channel at red pixel should be own value")
            XCTAssertEqual(ptr[idx + 2], 3000, "B channel at red pixel from diagonal B neighbors")
        }
    }

    // MARK: - Mono Camera (no debayer)

    func testMonoCameraDataPassesThrough() {
        // For mono cameras, save should not debayer
        let w = 2, h = 2
        let pixels: [UInt16] = [100, 200, 300, 400]
        let data = pixels.withUnsafeBytes { Data($0) }

        let metadata = CaptureMetadata(
            cameraName: "Test Mono", exposureMs: 100, gain: 100, binning: 1,
            pixelSizeMicrons: 2.9, bayerPattern: "", isColorCamera: false,
            width: w, height: h, bytesPerPixel: 2,
            observerLat: nil, observerLon: nil
        )

        // Save as FITS to a temp file
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_mono_\(UUID().uuidString).fits")
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertNoThrow(try FrameSaver.save(data: data, metadata: metadata,
                                              format: .fits, colorMode: .rgb, to: url))

        // Verify the FITS header says NAXIS=2 (not 3)
        let fileData = try! Data(contentsOf: url)
        let header = String(data: fileData.prefix(2880), encoding: .ascii)!
        XCTAssertTrue(header.contains("NAXIS   =                    2"), "Mono FITS should be NAXIS=2")
        XCTAssertFalse(header.contains("NAXIS3"), "Mono FITS should not have NAXIS3")
    }

    // MARK: - Color Camera FITS RGB

    func testColorCameraFITSHasThreeAxes() {
        let (data, w, h) = rggbTestData16()

        let metadata = CaptureMetadata(
            cameraName: "Test Color", exposureMs: 100, gain: 100, binning: 1,
            pixelSizeMicrons: 2.9, bayerPattern: "RGGB", isColorCamera: true,
            width: w, height: h, bytesPerPixel: 2,
            observerLat: nil, observerLon: nil
        )

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_rgb_\(UUID().uuidString).fits")
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertNoThrow(try FrameSaver.save(data: data, metadata: metadata,
                                              format: .fits, colorMode: .rgb, to: url))

        let fileData = try! Data(contentsOf: url)
        let header = String(data: fileData.prefix(2880), encoding: .ascii)!
        XCTAssertTrue(header.contains("NAXIS   =                    3"), "Color RGB FITS should be NAXIS=3")
        XCTAssertTrue(header.contains("NAXIS3  =                    3"), "Should have NAXIS3=3")
        XCTAssertFalse(header.contains("BAYERPAT"), "Debayered FITS should not have BAYERPAT")

        // Verify data size: header (2880) + 3 planes of w*h*2 bytes, padded to 2880
        let pixelBytes = w * h * 2 * 3
        let paddedPixels = ((pixelBytes + 2879) / 2880) * 2880
        XCTAssertEqual(fileData.count, 2880 + paddedPixels, "File size should match header + 3 planes")
    }

    func testColorCameraFITSLuminanceHasTwoAxes() {
        let (data, w, h) = rggbTestData16()

        let metadata = CaptureMetadata(
            cameraName: "Test Color", exposureMs: 100, gain: 100, binning: 1,
            pixelSizeMicrons: 2.9, bayerPattern: "RGGB", isColorCamera: true,
            width: w, height: h, bytesPerPixel: 2,
            observerLat: nil, observerLon: nil
        )

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_lum_\(UUID().uuidString).fits")
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertNoThrow(try FrameSaver.save(data: data, metadata: metadata,
                                              format: .fits, colorMode: .luminance, to: url))

        let fileData = try! Data(contentsOf: url)
        let header = String(data: fileData.prefix(2880), encoding: .ascii)!
        XCTAssertTrue(header.contains("NAXIS   =                    2"), "Luminance FITS should be NAXIS=2")
        XCTAssertFalse(header.contains("NAXIS3"), "Luminance FITS should not have NAXIS3")
    }

    // MARK: - TIFF

    func testColorCameraTIFFRGB() {
        let (data, w, h) = rggbTestData16()

        let metadata = CaptureMetadata(
            cameraName: "Test Color", exposureMs: 100, gain: 100, binning: 1,
            pixelSizeMicrons: 2.9, bayerPattern: "RGGB", isColorCamera: true,
            width: w, height: h, bytesPerPixel: 2,
            observerLat: nil, observerLon: nil
        )

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_rgb_\(UUID().uuidString).tif")
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertNoThrow(try FrameSaver.save(data: data, metadata: metadata,
                                              format: .tiff, colorMode: .rgb, to: url))

        // Verify the TIFF was written and is non-empty
        let fileData = try! Data(contentsOf: url)
        XCTAssertGreaterThan(fileData.count, 0, "TIFF should be non-empty")
    }

    func testMonoCameraTIFF() {
        let w = 4, h = 4
        let pixels = [UInt16](repeating: 5000, count: w * h)
        let data = pixels.withUnsafeBytes { Data($0) }

        let metadata = CaptureMetadata(
            cameraName: "Test Mono", exposureMs: 100, gain: 100, binning: 1,
            pixelSizeMicrons: 2.9, bayerPattern: "", isColorCamera: false,
            width: w, height: h, bytesPerPixel: 2,
            observerLat: nil, observerLon: nil
        )

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_mono_\(UUID().uuidString).tif")
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertNoThrow(try FrameSaver.save(data: data, metadata: metadata,
                                              format: .tiff, colorMode: .rgb, to: url))

        let fileData = try! Data(contentsOf: url)
        XCTAssertGreaterThan(fileData.count, 0, "Mono TIFF should be non-empty")
    }
}
