import SwiftUI
import Metal
import MetalKit

/// Displays live camera frames using Metal rendering.
///
/// The image is scaled to fill the view using a fullscreen triangle shader.
/// The `imageRect` published on the view model gives the actual image area
/// in SwiftUI points, so overlays can position correctly.
struct CameraPreviewView: NSViewRepresentable {
    @ObservedObject var viewModel: CameraPreviewViewModel

    func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = viewModel.device
        mtkView.delegate = context.coordinator
        // Continuous 30fps redraw, decoupled from SwiftUI layout.
        mtkView.isPaused = false
        mtkView.preferredFramesPerSecond = 30
        mtkView.enableSetNeedsDisplay = false
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = false
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        mtkView.autoResizeDrawable = true
        mtkView.autoresizingMask = [.width, .height]
        return mtkView
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.viewModel = viewModel
    }

    static func dismantleNSView(_ nsView: MTKView, coordinator: Coordinator) {
        coordinator.isActive = false
        nsView.isPaused = true
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    class Coordinator: NSObject, MTKViewDelegate {
        var viewModel: CameraPreviewViewModel
        /// Set to false in dismantleNSView to prevent async updates on detached views.
        var isActive = true
        private var blitPipeline: MTLRenderPipelineState?
        private var lastLoggedDrawableWidth: Int = 0
        private var lastImageRectSize: CGSize = .zero

        init(viewModel: CameraPreviewViewModel) {
            self.viewModel = viewModel
            super.init()
            buildBlitPipeline()
        }

        private func buildBlitPipeline() {
            guard let device = viewModel.device,
                  let library = device.makeDefaultLibrary(),
                  let vertexFunc = library.makeFunction(name: "blit_vertex"),
                  let fragmentFunc = library.makeFunction(name: "blit_fragment") else {
                return
            }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vertexFunc
            desc.fragmentFunction = fragmentFunc
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            blitPipeline = try? device.makeRenderPipelineState(descriptor: desc)
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            view.setNeedsDisplay(view.bounds)
        }

        func draw(in view: MTKView) {
            // Skip drawing if view is not in a window (tab switched away)
            guard view.window != nil,
                  let texture = viewModel.displayTexture,
                  let drawable = view.currentDrawable,
                  let device = viewModel.device,
                  let commandBuffer = viewModel.commandQueue?.makeCommandBuffer(),
                  let pipeline = blitPipeline else {
                return
            }

            let drawW = drawable.texture.width
            let drawH = drawable.texture.height

            // Log dimensions when drawable size changes
            if drawW != lastLoggedDrawableWidth {
                lastLoggedDrawableWidth = drawW
                let bounds = view.bounds
                let texW = texture.width
                let texH = texture.height
                let msg = "[Preview] bounds=\(Int(bounds.width))x\(Int(bounds.height)) drawable=\(drawW)x\(drawH) tex=\(texW)x\(texH)"
                Task { @MainActor [weak self] in
                    guard let self, self.isActive else { return }
                    self.viewModel.debugMessage = msg
                }
            }

            // Render fullscreen triangle sampling the source texture
            let passDesc = MTLRenderPassDescriptor()
            passDesc.colorAttachments[0].texture = drawable.texture
            passDesc.colorAttachments[0].loadAction = .clear
            passDesc.colorAttachments[0].storeAction = .store
            passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else {
                return
            }
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()

            commandBuffer.present(drawable)
            commandBuffer.commit()

            // Image fills the entire view — imageRect = full view bounds in points.
            // Only update when size changes to avoid redundant @Published updates.
            let backingScale = view.window?.backingScaleFactor ?? 2.0
            let newSize = CGSize(
                width: CGFloat(drawW) / backingScale,
                height: CGFloat(drawH) / backingScale
            )
            if newSize != lastImageRectSize {
                lastImageRectSize = newSize
                let rectInPoints = CGRect(origin: .zero, size: newSize)
                Task { @MainActor [weak self] in
                    guard let self, self.isActive else { return }
                    self.viewModel.imageRect = rectInPoints
                }
            }
        }
    }
}

/// ViewModel that bridges FrameGrabber output to Metal display.
@MainActor
final class CameraPreviewViewModel: ObservableObject {
    let device: MTLDevice?
    let commandQueue: MTLCommandQueue?

