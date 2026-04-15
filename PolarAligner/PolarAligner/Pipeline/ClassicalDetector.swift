import Foundation
import Metal
import MetalPerformanceShaders

/// Classical star detection using Metal Performance Shaders.
///
/// Pipeline:
/// 1. Convert debayered RGBA to grayscale luminance
/// 2. Gaussian blur for background estimation
/// 3. Background subtraction
/// 4. Threshold to create binary mask
/// 5. Find local maxima (peaks)
/// 6. Sub-pixel centroid refinement (CentroidExtractor.metal)
final class ClassicalDetector: StarDetectorProtocol {
    /// Active detection config — can be swapped at runtime (e.g. Sharp/Diffused preset).
    var config: StarDetectionConfig
    private var centroidPipeline: MTLComputePipelineState?
    private var luminancePipeline: MTLComputePipelineState?

    // Reusable textures
    private var luminanceTexture: MTLTexture?
    private var blurredTexture: MTLTexture?
    private var subtractedTexture: MTLTexture?
    private var lastWidth: Int = 0
    private var lastHeight: Int = 0

    init(config: StarDetectionConfig = StarDetectionConfig()) {
        self.config = config
    }

    func detectStars(
        in texture: MTLTexture,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> [DetectedStar] {
        try ensurePipelines(device: device)
        let w = texture.width
        let h = texture.height
        ensureTextures(device: device, width: w, height: h)

        guard let lumTex = luminanceTexture,
              let blurTex = blurredTexture,
              let subTex = subtractedTexture,
              let cmdBuf = commandQueue.makeCommandBuffer() else {
            return []
        }

        // Step 1: Convert to luminance
        if let encoder = cmdBuf.makeComputeCommandEncoder(), let lumPipeline = luminancePipeline {
            encoder.setComputePipelineState(lumPipeline)
            encoder.setTexture(texture, index: 0)
            encoder.setTexture(lumTex, index: 1)
            let threads = MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1)
            let groups = MTLSize(width: 16, height: 16, depth: 1)
            encoder.dispatchThreadgroups(threads, threadsPerThreadgroup: groups)
            encoder.endEncoding()
        }

        // Step 2: Gaussian blur for background estimation
        let blur = MPSImageGaussianBlur(device: device, sigma: config.backgroundSigma)
        blur.edgeMode = .clamp
        blur.encode(commandBuffer: cmdBuf, sourceTexture: lumTex, destinationTexture: blurTex)

        // Step 3: Background subtraction done on CPU in findPeaks()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        // Read luminance and blurred textures back for peak finding
        let peaks = try findPeaks(
            luminance: lumTex,
            background: blurTex,
            width: w,
            height: h,
            device: device,
            commandQueue: commandQueue
        )

        // Step 6: Sub-pixel centroid refinement on GPU
        let refined = try refineCentroids(
            candidates: peaks,
            luminance: lumTex,
            device: device,
            commandQueue: commandQueue
        )

        return refined
    }

    // MARK: - Peak Finding

