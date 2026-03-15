import Foundation
import CoreML
import Metal

/// Star detection using a Core ML ELUNet model.
///
/// Hybrid approach:
/// 1. Crop a square (height×height) from the image center for uniform scaling
/// 2. Downscale to 512×512, run neural net → confidence heatmap
/// 3. Find peaks via threshold + NMS + quadratic sub-pixel refinement
/// 4. Map positions back to full resolution
/// 5. Refine each position with CPU weighted-centroid on the original pixels
///
/// Expected model:
/// - Input:  "image"   — (1, 1, 512, 512) float32, 99.9th percentile normalized
/// - Output: "heatmap" — (1, 1, 512, 512) float16, confidence values in [0,1]
final class CoreMLDetector: StarDetectorProtocol {
    private let config: StarDetectionConfig
    private var model: MLModel?
    private let classicalFallback: ClassicalDetector

    /// Diagnostic info from last detection (for debug logging).
    var lastDiagnostic: String = ""

    /// Model input resolution.
    static let modelSize = 512

    /// Heatmap confidence threshold for star detection.
    private let heatmapThreshold: Float = 0.3

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

        // Step 1: Downscale cropped square to modelSize×modelSize, percentile normalize
        let inputArray = try prepareModelInput(
            pixelData: pixelData, fullWidth: fullW,
            cropX0: cropX0, cropY0: cropY0, cropSize: cropSize
        )

        // Step 2: Run inference
        let provider = try MLDictionaryFeatureProvider(dictionary: ["image": inputArray])
        let prediction = try model.prediction(from: provider)

        guard let heatmapArray = prediction.featureValue(for: "heatmap")?.multiArrayValue else {
            throw CoreMLDetectorError.invalidOutput
        }

        let size = Self.modelSize
        let planeSize = size * size

        // Extract single-channel heatmap
        var heatmap = [Float](repeating: 0, count: planeSize)
        for i in 0..<planeSize {
            heatmap[i] = heatmapArray[i].floatValue
        }

        // Diagnostics
        let hmMin = heatmap.min() ?? 0
        let hmMax = heatmap.max() ?? 0

        // Step 3: Find peaks via threshold + 5×5 NMS + quadratic sub-pixel refinement
        let peaks = findHeatmapPeaks(heatmap: heatmap, width: size, height: size)

        // Step 4: Map model-space positions back to full image coordinates.
        // Model pixels map to the cropped square, which starts at (cropX0, cropY0).
        let scale = Double(cropSize) / Double(size)

        let approxPositions = peaks.map { p in
            (x: p.x * scale + Double(cropX0), y: p.y * scale + Double(cropY0))
        }

        // Step 5: Refine each position with weighted centroid on full-res pixels
        var stars = refinePositions(
            approximate: approxPositions,
            pixelData: pixelData,
            width: fullW,
            height: fullH
        )

        // Step 6: Remove duplicate detections that refined to nearby positions.
        // Sort brightest-first so the brighter detection survives.
        stars.sort { $0.brightness > $1.brightness }
        stars = enforceMinSeparation(stars, minSep: config.minSeparation)

        lastDiagnostic = String(
            format: "heatmap=[%.3f,%.3f] crop=%dx%d+%d peaks=%d dedup=%d",
            hmMin, hmMax, cropSize, cropSize, cropX0, peaks.count, stars.count
        )
        print("[CoreML] \(lastDiagnostic)")

        if stars.count > config.maxStars {
            stars = Array(stars.prefix(config.maxStars))
        }

