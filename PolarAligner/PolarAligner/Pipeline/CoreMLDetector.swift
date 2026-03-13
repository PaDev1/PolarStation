import Foundation
import CoreML
import Metal

/// Star detection using a Core ML ELUNet model (Zhao et al. 2024).
///
/// Hybrid approach:
/// 1. Crop a square (height×height) from the image center for uniform scaling
/// 2. Downscale to 512×512, run neural net for robust star detection
/// 3. Map approximate positions back to full resolution
/// 4. Refine each position with CPU weighted-centroid on the original pixels
///
/// Expected model:
/// - Input:  "image"  — (1, 1, 512, 512) normalized grayscale
/// - Output: "output" — (1, 2, 512, 512) seg logits + distance map
final class CoreMLDetector: StarDetectorProtocol {
    private let config: StarDetectionConfig
    private var model: MLModel?
    private let classicalFallback: ClassicalDetector

    /// Diagnostic info from last detection (for debug logging).
    var lastDiagnostic: String = ""

    /// Model input resolution.
    static let modelSize = 512

    /// Training normalization parameters (from dataset_512 norm_stats.json).
    /// Input = (pixel_value_0_255 - mean) / std
    private let normMean: Float = 21.93
    private let normStd: Float = 11.91

    /// Trilateration window radius (matching Zhao et al. default).
    private let trilaterationRadius = 5

    /// Half-width of the centroid refinement window (pixels in full-res).
    private let refineHalfWidth = 7

    init(config: StarDetectionConfig = StarDetectionConfig()) {
        self.config = config
        self.classicalFallback = ClassicalDetector(config: config)
    }

