import Foundation
import ImageIO

// MARK: - Types

enum CaptureFormat: String, CaseIterable, Identifiable {
    case fits = "FITS"
    case tiff = "TIFF"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .fits: return "fits"
        case .tiff: return "tif"
        }
    }
}

enum CaptureColorMode: String, CaseIterable, Identifiable {
    case rgb = "rgb"
    case luminance = "luminance"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rgb: return "RGB"
        case .luminance: return "Luminance"
        }
    }
}

struct CaptureMetadata {
    let cameraName: String
    let exposureMs: Double
    let gain: Int
    let binning: Int
    let pixelSizeMicrons: Double
    let bayerPattern: String
    let isColorCamera: Bool
    let width: Int
    let height: Int
    let bytesPerPixel: Int
    let observerLat: Double?
    let observerLon: Double?
    /// J2000 plate-solved RA in degrees (nil if no solve available).
    let solvedRA: Double?
    /// J2000 plate-solved Dec in degrees (nil if no solve available).
    let solvedDec: Double?
}

enum FrameSaverError: Error, LocalizedError {
    case imageCreation
    case destinationCreation
    case writeFailed
    case incompleteFrame(got: Int, expected: Int, width: Int, height: Int, bpp: Int)

    var errorDescription: String? {
        switch self {
        case .imageCreation: return "Failed to create image from raw data"
        case .destinationCreation: return "Failed to create file destination"
        case .writeFailed: return "Failed to write file"
        case .incompleteFrame(let got, let expected, let w, let h, let bpp):
            return "Incomplete frame: got \(got) bytes, expected \(expected) (\(w)×\(h)×\(bpp)bpp) — frame dropped"
        }
    }
}

// MARK: - FrameSaver

enum FrameSaver {

    static func save(data: Data, metadata: CaptureMetadata, format: CaptureFormat,
                      colorMode: CaptureColorMode = .rgb, to url: URL) throws {
        let expectedBytes = metadata.width * metadata.height * metadata.bytesPerPixel
        guard data.count >= expectedBytes else {
            throw FrameSaverError.incompleteFrame(
                got: data.count, expected: expectedBytes,
                width: metadata.width, height: metadata.height, bpp: metadata.bytesPerPixel
            )
        }
        switch format {
        case .fits: try saveFITS(data: data, metadata: metadata, colorMode: colorMode, to: url)
        case .tiff: try saveTIFF(data: data, metadata: metadata, colorMode: colorMode, to: url)
        }
    }

    // MARK: - FITS