        return stars
    }

    // MARK: - Deduplication

    /// Remove detections that are too close to a brighter detection (sorted brightest-first).
    private func enforceMinSeparation(_ stars: [DetectedStar], minSep: Float) -> [DetectedStar] {
        let minSepSq = Double(minSep * minSep)
        var kept: [DetectedStar] = []
        for star in stars {
            let tooClose = kept.contains { existing in
                let dx = star.x - existing.x
                let dy = star.y - existing.y
                return dx * dx + dy * dy < minSepSq
            }
            if !tooClose {
                kept.append(star)
            }
        }
        return kept
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
    ///
    /// Area-average downscale preserves star flux; `max(avg, maxLum*0.5)` prevents faint
    /// point sources from being averaged below detection threshold.
    /// 99.9th percentile normalization matches the training pipeline.
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

        // Step 1: Area-average downscale from cropped square, preserving peak brightness
        var downscaled = [Float](repeating: 0, count: size * size)

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
                downscaled[y * size + x] = max(avg, maxLum * 0.5)
            }
        }

        // Step 1b: Gaussian blur to widen sub-pixel stars into multi-pixel PSFs.
        // After downscaling from cropSize→512, stars with sigma ~1.5px in the original
        // become sub-pixel. The model expects stars with FWHM ~2-5px. A small blur
        // (sigma=1.2px) widens them to detectable size without smearing the background.
        if scale > 1.5 {
            let blurSigma: Float = 1.2
            downscaled = gaussianBlur2D(downscaled, width: size, height: size, sigma: blurSigma)
        }

        // Step 2: Background subtraction + 99.9th percentile normalization
        // Subtract background (median) first so stars stand out clearly,
        // then normalize by 99.9th percentile of the background-subtracted image.
        // Without background subtraction, sparse star fields have nearly all pixels
        // at ~0.04, making the 99.9th percentile a noise value that saturates the
        // entire image to near-white, hiding stars completely.
        var sorted = downscaled.sorted()
        let median = sorted[sorted.count / 2]

        for i in 0..<(size * size) {
            downscaled[i] = max(0, downscaled[i] - median)
        }

        // Now 99.9th percentile on background-subtracted data
        var rawMax: Float = 0
        for v in downscaled { rawMax = max(rawMax, v) }

        if rawMax > 0 {
            var histogram = [Int](repeating: 0, count: 1000)
            for v in downscaled {
                let bin = min(Int(v / rawMax * 999), 999)
                histogram[bin] += 1
            }
            var cumulative = 0
            let target = Int(Float(size * size) * 0.999)
            var vmax: Float = rawMax
            for (bin, cnt) in histogram.enumerated() {
                cumulative += cnt
                if cumulative >= target {
                    vmax = max(Float(bin + 1) / 1000.0 * rawMax, 1e-6)
                    break
                }
            }

            for i in 0..<(size * size) {
                array[i] = NSNumber(value: min(downscaled[i] / vmax, 1.0))
            }
        } else {
            for i in 0..<(size * size) {
                array[i] = NSNumber(value: downscaled[i])
            }
        }

        return array
    }

    // MARK: - Heatmap Peak Detection

    /// Find star positions from the model's confidence heatmap.
    ///
    /// 1. Threshold at `heatmapThreshold`
    /// 2. 5×5 local maximum (NMS): pixel must be strictly greater than all neighbors
    /// 3. Quadratic sub-pixel refinement on 3×3 neighborhood
    private func findHeatmapPeaks(
        heatmap: [Float], width: Int, height: Int
    ) -> [(x: Double, y: Double, confidence: Float)] {
        var peaks: [(x: Double, y: Double, confidence: Float)] = []

        for y in 2..<(height - 2) {
            for x in 2..<(width - 2) {
                let val = heatmap[y * width + x]
                guard val >= heatmapThreshold else { continue }

                // Check if local maximum in 5×5 neighborhood
                var isMax = true
                outer: for dy in -2...2 {
                    for dx in -2...2 {
                        if dx == 0 && dy == 0 { continue }
                        if heatmap[(y + dy) * width + (x + dx)] >= val {
                            isMax = false
                            break outer
                        }
                    }
                }
                guard isMax else { continue }

                // Quadratic sub-pixel refinement on 3×3 neighborhood
                let (subX, subY) = quadraticRefine(heatmap: heatmap, width: width, x: x, y: y)
                peaks.append((x: subX, y: subY, confidence: val))
            }
        }

        return peaks
    }

    /// Fit a 1D parabola along x and y axes through the 3×3 neighborhood
    /// to find the sub-pixel peak location.
    private func quadraticRefine(
        heatmap: [Float], width: Int, x: Int, y: Int
    ) -> (Double, Double) {
        let c = heatmap[y * width + x]
        let dxVal = (heatmap[y * width + x + 1] - heatmap[y * width + x - 1]) / 2
        let dyVal = (heatmap[(y + 1) * width + x] - heatmap[(y - 1) * width + x]) / 2
        let dxx = heatmap[y * width + x + 1] + heatmap[y * width + x - 1] - 2 * c
        let dyy = heatmap[(y + 1) * width + x] + heatmap[(y - 1) * width + x] - 2 * c

        let subX = dxx != 0 ? Double(x) - Double(dxVal / dxx) : Double(x)
        let subY = dyy != 0 ? Double(y) - Double(dyVal / dyy) : Double(y)
        return (subX, subY)
    }

    // MARK: - Pixel Sampling

    /// Sample luminance at a pixel position from half-float RGBA data.
    private func sampleLuminance(_ pixelData: [UInt16], _ stride: Int, _ x: Int, _ y: Int) -> Float {
        let idx = (y * stride + x) * 4
        let r = halfToFloat(pixelData[idx])
        let g = halfToFloat(pixelData[idx + 1])
        let b = halfToFloat(pixelData[idx + 2])
        return 0.299 * r + 0.587 * g + 0.114 * b
    }

    // MARK: - Centroid Refinement

    /// Refine approximate star positions using weighted centroid on full-resolution pixel data.
    /// This corrects the quantization error from the model grid and produces
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

    // MARK: - Image Processing

    /// Apply a separable Gaussian blur to a 2D float array.
    /// Used to widen sub-pixel stars into multi-pixel PSFs in the model input.
    private func gaussianBlur2D(_ input: [Float], width: Int, height: Int, sigma: Float) -> [Float] {
        let radius = Int(ceil(sigma * 3))
        let kernelSize = 2 * radius + 1

        // Generate 1D Gaussian kernel
        var kernel = [Float](repeating: 0, count: kernelSize)
        var kernelSum: Float = 0
        for i in 0..<kernelSize {
            let x = Float(i - radius)
            kernel[i] = exp(-x * x / (2 * sigma * sigma))
            kernelSum += kernel[i]
        }
        for i in 0..<kernelSize { kernel[i] /= kernelSum }

        // Horizontal pass
        var temp = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                var sum: Float = 0
                for k in 0..<kernelSize {
                    let sx = min(max(x + k - radius, 0), width - 1)
                    sum += input[y * width + sx] * kernel[k]
                }
                temp[y * width + x] = sum
            }
        }

        // Vertical pass
        var output = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                var sum: Float = 0
                for k in 0..<kernelSize {
                    let sy = min(max(y + k - radius, 0), height - 1)
                    sum += temp[sy * width + x] * kernel[k]
                }
                output[y * width + x] = sum
            }
        }

        return output
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