    /// Load the Core ML model from a .mlmodelc bundle.
    func loadModel(from url: URL) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all
        model = try MLModel(contentsOf: url, configuration: config)
    }

    /// Load the model from the app bundle by name.
    func loadModel(named name: String) throws {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") else {
            throw CoreMLDetectorError.modelNotFound(name)
        }
        try loadModel(from: url)
    }

    func detectStars(
        in texture: MTLTexture,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> [DetectedStar] {
        guard let model = model else {
            return try classicalFallback.detectStars(in: texture, device: device, commandQueue: commandQueue)
        }

        let fullW = texture.width
        let fullH = texture.height

        // Read full-res pixel data (reused for centroid refinement)
        let pixelData = readHalfFloatTexture(texture, width: fullW, height: fullH)

        // Crop a square region (height × height) from the center of the image.
        // This avoids non-uniform scaling which distorts star PSFs.
        let cropSize = min(fullW, fullH)
        let cropX0 = (fullW - cropSize) / 2
        let cropY0 = (fullH - cropSize) / 2

        // Step 1: Downscale cropped square to modelSize×modelSize, normalize
        let inputArray = try prepareModelInput(
            pixelData: pixelData, fullWidth: fullW,
            cropX0: cropX0, cropY0: cropY0, cropSize: cropSize
        )

        // Step 2: Run inference
        let provider = try MLDictionaryFeatureProvider(dictionary: ["image": inputArray])
        let prediction = try model.prediction(from: provider)

        guard let output = prediction.featureValue(for: "output")?.multiArrayValue else {
            throw CoreMLDetectorError.invalidOutput
        }

        let size = Self.modelSize
        let planeSize = size * size

        // Extract channel 0 (seg logits) and channel 1 (dist map)
        var segLogits = [Float](repeating: 0, count: planeSize)
        var distMap = [Float](repeating: 0, count: planeSize)

        for i in 0..<planeSize {
            segLogits[i] = output[i].floatValue
            distMap[i] = output[planeSize + i].floatValue
        }

        // Diagnostics
        let segMin = segLogits.min() ?? 0
        let segMax = segLogits.max() ?? 0
        let distMin = distMap.min() ?? 0
        let distMax = distMap.max() ?? 0

        // Step 3: Apply sigmoid to segmentation logits
        var segProb = [Float](repeating: 0, count: planeSize)
        for i in 0..<planeSize {
            segProb[i] = 1.0 / (1.0 + exp(-segLogits[i]))
        }

        // Step 4: Trilateration centroiding in model space
        let centroids = trilaterationCentroid(
            distMap: distMap,
            segProb: segProb,
            width: size,
            height: size
        )

        // Step 5: Map model-space positions back to full image coordinates.
        // Model pixels map to the cropped square, which starts at (cropX0, cropY0).
        let scale = Double(cropSize) / Double(size)

        let approxPositions = centroids.map { c in
            (x: c.x * scale + Double(cropX0), y: c.y * scale + Double(cropY0))
        }

        // Step 6: Refine each position with weighted centroid on full-res pixels
        var stars = refinePositions(
            approximate: approxPositions,
            pixelData: pixelData,
            width: fullW,
            height: fullH
        )

        lastDiagnostic = String(
            format: "seg=[%.2f,%.2f] dist=[%.1f,%.1f] crop=%dx%d+%d ml=%d refined=%d",
            segMin, segMax, distMin, distMax, cropSize, cropSize, cropX0, centroids.count, stars.count
        )

        stars.sort { $0.brightness > $1.brightness }
        if stars.count > config.maxStars {
            stars = Array(stars.prefix(config.maxStars))
        }

        return stars
    }

    // MARK: - Input Preparation

    /// Read rgba16Float texture into CPU memory.
    private func readHalfFloatTexture(_ texture: MTLTexture, width: Int, height: Int) -> [UInt16] {
        var pixelData = [UInt16](repeating: 0, count: width * height * 4)
        let bytesPerRow = width * 4 * MemoryLayout<UInt16>.size
        let region = MTLRegion(origin: MTLOrigin(), size: MTLSize(width: width, height: height, depth: 1))
        texture.getBytes(&pixelData, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)
        return pixelData
    }

    /// Downscale a square crop of full-res pixel data to modelSize×modelSize with normalization.
    private func prepareModelInput(
        pixelData: [UInt16], fullWidth w: Int,
        cropX0: Int, cropY0: Int, cropSize: Int
    ) throws -> MLMultiArray {
        let size = Self.modelSize

        let array = try MLMultiArray(
            shape: [1, 1, NSNumber(value: size), NSNumber(value: size)],
            dataType: .float32
        )

        let scale = Float(cropSize) / Float(size)

        // Area-average downscale from cropped square + normalize
        for y in 0..<size {
            let srcY0 = cropY0 + Int(Float(y) * scale)
            let srcY1 = cropY0 + min(Int(Float(y + 1) * scale), cropSize - 1)
            for x in 0..<size {
                let srcX0 = cropX0 + Int(Float(x) * scale)
                let srcX1 = cropX0 + min(Int(Float(x + 1) * scale), cropSize - 1)

                var lumSum: Float = 0
                var maxLum: Float = 0
                var count: Float = 0
                for sy in srcY0...srcY1 {
                    for sx in srcX0...srcX1 {
                        let idx = (sy * w + sx) * 4
                        let r = halfToFloat(pixelData[idx])
                        let g = halfToFloat(pixelData[idx + 1])
                        let b = halfToFloat(pixelData[idx + 2])
                        let lum = 0.299 * r + 0.587 * g + 0.114 * b
                        lumSum += lum
                        maxLum = max(maxLum, lum)
                        count += 1
                    }
                }

                let avg = count > 0 ? lumSum / count : 0
                let val = max(avg, maxLum * 0.5)

                // Scale to 0-255 range (match training data) then normalize
                let raw255 = val * 255.0
                let normalized = (raw255 - normMean) / normStd
                array[y * size + x] = NSNumber(value: normalized)
            }
        }

        return array
    }

    // MARK: - Centroid Refinement

    /// Refine approximate star positions using weighted centroid on full-resolution pixel data.
    /// This corrects the quantization error from the 256×256 model grid and produces
    /// accurate FWHM and SNR values.
    private func refinePositions(
        approximate: [(x: Double, y: Double)],
        pixelData: [UInt16],
        width: Int,
        height: Int
    ) -> [DetectedStar] {
        let hw = refineHalfWidth
        let winSize = 2 * hw + 1
        var results: [DetectedStar] = []

        for approx in approximate {
            let cx = Int(approx.x.rounded())
            let cy = Int(approx.y.rounded())

            // Skip if too close to edge
            guard cx >= hw && cx < width - hw &&
                  cy >= hw && cy < height - hw else { continue }

            // Compute luminance in the refinement window
            var window = [Float](repeating: 0, count: winSize * winSize)
            for dy in -hw...hw {
                for dx in -hw...hw {
                    let px = cx + dx
                    let py = cy + dy
                    let idx = (py * width + px) * 4
                    let r = halfToFloat(pixelData[idx])
                    let g = halfToFloat(pixelData[idx + 1])
                    let b = halfToFloat(pixelData[idx + 2])
                    window[(dy + hw) * winSize + (dx + hw)] = 0.299 * r + 0.587 * g + 0.114 * b
                }
            }

            // Estimate background from window edges (median)
            var edgeValues: [Float] = []
            edgeValues.reserveCapacity(4 * winSize - 4)
            for i in 0..<winSize {
                edgeValues.append(window[i])                          // top row
                edgeValues.append(window[(winSize - 1) * winSize + i]) // bottom row
                if i > 0 && i < winSize - 1 {
                    edgeValues.append(window[i * winSize])             // left col
                    edgeValues.append(window[i * winSize + winSize - 1]) // right col
                }
            }
            edgeValues.sort()
            let background = edgeValues[edgeValues.count / 2]

            // Noise estimate from edge standard deviation
            let edgeMean = edgeValues.reduce(0, +) / Float(edgeValues.count)
            var edgeVar: Float = 0
            for v in edgeValues { edgeVar += (v - edgeMean) * (v - edgeMean) }
            let noise = sqrt(edgeVar / Float(edgeValues.count))

            // Weighted centroid (background-subtracted)
            var sumI: Double = 0
            var sumIx: Double = 0
            var sumIy: Double = 0
            var peak: Float = 0

            for dy in -hw...hw {
                for dx in -hw...hw {
                    let val = window[(dy + hw) * winSize + (dx + hw)] - background
                    if val > 0 {
                        let v = Double(val)
                        sumI += v
                        sumIx += v * Double(cx + dx)
                        sumIy += v * Double(cy + dy)
                        peak = max(peak, val)
                    }
                }
            }

            guard sumI > 0 && peak > 0 else { continue }

            let refinedX = sumIx / sumI
            let refinedY = sumIy / sumI
            let snr = Double(peak) / Double(max(noise, 0.001))

            guard snr >= config.minSNR else { continue }

            // Estimate FWHM: count pixels above half-max, approximate as circular diameter
            let halfMax = peak / 2
            var aboveHalfCount = 0
            for i in 0..<(winSize * winSize) {
                if window[i] - background > halfMax { aboveHalfCount += 1 }
            }
            let fwhm = 2.0 * sqrt(Double(aboveHalfCount) / .pi)

            results.append(DetectedStar(
                x: refinedX,
                y: refinedY,
                brightness: sumI,
                fwhm: fwhm,
                snr: snr
            ))
        }

        return results
    }

    // MARK: - Trilateration Centroiding (Zhao et al. 2024)

    /// A centroid found via trilateration on the distance map.
    private struct CentroidResult {
        let x: Double
        let y: Double
        let brightness: Double
    }

    /// Trilateration-based centroiding from Zhao et al. (2024).
    ///
    /// For each candidate pixel (seg probability > 0.5 and distance ≤ threshold),
    /// collects nearby star pixels within a window and solves the trilateration
    /// least-squares system to find the sub-pixel centroid position.
    private func trilaterationCentroid(
        distMap: [Float],
        segProb: [Float],
        width: Int,
        height: Int
    ) -> [CentroidResult] {
        var results: [CentroidResult] = []
        let threshold: Float = 0.5 * sqrt(2.0)  // ~0.707 pixels
        let radius = trilaterationRadius

        // Working copy of seg map — zero out used pixels to avoid duplicates
        var seg = segProb

        for row in 0..<height {
            for col in 0..<width {
                let idx = row * width + col
                guard distMap[idx] <= threshold && seg[idx] > 0.5 else { continue }

                // Collect neighboring star pixels
                var xi: [Float] = []
                var yi: [Float] = []
                var ri: [Float] = []

                for dRow in -radius...radius {
                    for dCol in -radius...radius {
                        let r = row + dRow
                        let c = col + dCol
                        guard r >= 0 && r < height && c >= 0 && c < width else { continue }
                        let nIdx = r * width + c
                        guard seg[nIdx] > 0.5 else { continue }

                        xi.append(Float(c) + 0.5)
                        yi.append(Float(r) + 0.5)
                        ri.append(distMap[nIdx])
                        seg[nIdx] = 0  // mark as used
                    }
                }

                let n = xi.count
                guard n >= 3 else {
                    // Not enough points — use pixel center
                    results.append(CentroidResult(
                        x: Double(col) + 0.5,
                        y: Double(row) + 0.5,
                        brightness: Double(1.0 / max(distMap[idx], 0.01))
                    ))
                    continue
                }

                // Trilateration least-squares (Zhao et al.)
                // Reference point = last collected pixel
                let xn = xi[n - 1]
                let yn = yi[n - 1]
                let rn = ri[n - 1]

                // Build A matrix (n-1 x 2) and B vector (n-1)
                var aFlat = [Float](repeating: 0, count: (n - 1) * 2)
                var b = [Float](repeating: 0, count: n - 1)

                for i in 0..<(n - 1) {
                    aFlat[i * 2 + 0] = 2.0 * (xn - xi[i])
                    aFlat[i * 2 + 1] = 2.0 * (yn - yi[i])
                    b[i] = ri[i] * ri[i] - rn * rn
                        - xi[i] * xi[i] - yi[i] * yi[i]
                        + xn * xn + yn * yn
                }

                // Solve via normal equations: x = (A^T A)^-1 A^T b
                if let solution = solveNormalEquations2x2(a: aFlat, b: b, rows: n - 1) {
                    let cx = Double(solution.0)
                    let cy = Double(solution.1)
                    let minDist = ri.min() ?? 1.0
                    results.append(CentroidResult(
                        x: cx, y: cy,
                        brightness: Double(1.0 / max(minDist, 0.01))
                    ))
                } else {
                    results.append(CentroidResult(
                        x: Double(col) + 0.5,
                        y: Double(row) + 0.5,
                        brightness: Double(1.0 / max(distMap[idx], 0.01))
                    ))
                }
            }
        }

        return results
    }

    /// Solve 2-variable normal equations: (A^T A) x = A^T b
    /// where A is (rows x 2) and b is (rows).
    /// Returns (x0, x1) or nil if singular.
    private func solveNormalEquations2x2(a: [Float], b: [Float], rows: Int) -> (Float, Float)? {
        var ata00: Float = 0, ata01: Float = 0, ata11: Float = 0
        var atb0: Float = 0, atb1: Float = 0

        for i in 0..<rows {
            let a0 = a[i * 2 + 0]
            let a1 = a[i * 2 + 1]
            ata00 += a0 * a0
            ata01 += a0 * a1
            ata11 += a1 * a1
            atb0 += a0 * b[i]
            atb1 += a1 * b[i]
        }

        let det = ata00 * ata11 - ata01 * ata01
        guard abs(det) > 1e-10 else { return nil }

        let invDet = 1.0 / det
        let x0 = (ata11 * atb0 - ata01 * atb1) * invDet
        let x1 = (ata00 * atb1 - ata01 * atb0) * invDet

        return (x0, x1)
    }

    // MARK: - Utilities

    /// Convert IEEE 754 half-float (UInt16) to Float.
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

        let f = Float(sign == 0 ? 1 : -1) * pow(2.0, Float(Int(exponent) - 15)) * (1.0 + Float(mantissa) / 1024.0)
        return f
    }
}

// MARK: - Errors

enum CoreMLDetectorError: Error, LocalizedError {
    case modelNotFound(String)
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let name): return "Core ML model '\(name)' not found in bundle"
        case .invalidOutput:           return "Model produced unexpected output format"
        }
    }
}