    static func saveFITS(data: Data, metadata: CaptureMetadata,
                          colorMode: CaptureColorMode, to url: URL) throws {
        let bitpix = metadata.bytesPerPixel == 2 ? 16 : 8
        let isRGB = metadata.isColorCamera && colorMode == .rgb

        // Prepare pixel data: debayer if color camera
        let pixelData: Data
        if metadata.isColorCamera {
            if colorMode == .luminance {
                let interleaved = debayerToRGBInterleaved(
                    data, width: metadata.width, height: metadata.height,
                    bytesPerPixel: metadata.bytesPerPixel, bayerPattern: metadata.bayerPattern
                )
                pixelData = rgbInterleavedToLuminance(
                    interleaved, width: metadata.width, height: metadata.height,
                    bytesPerPixel: metadata.bytesPerPixel
                )
            } else {
                pixelData = debayerToRGBPlanar(
                    data, width: metadata.width, height: metadata.height,
                    bytesPerPixel: metadata.bytesPerPixel, bayerPattern: metadata.bayerPattern
                )
            }
        } else {
            // Mono camera — raw data is already single-channel
            pixelData = data
        }

        // Build header records
        var records: [String] = []
        records.append(fitsRecord("SIMPLE", logical: true, comment: "Standard FITS"))
        records.append(fitsRecord("BITPIX", integer: bitpix, comment: "Bits per pixel"))

        if isRGB {
            records.append(fitsRecord("NAXIS", integer: 3, comment: "Number of axes"))
            records.append(fitsRecord("NAXIS1", integer: metadata.width, comment: "Image width"))
            records.append(fitsRecord("NAXIS2", integer: metadata.height, comment: "Image height"))
            records.append(fitsRecord("NAXIS3", integer: 3, comment: "RGB channels"))
        } else {
            records.append(fitsRecord("NAXIS", integer: 2, comment: "Number of axes"))
            records.append(fitsRecord("NAXIS1", integer: metadata.width, comment: "Image width"))
            records.append(fitsRecord("NAXIS2", integer: metadata.height, comment: "Image height"))
        }

        if bitpix == 16 {
            records.append(fitsRecord("BZERO", float: 32768.0, comment: "Unsigned 16-bit offset"))
            records.append(fitsRecord("BSCALE", float: 1.0, comment: "Scale factor"))
        }

        // Observation
        records.append(fitsRecord("EXPTIME", float: metadata.exposureMs / 1000.0, comment: "[s] Exposure time"))
        records.append(fitsRecord("GAIN", integer: metadata.gain, comment: "Sensor gain"))
        records.append(fitsRecord("XBINNING", integer: metadata.binning, comment: "X binning"))
        records.append(fitsRecord("YBINNING", integer: metadata.binning, comment: "Y binning"))
        records.append(fitsRecord("DATE-OBS", string: isoDateUTC(), comment: "UTC observation time"))
        records.append(fitsRecord("INSTRUME", string: metadata.cameraName, comment: "Camera name"))
        records.append(fitsRecord("IMAGETYP", string: "Light Frame", comment: "Frame type"))

        if isRGB {
            records.append(fitsRecord("CTYPE3", string: "RGB", comment: "Channel axis type"))
        }

        // Pixel size (effective, after binning)
        let px = metadata.pixelSizeMicrons * Double(metadata.binning)
        records.append(fitsRecord("XPIXSZ", float: px, comment: "[um] Pixel size X"))
        records.append(fitsRecord("YPIXSZ", float: px, comment: "[um] Pixel size Y"))

        // Location
        if let lat = metadata.observerLat {
            records.append(fitsRecord("SITELAT", float: lat, comment: "[deg] Observer latitude"))
        }
        if let lon = metadata.observerLon {
            records.append(fitsRecord("SITELONG", float: lon, comment: "[deg] Observer longitude"))
        }

        // Plate-solved position
        if let ra = metadata.solvedRA, let dec = metadata.solvedDec {
            records.append(fitsRecord("RA", float: ra, comment: "[deg] J2000 RA from plate solve"))
            records.append(fitsRecord("DEC", float: dec, comment: "[deg] J2000 Dec from plate solve"))
            records.append(fitsRecord("OBJCTRA", string: raToSexagesimal(ra), comment: "RA (J2000)"))
            records.append(fitsRecord("OBJCTDEC", string: decToSexagesimal(dec), comment: "Dec (J2000)"))
        }

        // Software
        records.append(fitsRecord("SWCREATE", string: "PolarStation", comment: "Software"))

        // END
        records.append("END".padding(toLength: 80, withPad: " ", startingAt: 0))

        // Pad header to multiple of 2880 bytes
        let headerStr = records.joined()
        let headerBlocks = (headerStr.count + 2879) / 2880
        let paddedHeader = headerStr.padding(toLength: headerBlocks * 2880, withPad: " ", startingAt: 0)

        guard let headerData = paddedHeader.data(using: .ascii) else {
            throw FrameSaverError.writeFailed
        }

        var fileData = Data()
        fileData.reserveCapacity(headerData.count + pixelData.count + 2880)
        fileData.append(headerData)

        // Pixel data
        if bitpix == 16 {
            fileData.append(convertUInt16LEToSignedBE(pixelData))
        } else {
            fileData.append(pixelData)
        }

        // Pad data to 2880 bytes
        let remainder = fileData.count % 2880
        if remainder > 0 {
            fileData.append(Data(count: 2880 - remainder))
        }

        try fileData.write(to: url)
    }

    // MARK: - TIFF

