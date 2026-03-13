import SwiftUI
import Metal
import MetalKit
import MetalPerformanceShaders

/// Displays live camera frames using Metal rendering.
///
/// The image is scaled to fill the view using aspect-fit (letterboxed).
/// The `imageRect` published on the view model gives the actual image area
/// in SwiftUI points, so overlays can position correctly.
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
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        return mtkView
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.viewModel = viewModel
        // Force drawable to match the view's actual size
        let scale = nsView.window?.backingScaleFactor ?? 2.0
        let newSize = CGSize(
            width: nsView.bounds.width * scale,
            height: nsView.bounds.height * scale
        )
        if nsView.drawableSize != newSize && newSize.width > 0 && newSize.height > 0 {
            nsView.drawableSize = newSize
        }
        nsView.setNeedsDisplay(nsView.bounds)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    class Coordinator: NSObject, MTKViewDelegate {
        var viewModel: CameraPreviewViewModel
        private var loggedDimensions = false

        init(viewModel: CameraPreviewViewModel) {
            self.viewModel = viewModel
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let texture = viewModel.displayTexture,
                  let drawable = view.currentDrawable,
                  let device = viewModel.device,
                  let commandBuffer = viewModel.commandQueue?.makeCommandBuffer() else {
                return
            }

            let drawW = drawable.texture.width
            let drawH = drawable.texture.height
            let texW = texture.width
            let texH = texture.height

            // Log dimensions once for debugging
            if !loggedDimensions {
                loggedDimensions = true
                let bounds = view.bounds
                let drawableSize = view.drawableSize
                let msg = "[Preview] bounds=\(Int(bounds.width))x\(Int(bounds.height)) drawableSize=\(Int(drawableSize.width))x\(Int(drawableSize.height)) drawable=\(drawW)x\(drawH) tex=\(texW)x\(texH)"
                Task { @MainActor [weak self] in
                    self?.viewModel.debugMessage = msg
                }
            }

            // Scale the source image to fill the entire drawable (stretch to fit).
            // imageRect covers the full view so overlays map 1:1.
            let scaler = MPSImageBilinearScale(device: device)
            var transform = MPSScaleTransform(
                scaleX: Double(texW) / Double(drawW),
                scaleY: Double(texH) / Double(drawH),
                translateX: 0,
                translateY: 0
            )
            withUnsafePointer(to: &transform) { ptr in
                scaler.scaleTransform = ptr
                scaler.encode(commandBuffer: commandBuffer,
                             sourceTexture: texture,
                             destinationTexture: drawable.texture)
            }

            commandBuffer.present(drawable)
            commandBuffer.commit()

            // Image fills the entire view — imageRect = full view bounds in points
            let backingScale = view.window?.backingScaleFactor ?? 2.0
            let rectInPoints = CGRect(
                x: 0,
                y: 0,
                width: CGFloat(drawW) / backingScale,
                height: CGFloat(drawH) / backingScale
            )
            Task { @MainActor [weak self] in
                self?.viewModel.imageRect = rectInPoints
            }
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

    /// The actual image rectangle in SwiftUI points within the preview view.
    /// Used by overlays to position star markers correctly.
    @Published var imageRect: CGRect = .zero

    /// Debug message from the draw function (logged once, displayed in debug strip).
    @Published var debugMessage: String?

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