    /// Find local maxima in the background-subtracted image.
    /// Done on CPU for simplicity; the number of pixels scanned is manageable
    /// at 1920x1080 (2M pixels, ~3ms).
    private func findPeaks(
        luminance: MTLTexture,
        background: MTLTexture,
        width: Int,
        height: Int,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> [PeakCandidate] {
        // Read textures to CPU
        let lumData = readTexture(luminance, width: width, height: height)
        let bgData = readTexture(background, width: width, height: height)

        guard lumData.count == width * height,
              bgData.count == width * height else {
            return []
        }

        // Compute background-subtracted image and statistics
        var subtracted = [Float](repeating: 0, count: width * height)
        var sum: Double = 0
        var sumSq: Double = 0
        var count: Double = 0

        for i in 0..<(width * height) {
            let val = lumData[i] - bgData[i]
            subtracted[i] = max(val, 0)
            if val > 0 {
                sum += Double(val)
                sumSq += Double(val) * Double(val)
                count += 1
            }
        }

        let mean = count > 0 ? sum / count : 0
        let stddev = count > 1 ? sqrt((sumSq - sum * sum / count) / (count - 1)) : 1
        let threshold = Float(mean + Double(config.detectionSigma) * stddev)

        // Find local maxima above threshold
        let minSep = Int(config.minSeparation)
        var peaks: [PeakCandidate] = []

        for y in minSep..<(height - minSep) {
            for x in minSep..<(width - minSep) {
                let idx = y * width + x
                let val = subtracted[idx]

                guard val > threshold else { continue }

                // Check if local maximum in 3x3 neighborhood.
                // Use strict `>` so flat-top peaks (common with diffuse stars on
                // less-sharp optics) are not all rejected as "neighbor equals me".
                // Min-separation enforcement below dedupes plateau pixels.
                var isMax = true
                for dy in -1...1 {
                    for dx in -1...1 {
                        if dx == 0 && dy == 0 { continue }
                        let nidx = (y + dy) * width + (x + dx)
                        if subtracted[nidx] > val {
                            isMax = false
                            break
                        }
                    }
                    if !isMax { break }
                }

                if isMax {
                    peaks.append(PeakCandidate(x: Float(x), y: Float(y), peakValue: val))
                }
            }
        }

        // Sort by brightness and enforce minimum separation
        peaks.sort { $0.peakValue > $1.peakValue }
        peaks = enforceMinSeparation(peaks, minSep: config.minSeparation)

        // Limit count
        if peaks.count > config.maxStars {
            peaks = Array(peaks.prefix(config.maxStars))
        }

        return peaks
    }

    /// Remove detections that are too close to a brighter detection.
    private func enforceMinSeparation(_ peaks: [PeakCandidate], minSep: Float) -> [PeakCandidate] {
        var kept: [PeakCandidate] = []
        let minSepSq = minSep * minSep

        for peak in peaks {
            let tooClose = kept.contains { existing in
                let dx = peak.x - existing.x
                let dy = peak.y - existing.y
                return dx * dx + dy * dy < minSepSq
            }
            if !tooClose {
                kept.append(peak)
            }
        }
        return kept
    }

    // MARK: - Centroid Refinement

    /// Run sub-pixel centroid refinement on GPU.
    private func refineCentroids(
        candidates: [PeakCandidate],
        luminance: MTLTexture,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> [DetectedStar] {
        guard !candidates.isEmpty, let pipeline = centroidPipeline else {
            return []
        }

        let count = candidates.count

        // Upload candidates to GPU buffer
        let candidateBuffer = device.makeBuffer(
            bytes: candidates,
            length: count * MemoryLayout<PeakCandidate>.stride,
            options: .storageModeShared
        )

        // Allocate output buffer
        let resultBuffer = device.makeBuffer(
            length: count * MemoryLayout<CentroidResultGPU>.stride,
            options: .storageModeShared
        )

        guard let candBuf = candidateBuffer, let resBuf = resultBuffer,
              let cmdBuf = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuf.makeComputeCommandEncoder() else {
            return []
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(luminance, index: 0)
        encoder.setBuffer(candBuf, offset: 0, index: 0)
        encoder.setBuffer(resBuf, offset: 0, index: 1)

        var params = CentroidParamsGPU(
            width: UInt32(luminance.width),
            height: UInt32(luminance.height),
            halfWidth: UInt32(config.centroidHalfWidth),
            threshold: 0.001,
            maxCandidates: UInt32(count)
        )
        encoder.setBytes(&params, length: MemoryLayout<CentroidParamsGPU>.size, index: 2)

        let threadgroups = MTLSize(width: (count + 63) / 64, height: 1, depth: 1)
        let threadsPerGroup = MTLSize(width: 64, height: 1, depth: 1)
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()

        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        // Read results
        let resultPtr = resBuf.contents().bindMemory(to: CentroidResultGPU.self, capacity: count)
        var stars: [DetectedStar] = []

        for i in 0..<count {
            let r = resultPtr[i]
            if r.valid == 1 && r.snr >= Float(config.minSNR) {
                stars.append(DetectedStar(
                    x: Double(r.x),
                    y: Double(r.y),
                    brightness: Double(r.brightness),
                    fwhm: Double(r.fwhm),
                    snr: Double(r.snr)
                ))
            }
        }

        stars.sort { $0.brightness > $1.brightness }
        return stars
    }

    // MARK: - Texture I/O

    private func readTexture(_ texture: MTLTexture, width: Int, height: Int) -> [Float] {
        var data = [Float](repeating: 0, count: width * height)
        let bytesPerRow = width * MemoryLayout<Float>.size
        let region = MTLRegion(origin: MTLOrigin(), size: MTLSize(width: width, height: height, depth: 1))
        texture.getBytes(&data, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)
        return data
    }

    // MARK: - Pipeline Setup

    private func ensurePipelines(device: MTLDevice) throws {
        guard centroidPipeline == nil else { return }
        guard let library = device.makeDefaultLibrary() else {
            throw MetalPipelineError.noLibrary
        }
        guard let centroidFunc = library.makeFunction(name: "refine_centroids") else {
            throw MetalPipelineError.functionNotFound("refine_centroids")
        }
        centroidPipeline = try device.makeComputePipelineState(function: centroidFunc)

        guard let lumFunc = library.makeFunction(name: "rgba_to_luminance") else {
            throw MetalPipelineError.functionNotFound("rgba_to_luminance")
        }
        luminancePipeline = try device.makeComputePipelineState(function: lumFunc)
    }

    private func ensureTextures(device: MTLDevice, width: Int, height: Int) {
        guard width != lastWidth || height != lastHeight else { return }
        lastWidth = width
        lastHeight = height

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        // Must use .shared so CPU can read back via getBytes after GPU writes
        desc.storageMode = .shared
        luminanceTexture = device.makeTexture(descriptor: desc)
        blurredTexture = device.makeTexture(descriptor: desc)
        subtractedTexture = device.makeTexture(descriptor: desc)
    }
}

// MARK: - GPU Structs (must match CentroidExtractor.metal)

/// Matches `StarCandidate` in Metal.
private struct PeakCandidate {
    var x: Float
    var y: Float
    var peakValue: Float
}

/// Matches `CentroidParams` in Metal.
private struct CentroidParamsGPU {
    var width: UInt32
    var height: UInt32
    var halfWidth: UInt32
    var threshold: Float
    var maxCandidates: UInt32
}

/// Matches `CentroidResult` in Metal.
private struct CentroidResultGPU {
    var x: Float
    var y: Float
    var brightness: Float
    var fwhm: Float
    var snr: Float
    var valid: UInt32
}