    static func saveTIFF(data: Data, metadata: CaptureMetadata,
                          colorMode: CaptureColorMode, to url: URL) throws {
        let w = metadata.width
        let h = metadata.height
        let bpp = metadata.bytesPerPixel

        // Prepare pixel data
        let imageData: Data
        let colorSpace: CGColorSpace
        let channels: Int

        if metadata.isColorCamera {
            let interleaved = debayerToRGBInterleaved(
                data, width: w, height: h,
                bytesPerPixel: bpp, bayerPattern: metadata.bayerPattern
            )
            if colorMode == .luminance {
                imageData = rgbInterleavedToLuminance(interleaved, width: w, height: h, bytesPerPixel: bpp)
                guard let cs = CGColorSpace(name: CGColorSpace.linearGray) else {
                    throw FrameSaverError.imageCreation
                }
                colorSpace = cs
                channels = 1
            } else {
                imageData = interleaved
                guard let cs = CGColorSpace(name: CGColorSpace.linearSRGB) else {
                    throw FrameSaverError.imageCreation
                }
                colorSpace = cs
                channels = 3
            }
        } else {
            // Mono camera — raw data is single channel
            imageData = data
            guard let cs = CGColorSpace(name: CGColorSpace.linearGray) else {
                throw FrameSaverError.imageCreation
            }
            colorSpace = cs
            channels = 1
        }

        var bitmapInfo = CGBitmapInfo()
        if bpp == 2 {
            bitmapInfo.insert(CGBitmapInfo(rawValue: CGImageByteOrderInfo.order16Little.rawValue))
        }

        guard let provider = CGDataProvider(data: imageData as CFData),
              let cgImage = CGImage(
                width: w,
                height: h,
                bitsPerComponent: bpp * 8,
                bitsPerPixel: bpp * 8 * channels,
                bytesPerRow: w * bpp * channels,
                space: colorSpace,
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw FrameSaverError.imageCreation
        }

        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, "public.tiff" as CFString, 1, nil
        ) else {
            throw FrameSaverError.destinationCreation
        }

        // Uncompressed TIFF
        let opts: [CFString: Any] = [
            kCGImagePropertyTIFFCompression: 1
        ]
        CGImageDestinationAddImage(dest, cgImage, [kCGImagePropertyTIFFDictionary: opts] as CFDictionary)

