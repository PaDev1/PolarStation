import SwiftUI
import Metal
import MetalKit

/// Displays live camera frames using Metal rendering.
struct CameraPreviewView: NSViewRepresentable {
    @ObservedObject var viewModel: CameraPreviewViewModel

    func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = viewModel.device
        mtkView.delegate = context.coordinator
        mtkView.enableSetNeedsDisplay = true
        mtkView.isPaused = true
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = false
        return mtkView
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.viewModel = viewModel
        nsView.setNeedsDisplay(nsView.bounds)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    class Coordinator: NSObject, MTKViewDelegate {
        var viewModel: CameraPreviewViewModel

        init(viewModel: CameraPreviewViewModel) {
            self.viewModel = viewModel
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let texture = viewModel.displayTexture,
                  let drawable = view.currentDrawable,
                  let commandBuffer = viewModel.commandQueue?.makeCommandBuffer() else {
                return
            }

            // Blit the processed texture to the drawable
            let blitEncoder = commandBuffer.makeBlitCommandEncoder()
            let sourceSize = MTLSize(width: min(texture.width, drawable.texture.width),
                                     height: min(texture.height, drawable.texture.height),
                                     depth: 1)
            blitEncoder?.copy(
                from: texture,
                sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: sourceSize,
                to: drawable.texture,
                destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blitEncoder?.endEncoding()

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}

/// ViewModel that bridges FrameGrabber output to Metal display.
@MainActor
final class CameraPreviewViewModel: ObservableObject {
    let device: MTLDevice?
    let commandQueue: MTLCommandQueue?

    @Published var displayTexture: MTLTexture?
    @Published var isCapturing = false
    @Published var frameRate: Double = 0
    @Published var frameCount: UInt64 = 0

    /// Called after each frame is processed (on MainActor).
    var onFrameProcessed: (() -> Void)?

    private var pipeline: MetalPipeline?
    private var lastFrameTime: CFAbsoluteTime = 0

    init() {
        self.device = MTLCreateSystemDefaultDevice()
        self.commandQueue = device?.makeCommandQueue()
        self.pipeline = try? MetalPipeline()
    }

    /// Called from the capture thread — dispatches to main for texture update.
    nonisolated func processFrame(
        buffer: UnsafeBufferPointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerPixel: Int
    ) {
        // Copy the buffer since it will be reused by the capture thread
        let dataCopy = Data(buffer)

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            dataCopy.withUnsafeBytes { rawBuffer in
                guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                self.displayTexture = self.pipeline?.processFrame(
                    rawData: ptr,
                    width: width,
                    height: height,
                    bytesPerPixel: bytesPerPixel
                )
            }

            // Frame rate calculation
            let now = CFAbsoluteTimeGetCurrent()
            if self.lastFrameTime > 0 {
                let dt = now - self.lastFrameTime
                self.frameRate = 1.0 / dt
            }
            self.lastFrameTime = now
            self.frameCount += 1

            // Trigger star detection callback
            self.onFrameProcessed?()
        }
    }
}
