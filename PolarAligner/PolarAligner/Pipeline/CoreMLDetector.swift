import Foundation
import CoreML
import Metal

/// Star detection using a Core ML UNet model.
///
/// The model takes a downscaled grayscale image (256x256) and outputs a heatmap
/// where peaks correspond to star positions. These are then mapped back to
/// full-resolution coordinates and refined with sub-pixel centroiding.
///
/// Expected model:
/// - Input: grayscale image 256x256 (MLMultiArray or CVPixelBuffer)
/// - Output: heatmap 256x256 (MLMultiArray, float, peaks = star positions)
final class CoreMLDetector: StarDetectorProtocol {
    private let config: StarDetectionConfig
    private var model: MLModel?
    private let classicalFallback: ClassicalDetector
    private var luminancePipeline: MTLComputePipelineState?

    /// Model input resolution.
    static let modelSize = 256

    init(config: StarDetectionConfig = StarDetectionConfig()) {
        self.config = config
        self.classicalFallback = ClassicalDetector(config: config)
    }

    /// Load the Core ML model from a .mlmodelc bundle.
    func loadModel(from url: URL) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all // Use Neural Engine when available
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
            // Fall back to classical detection if no model loaded
            return try classicalFallback.detectStars(in: texture, device: device, commandQueue: commandQueue)
        }

        let fullW = texture.width
        let fullH = texture.height

        // Step 1: Downscale to model input size and convert to grayscale
        let inputArray = try prepareInput(
            texture: texture,
            device: device,
            commandQueue: commandQueue
        )

        // Step 2: Run inference
        let provider = try MLDictionaryFeatureProvider(dictionary: ["image": inputArray])
        let prediction = try model.prediction(from: provider)

        guard let heatmap = prediction.featureValue(for: "heatmap")?.multiArrayValue else {
            throw CoreMLDetectorError.invalidOutput
        }

        // Step 3: Find peaks in the heatmap
        let peaks = findHeatmapPeaks(heatmap)

        // Step 4: Map peaks back to full resolution
        let scaleX = Double(fullW) / Double(Self.modelSize)
        let scaleY = Double(fullH) / Double(Self.modelSize)

        let mappedPeaks: [DetectedStar] = peaks.map { peak in
            DetectedStar(
                x: peak.x * scaleX,
                y: peak.y * scaleY,
                brightness: peak.brightness,
                fwhm: peak.fwhm * scaleX,  // Scale FWHM too
                snr: peak.snr
            )
        }

        // TODO: Step 5: Refine centroids on full-res image using CentroidExtractor

        return mappedPeaks
    }

    // MARK: - Input Preparation

    private func prepareInput(
        texture: MTLTexture,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> MLMultiArray {
        let size = Self.modelSize

        // Read texture to CPU, downscale, convert to grayscale
        let w = texture.width
        let h = texture.height

        // Read RGBA half-float texture
        var pixelData = [UInt16](repeating: 0, count: w * h * 4)
        let bytesPerRow = w * 4 * MemoryLayout<UInt16>.size
        let region = MTLRegion(origin: MTLOrigin(), size: MTLSize(width: w, height: h, depth: 1))
        texture.getBytes(&pixelData, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)

        // Create MLMultiArray for model input (1 x 256 x 256)
        let array = try MLMultiArray(shape: [1, NSNumber(value: size), NSNumber(value: size)], dataType: .float32)

        let scaleX = Float(w) / Float(size)
        let scaleY = Float(h) / Float(size)

        for y in 0..<size {
            for x in 0..<size {
                let srcX = Int(Float(x) * scaleX)
                let srcY = Int(Float(y) * scaleY)
                let srcIdx = (srcY * w + srcX) * 4

                // Convert half-float to float for R, G, B channels
                let r = halfToFloat(pixelData[srcIdx])
                let g = halfToFloat(pixelData[srcIdx + 1])
                let b = halfToFloat(pixelData[srcIdx + 2])

                // Luminance
                let lum = 0.299 * r + 0.587 * g + 0.114 * b
                array[y * size + x] = NSNumber(value: lum)
            }
        }

        return array
    }

    // MARK: - Peak Finding in Heatmap

    private func findHeatmapPeaks(_ heatmap: MLMultiArray) -> [DetectedStar] {
        let size = Self.modelSize
        var peaks: [DetectedStar] = []

        // Simple threshold + NMS on the heatmap
        let threshold: Float = 0.3 // Configurable

        for y in 2..<(size - 2) {
            for x in 2..<(size - 2) {
                let val = heatmap[y * size + x].floatValue

                guard val > threshold else { continue }

                // 3x3 local maximum check
                var isMax = true
                for dy in -1...1 {
                    for dx in -1...1 {
                        if dx == 0 && dy == 0 { continue }
                        let nval = heatmap[(y + dy) * size + (x + dx)].floatValue
                        if nval >= val {
                            isMax = false
                            break
                        }
                    }
                    if !isMax { break }
                }

                if isMax {
                    // Sub-pixel refinement via quadratic fit on the heatmap
                    let (sx, sy) = quadraticSubpixel(heatmap, x: x, y: y, size: size)

                    peaks.append(DetectedStar(
                        x: Double(sx),
                        y: Double(sy),
                        brightness: Double(val),
                        fwhm: 0,
                        snr: Double(val / threshold)
                    ))
                }
            }
        }

        peaks.sort { $0.brightness > $1.brightness }
        if peaks.count > config.maxStars {
            peaks = Array(peaks.prefix(config.maxStars))
        }

        return peaks
    }

    /// Quadratic sub-pixel refinement around a peak.
    private func quadraticSubpixel(_ heatmap: MLMultiArray, x: Int, y: Int, size: Int) -> (Float, Float) {
        let c = heatmap[y * size + x].floatValue
        let xm = heatmap[y * size + (x - 1)].floatValue
        let xp = heatmap[y * size + (x + 1)].floatValue
        let ym = heatmap[(y - 1) * size + x].floatValue
        let yp = heatmap[(y + 1) * size + x].floatValue

        var dx: Float = 0
        var dy: Float = 0
        let denom_x = 2.0 * c - xm - xp
        let denom_y = 2.0 * c - ym - yp

        if abs(denom_x) > 1e-6 {
            dx = (xm - xp) / (2.0 * denom_x)
        }
        if abs(denom_y) > 1e-6 {
            dy = (ym - yp) / (2.0 * denom_y)
        }

        return (Float(x) + clamp(dx, -0.5, 0.5), Float(y) + clamp(dy, -0.5, 0.5))
    }

    /// Convert IEEE 754 half-float (UInt16) to Float.
    private func halfToFloat(_ h: UInt16) -> Float {
        let sign = (h >> 15) & 1
        let exponent = (h >> 10) & 0x1F
        let mantissa = h & 0x3FF

        if exponent == 0 {
            if mantissa == 0 { return sign == 0 ? 0.0 : -0.0 }
            // Subnormal
            var m = Float(mantissa) / 1024.0
            m *= pow(2.0, -14.0)
            return sign == 0 ? m : -m
        } else if exponent == 31 {
            return mantissa == 0 ? (sign == 0 ? .infinity : -.infinity) : .nan
        }

        let f = Float(sign == 0 ? 1 : -1) * pow(2.0, Float(Int(exponent) - 15)) * (1.0 + Float(mantissa) / 1024.0)
        return f
    }

    private func clamp(_ x: Float, _ lo: Float, _ hi: Float) -> Float {
        return min(max(x, lo), hi)
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