        guard CGImageDestinationFinalize(dest) else {
            throw FrameSaverError.writeFailed
        }
    }

    // MARK: - Debayer

    /// Bayer pattern offsets: (redX, redY) for each pattern.
    /// RGGB: red at (0,0), BGGR: red at (1,1), GRBG: red at (1,0), GBRG: red at (0,1).
    private static func bayerRedOffset(_ pattern: String) -> (Int, Int) {
        switch pattern {
        case "BGGR": return (1, 1)
        case "GRBG": return (1, 0)
        case "GBRG": return (0, 1)
        default:     return (0, 0) // RGGB
        }
    }

    /// Debayer raw Bayer data to 3 separate planes (R, G, B) for FITS.
    /// Uses bilinear interpolation matching the Metal debayer_rggb shader.
    /// Output: R plane followed by G plane followed by B plane, each width*height*bpp bytes.
    static func debayerToRGBPlanar(
        _ data: Data, width: Int, height: Int, bytesPerPixel bpp: Int, bayerPattern: String
    ) -> Data {
        let pixelCount = width * height
        let (rx, ry) = bayerRedOffset(bayerPattern)

        if bpp == 2 {
            var rPlane = [UInt16](repeating: 0, count: pixelCount)
            var gPlane = [UInt16](repeating: 0, count: pixelCount)
            var bPlane = [UInt16](repeating: 0, count: pixelCount)

            data.withUnsafeBytes { raw in
                let src = raw.bindMemory(to: UInt16.self)
                for y in 0..<height {
                    for x in 0..<width {
                        let (r, g, b) = debayerPixel16(src: src, x: x, y: y, w: width, h: height, rx: rx, ry: ry)
                        let idx = y * width + x
                        rPlane[idx] = r
                        gPlane[idx] = g
                        bPlane[idx] = b
                    }
                }
            }

            var result = Data(capacity: pixelCount * 3 * bpp)
            result.append(contentsOf: rPlane.withUnsafeBytes { Data($0) })
            result.append(contentsOf: gPlane.withUnsafeBytes { Data($0) })
            result.append(contentsOf: bPlane.withUnsafeBytes { Data($0) })
            return result
        } else {
            var rPlane = [UInt8](repeating: 0, count: pixelCount)
            var gPlane = [UInt8](repeating: 0, count: pixelCount)
            var bPlane = [UInt8](repeating: 0, count: pixelCount)

            data.withUnsafeBytes { raw in
                let src = raw.bindMemory(to: UInt8.self)
                for y in 0..<height {
                    for x in 0..<width {
                        let (r, g, b) = debayerPixel8(src: src, x: x, y: y, w: width, h: height, rx: rx, ry: ry)
                        let idx = y * width + x
                        rPlane[idx] = r
                        gPlane[idx] = g
                        bPlane[idx] = b
                    }
                }
            }

            var result = Data(capacity: pixelCount * 3)
            result.append(contentsOf: rPlane)
            result.append(contentsOf: gPlane)
            result.append(contentsOf: bPlane)
            return result
        }
    }

    /// Debayer raw Bayer data to interleaved RGB (R,G,B,R,G,B,...) for TIFF.
    static func debayerToRGBInterleaved(
        _ data: Data, width: Int, height: Int, bytesPerPixel bpp: Int, bayerPattern: String
    ) -> Data {
        let pixelCount = width * height
        let (rx, ry) = bayerRedOffset(bayerPattern)

        if bpp == 2 {
            var result = [UInt16](repeating: 0, count: pixelCount * 3)
            data.withUnsafeBytes { raw in
                let src = raw.bindMemory(to: UInt16.self)
                for y in 0..<height {
                    for x in 0..<width {
                        let (r, g, b) = debayerPixel16(src: src, x: x, y: y, w: width, h: height, rx: rx, ry: ry)
                        let idx = (y * width + x) * 3
                        result[idx] = r
                        result[idx + 1] = g
                        result[idx + 2] = b
                    }
                }
            }
            return result.withUnsafeBytes { Data($0) }
        } else {
            var result = [UInt8](repeating: 0, count: pixelCount * 3)
            data.withUnsafeBytes { raw in
                let src = raw.bindMemory(to: UInt8.self)
                for y in 0..<height {
                    for x in 0..<width {
                        let (r, g, b) = debayerPixel8(src: src, x: x, y: y, w: width, h: height, rx: rx, ry: ry)
                        let idx = (y * width + x) * 3
                        result[idx] = r
                        result[idx + 1] = g
                        result[idx + 2] = b
                    }
                }
            }
            return Data(result)
        }
    }

    /// Convert interleaved RGB data to single-channel luminance.
    /// BT.601: L = 0.299*R + 0.587*G + 0.114*B
    static func rgbInterleavedToLuminance(
        _ data: Data, width: Int, height: Int, bytesPerPixel bpp: Int
    ) -> Data {
        let pixelCount = width * height

        if bpp == 2 {
            var lum = [UInt16](repeating: 0, count: pixelCount)
            data.withUnsafeBytes { raw in
                let src = raw.bindMemory(to: UInt16.self)
                for i in 0..<pixelCount {
                    let r = Double(src[i * 3])
                    let g = Double(src[i * 3 + 1])
                    let b = Double(src[i * 3 + 2])
                    lum[i] = UInt16(min(0.299 * r + 0.587 * g + 0.114 * b, 65535.0))
                }
            }
            return lum.withUnsafeBytes { Data($0) }
        } else {
            var lum = [UInt8](repeating: 0, count: pixelCount)
            data.withUnsafeBytes { raw in
                let src = raw.bindMemory(to: UInt8.self)
                for i in 0..<pixelCount {
                    let r = Double(src[i * 3])
                    let g = Double(src[i * 3 + 1])
                    let b = Double(src[i * 3 + 2])
                    lum[i] = UInt8(min(0.299 * r + 0.587 * g + 0.114 * b, 255.0))
                }
            }
            return Data(lum)
        }
    }

    // MARK: - Debayer pixel helpers (bilinear interpolation)

    private static func sample16(_ src: UnsafeBufferPointer<UInt16>, _ x: Int, _ y: Int, _ w: Int, _ h: Int) -> UInt16 {
        src[min(max(y, 0), h - 1) * w + min(max(x, 0), w - 1)]
    }

    private static func sample8(_ src: UnsafeBufferPointer<UInt8>, _ x: Int, _ y: Int, _ w: Int, _ h: Int) -> UInt8 {
        src[min(max(y, 0), h - 1) * w + min(max(x, 0), w - 1)]
    }

    /// Debayer one pixel (16-bit). rx/ry = position of red in the 2x2 Bayer cell.
    private static func debayerPixel16(
        src: UnsafeBufferPointer<UInt16>, x: Int, y: Int, w: Int, h: Int, rx: Int, ry: Int
    ) -> (UInt16, UInt16, UInt16) {
        // Determine which color this pixel is in the Bayer pattern.
        // px/py: position within the 2x2 Bayer cell, relative to red.
        let px = (x + 2 - rx) % 2  // 0 = red/blue column, 1 = green column
        let py = (y + 2 - ry) % 2  // 0 = red/green row, 1 = green/blue row

        let c = sample16(src, x, y, w, h)
        let r: UInt16, g: UInt16, b: UInt16

        if px == 0 && py == 0 {
            // Red pixel
            r = c
            g = avg16(sample16(src, x-1, y, w, h), sample16(src, x+1, y, w, h),
                       sample16(src, x, y-1, w, h), sample16(src, x, y+1, w, h))
            b = avg16(sample16(src, x-1, y-1, w, h), sample16(src, x+1, y-1, w, h),
                       sample16(src, x-1, y+1, w, h), sample16(src, x+1, y+1, w, h))
        } else if px == 1 && py == 0 {
            // Green pixel on red row
            g = c
            r = avg16(sample16(src, x-1, y, w, h), sample16(src, x+1, y, w, h))
            b = avg16(sample16(src, x, y-1, w, h), sample16(src, x, y+1, w, h))
        } else if px == 0 && py == 1 {
            // Green pixel on blue row
            g = c
            r = avg16(sample16(src, x, y-1, w, h), sample16(src, x, y+1, w, h))
            b = avg16(sample16(src, x-1, y, w, h), sample16(src, x+1, y, w, h))
        } else {
            // Blue pixel
            b = c
            g = avg16(sample16(src, x-1, y, w, h), sample16(src, x+1, y, w, h),
                       sample16(src, x, y-1, w, h), sample16(src, x, y+1, w, h))
            r = avg16(sample16(src, x-1, y-1, w, h), sample16(src, x+1, y-1, w, h),
                       sample16(src, x-1, y+1, w, h), sample16(src, x+1, y+1, w, h))
        }
        return (r, g, b)
    }

    /// Debayer one pixel (8-bit).
    private static func debayerPixel8(
        src: UnsafeBufferPointer<UInt8>, x: Int, y: Int, w: Int, h: Int, rx: Int, ry: Int
    ) -> (UInt8, UInt8, UInt8) {
        let px = (x + 2 - rx) % 2
        let py = (y + 2 - ry) % 2

        let c = sample8(src, x, y, w, h)
        let r: UInt8, g: UInt8, b: UInt8

        if px == 0 && py == 0 {
            r = c
            g = avg8(sample8(src, x-1, y, w, h), sample8(src, x+1, y, w, h),
                      sample8(src, x, y-1, w, h), sample8(src, x, y+1, w, h))
            b = avg8(sample8(src, x-1, y-1, w, h), sample8(src, x+1, y-1, w, h),
                      sample8(src, x-1, y+1, w, h), sample8(src, x+1, y+1, w, h))
        } else if px == 1 && py == 0 {
            g = c
            r = avg8(sample8(src, x-1, y, w, h), sample8(src, x+1, y, w, h))
            b = avg8(sample8(src, x, y-1, w, h), sample8(src, x, y+1, w, h))
        } else if px == 0 && py == 1 {
            g = c
            r = avg8(sample8(src, x, y-1, w, h), sample8(src, x, y+1, w, h))
            b = avg8(sample8(src, x-1, y, w, h), sample8(src, x+1, y, w, h))
        } else {
            b = c
            g = avg8(sample8(src, x-1, y, w, h), sample8(src, x+1, y, w, h),
                      sample8(src, x, y-1, w, h), sample8(src, x, y+1, w, h))
            r = avg8(sample8(src, x-1, y-1, w, h), sample8(src, x+1, y-1, w, h),
                      sample8(src, x-1, y+1, w, h), sample8(src, x+1, y+1, w, h))
        }
        return (r, g, b)
    }

    private static func avg16(_ a: UInt16, _ b: UInt16) -> UInt16 {
        UInt16((UInt32(a) + UInt32(b)) / 2)
    }

    private static func avg16(_ a: UInt16, _ b: UInt16, _ c: UInt16, _ d: UInt16) -> UInt16 {
        UInt16((UInt32(a) + UInt32(b) + UInt32(c) + UInt32(d)) / 4)
    }

    private static func avg8(_ a: UInt8, _ b: UInt8) -> UInt8 {
        UInt8((UInt16(a) + UInt16(b)) / 2)
    }

    private static func avg8(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> UInt8 {
        UInt8((UInt16(a) + UInt16(b) + UInt16(c) + UInt16(d)) / 4)
    }

    // MARK: - Helpers

    /// Convert unsigned 16-bit little-endian to FITS format (signed 16-bit big-endian with BZERO=32768).
    private static func convertUInt16LEToSignedBE(_ data: Data) -> Data {
        var result = Data(count: data.count)
        data.withUnsafeBytes { src in
            result.withUnsafeMutableBytes { dst in
                let srcPtr = src.bindMemory(to: UInt16.self)
                let dstPtr = dst.bindMemory(to: Int16.self)
                for i in 0..<srcPtr.count {
                    let unsigned = UInt16(littleEndian: srcPtr[i])
                    let signed = Int16(bitPattern: unsigned &- 32768)
                    dstPtr[i] = signed.bigEndian
                }
            }
        }
        return result
    }

    private static func isoDateUTC() -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt.string(from: Date())
    }

    // MARK: - Sexagesimal Formatters

    /// Format RA in degrees as "HH MM SS.SS" (OBJCTRA convention).
    private static func raToSexagesimal(_ raDeg: Double) -> String {
        let totalSec = (raDeg / 15.0) * 3600.0
        let h = Int(totalSec / 3600)
        let m = Int((totalSec - Double(h) * 3600) / 60)
        let s = totalSec - Double(h) * 3600 - Double(m) * 60
        return String(format: "%02d %02d %05.2f", h, m, s)
    }

    /// Format Dec in degrees as "+DD MM SS.S" (OBJCTDEC convention).
    private static func decToSexagesimal(_ decDeg: Double) -> String {
        let sign = decDeg < 0 ? "-" : "+"
        let abs = Swift.abs(decDeg)
        let totalSec = abs * 3600.0
        let d = Int(totalSec / 3600)
        let m = Int((totalSec - Double(d) * 3600) / 60)
        let s = totalSec - Double(d) * 3600 - Double(m) * 60
        return String(format: "%@%02d %02d %04.1f", sign, d, m, s)
    }

    // MARK: - FITS Record Builders

    private static func fitsRecord(_ kw: String, logical value: Bool, comment: String = "") -> String {
        let val = String(repeating: " ", count: 19) + (value ? "T" : "F")
        return buildRecord(kw, value: val, comment: comment)
    }

    private static func fitsRecord(_ kw: String, integer value: Int, comment: String = "") -> String {
        return buildRecord(kw, value: String(format: "%20d", value), comment: comment)
    }

    private static func fitsRecord(_ kw: String, float value: Double, comment: String = "") -> String {
        return buildRecord(kw, value: String(format: "%20.10G", value), comment: comment)
    }

    private static func fitsRecord(_ kw: String, string value: String, comment: String = "") -> String {
        let quoted = "'\(value)'"
        let padded = quoted.padding(toLength: max(20, quoted.count), withPad: " ", startingAt: 0)
        return buildRecord(kw, value: padded, comment: comment)
    }

    private static func buildRecord(_ keyword: String, value: String, comment: String) -> String {
        let kw = keyword.padding(toLength: 8, withPad: " ", startingAt: 0)
        var record = "\(kw)= \(value)"
        if !comment.isEmpty {
            record += " / \(comment)"
        }
        return String(record.prefix(80)).padding(toLength: 80, withPad: " ", startingAt: 0)
    }

    /// Generate a timestamp string for file naming.
    static func captureTimestamp() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.string(from: Date())
    }
}
