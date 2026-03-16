import Foundation
import Metal
import CoreVideo

/// Manages the Metal device, command queue, and compute pipelines for frame processing.
///
/// Pipeline: Raw sensor data → MTLBuffer → Debayer shader → RGB MTLTexture → Display
final class MetalPipeline {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    private let debayerPipeline: MTLComputePipelineState
    private let stretchPipeline: MTLComputePipelineState

    /// Output texture after debayer + stretch.
    private(set) var outputTexture: MTLTexture?

    /// Staging buffer for uploading raw frame data to GPU.
    private var rawBuffer: MTLBuffer?
    private var rawBufferSize: Int = 0

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalPipelineError.noDevice
        }
        self.device = device

        guard let queue = device.makeCommandQueue() else {
            throw MetalPipelineError.noCommandQueue
        }
        self.commandQueue = queue

        guard let library = device.makeDefaultLibrary() else {
            throw MetalPipelineError.noLibrary
        }

        guard let debayerFunc = library.makeFunction(name: "debayer_rggb") else {
            throw MetalPipelineError.functionNotFound("debayer_rggb")
        }
        self.debayerPipeline = try device.makeComputePipelineState(function: debayerFunc)

        guard let stretchFunc = library.makeFunction(name: "auto_stretch") else {
            throw MetalPipelineError.functionNotFound("auto_stretch")
        }
        self.stretchPipeline = try device.makeComputePipelineState(function: stretchFunc)
    }

    /// Process a raw frame: debayer RGGB → RGB, apply auto-stretch for display.
    ///
    /// - Parameters:
    ///   - rawData: Pointer to raw Bayer data.
    ///   - width: Frame width in pixels.
    ///   - height: Frame height in pixels.
    ///   - bytesPerPixel: 1 for RAW8, 2 for RAW16.
    ///   - stretchParams: Black/white point for display stretch.
    /// - Returns: The output BGRA texture ready for display.
    @discardableResult
    func processFrame(
        rawData: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerPixel: Int,
        blackPoint: Float = 0.0,
        whitePoint: Float = 1.0,
        midtones: Float = 0.5,
        useSTF: Bool = false
    ) -> MTLTexture? {
        let dataSize = width * height * bytesPerPixel
        ensureRawBuffer(size: dataSize)
        ensureOutputTexture(width: width, height: height)

        guard let rawBuf = rawBuffer,
              let outTex = outputTexture,
              let cmdBuf = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuf.makeComputeCommandEncoder() else {
            return nil
        }

        // Upload raw data to GPU buffer
        rawBuf.contents().copyMemory(from: rawData, byteCount: dataSize)

        // --- Pass 1: Debayer ---
        encoder.setComputePipelineState(debayerPipeline)
        encoder.setBuffer(rawBuf, offset: 0, index: 0)

        // Create intermediate RGB float texture for debayer output
        let intermediateDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        intermediateDesc.usage = [.shaderRead, .shaderWrite]
        guard let intermediateTex = device.makeTexture(descriptor: intermediateDesc) else {
            encoder.endEncoding()
            return nil
        }

        encoder.setTexture(intermediateTex, index: 0)

        var params = DebayerParams(
            width: UInt32(width),
            height: UInt32(height),
            bytesPerPixel: UInt32(bytesPerPixel)
        )
        encoder.setBytes(&params, length: MemoryLayout<DebayerParams>.size, index: 1)

        let debayerThreads = MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1)
        let debayerGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        encoder.dispatchThreadgroups(debayerThreads, threadsPerThreadgroup: debayerGroupSize)

        // --- Pass 2: Auto-stretch to display range ---
        encoder.setComputePipelineState(stretchPipeline)
        encoder.setTexture(intermediateTex, index: 0)
        encoder.setTexture(outTex, index: 1)

        var stretchParams = StretchParams(blackPoint: blackPoint, whitePoint: whitePoint,
                                             midtones: midtones, useSTF: useSTF ? 1 : 0)
        encoder.setBytes(&stretchParams, length: MemoryLayout<StretchParams>.size, index: 0)

        let stretchThreads = MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1)
        encoder.dispatchThreadgroups(stretchThreads, threadsPerThreadgroup: debayerGroupSize)

        encoder.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        return outTex
    }

    // MARK: - Resource Management

    private func ensureRawBuffer(size: Int) {
        if rawBufferSize < size {
            rawBuffer = device.makeBuffer(length: size, options: .storageModeShared)
            rawBufferSize = size
        }
    }

    private func ensureOutputTexture(width: Int, height: Int) {
        if let existing = outputTexture, existing.width == width, existing.height == height {
            return
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        outputTexture = device.makeTexture(descriptor: desc)
    }
}

// MARK: - Shader Parameter Structs

struct DebayerParams {
    var width: UInt32
    var height: UInt32
    var bytesPerPixel: UInt32
}

struct StretchParams {
    var blackPoint: Float
    var whitePoint: Float
    var midtones: Float
    var useSTF: UInt32
}

// MARK: - Errors

enum MetalPipelineError: Error, LocalizedError {
    case noDevice
    case noCommandQueue
    case noLibrary
    case functionNotFound(String)

    var errorDescription: String? {
        switch self {
        case .noDevice:             return "No Metal device found"
        case .noCommandQueue:       return "Failed to create command queue"
        case .noLibrary:            return "No Metal shader library found"
        case .functionNotFound(let name): return "Shader function '\(name)' not found"
        }
    }
}