    /// The texture is updated directly — MTKView reads it in draw(), no SwiftUI layout needed.
    var displayTexture: MTLTexture?
    @Published var isCapturing = false
    /// Frame stats — only frameRate is @Published to minimize SwiftUI invalidation.
    @Published var frameRate: Double = 0
    var frameCount: UInt64 = 0
    /// Time of last received frame (CFAbsoluteTime). UI can compare to `now` for activity indicator.
    var lastFrameTimestamp: CFAbsoluteTime = 0

    /// The actual image rectangle in SwiftUI points within the preview view.
    /// Used by overlays to position star markers correctly.
    @Published var imageRect: CGRect = .zero

    /// Debug message from the draw function (logged once, displayed in debug strip).
    @Published var debugMessage: String?

    /// Called after each frame is processed (on MainActor).
    var onFrameProcessed: (() -> Void)?

    private var pipeline: MetalPipeline?
    private var lastFrameTime: CFAbsoluteTime = 0
    /// Smoothing factor for EMA frame rate (0..1, lower = smoother).
    private let fpsAlpha: Double = 0.2
    /// Atomic flag: true while a MainActor Task is queued/running. Prevents frame queue buildup.
    private let _processing = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    /// Capture-thread frame counter (atomic increment, no MainActor dependency).
    private let _captureFrameCount = UnsafeMutablePointer<Int64>.allocate(capacity: 1)

    init() {
        self.device = MTLCreateSystemDefaultDevice()
        self.commandQueue = device?.makeCommandQueue()
        self.pipeline = try? MetalPipeline()
        _processing.initialize(to: 0)
        _captureFrameCount.initialize(to: 0)
    }

    deinit {
        _processing.deallocate()
        _captureFrameCount.deallocate()
    }

    /// Called from the capture thread — dispatches to main for texture update.
    /// Drops frames if the main thread hasn't finished processing the previous one.
    nonisolated func processFrame(
        buffer: UnsafeBufferPointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerPixel: Int
    ) {
        let captureTime = CFAbsoluteTimeGetCurrent()
        let captureCount = UInt64(OSAtomicIncrement64(_captureFrameCount))

        // Drop frame if main thread is still processing the previous one
        guard OSAtomicCompareAndSwap32(0, 1, _processing) else { return }

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

            // Frame rate: exponential moving average using capture-thread timestamp
            if self.lastFrameTime > 0 {
                let dt = captureTime - self.lastFrameTime
                if dt > 0 {
                    let instantFps = 1.0 / dt
                    if self.frameRate > 0 {
                        self.frameRate = self.fpsAlpha * instantFps + (1.0 - self.fpsAlpha) * self.frameRate
                    } else {
                        self.frameRate = instantFps
                    }
                }
            }
            self.lastFrameTime = captureTime
            self.lastFrameTimestamp = captureTime
            self.frameCount = captureCount

            // Allow next frame to be queued
            OSAtomicCompareAndSwap32(1, 0, self._processing)

            // Trigger star detection callback
            self.onFrameProcessed?()
        }
    }

    /// Reset frame rate tracking (call when capture starts/stops).
    func resetFrameRate() {
        lastFrameTime = 0
        frameRate = 0
        lastFrameTimestamp = 0
    }
}

// MARK: - Frame Rate Overlay

/// Shows fps with a blinking dot indicating frame activity.
/// Dot turns green briefly on each new frame, dims while waiting.
struct FrameRateView: View {
    @ObservedObject var previewViewModel: CameraPreviewViewModel
    @State private var dotOpacity: Double = 0.3
    @State private var waitSeconds: Double = 0
    @State private var timer: Timer?

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
                .opacity(dotOpacity)

            if previewViewModel.frameRate > 0 {
                Text(fpsText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .onChange(of: previewViewModel.frameRate) {
            // Flash dot bright on new frame
            withAnimation(.easeIn(duration: 0.1)) {
                dotOpacity = 1.0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation(.easeOut(duration: 0.5)) {
                    dotOpacity = 0.3
                }
            }
            waitSeconds = 0
        }
        .onAppear { startTimer() }
        .onDisappear { stopTimer() }
    }

    private var dotColor: Color {
        waitSeconds > 3 ? .orange : .green
    }

    private var fpsText: String {
        let fps = previewViewModel.frameRate
        if fps >= 1.0 {
            return String(format: "%.1f fps", fps)
        } else if fps > 0 {
            // Show as interval for slow frame rates (e.g. "2.1s/f")
            return String(format: "%.1fs/f", 1.0 / fps)
        }
        return ""
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                let ts = previewViewModel.lastFrameTimestamp
                if ts > 0 {
                    waitSeconds = CFAbsoluteTimeGetCurrent() - ts
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
