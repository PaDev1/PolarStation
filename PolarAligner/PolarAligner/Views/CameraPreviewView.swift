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
            var blitParams = SIMD4<Float>(viewModel.displayRotationRad, 0, 0, 0)
            encoder.setFragmentBytes(&blitParams, length: MemoryLayout<SIMD4<Float>>.size, index: 0)

            // Aspect-fit viewport: scale the image into the drawable while
            // preserving the texture's aspect ratio. Unused area stays black
            // (clear color) which produces letterbox/pillarbox bars.
            let texW = Double(texture.width)
            let texH = Double(texture.height)
            let dW = Double(drawW)
            let dH = Double(drawH)
            let texAspect = texW / texH
            let drawAspect = dW / dH
            let vpW: Double
            let vpH: Double
            if texAspect > drawAspect {
                // Texture wider than view → fit width, letterbox top/bottom
                vpW = dW
                vpH = dW / texAspect
            } else {
                // Texture taller than view → fit height, pillarbox left/right
                vpH = dH
                vpW = dH * texAspect
            }
            let vpX = (dW - vpW) / 2.0
            let vpY = (dH - vpH) / 2.0
            let viewport = MTLViewport(originX: vpX, originY: vpY,
                                       width: vpW, height: vpH,
                                       znear: 0.0, zfar: 1.0)
            encoder.setViewport(viewport)

            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()

            commandBuffer.present(drawable)
            commandBuffer.commit()

            // imageRect = the actual image region in SwiftUI points (so star
            // overlays etc. line up with the letterboxed image, not the bars).
            let backingScale = view.window?.backingScaleFactor ?? 2.0
            let newRect = CGRect(
                x: vpX / backingScale,
                y: vpY / backingScale,
                width: vpW / backingScale,
                height: vpH / backingScale
            )
            if newRect.size != lastImageRectSize {
                lastImageRectSize = newRect.size
                Task { @MainActor [weak self] in
                    guard let self, self.isActive else { return }
                    self.viewModel.imageRect = newRect
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

    /// Auto-stretch toggle: when enabled, computes STF auto-stretch from image statistics.
    @Published var autoStretchEnabled = false {
        didSet { _autoStretchFlag.pointee = autoStretchEnabled ? 1 : 0 }
    }

    /// STF stretch strength — target background display level (0.05 subtle … 0.40 aggressive).
    /// Defaults to 0.15. Written from MainActor, read from capture thread via pointer.
    @Published var stfStrength: Float = 0.15 {
        didSet { _stfStrengthPointer.pointee = stfStrength }
    }

    /// Current STF parameters (computed from image stats when autoStretch is on).
    var stfBlackPoint: Float = 0.0
    var stfWhitePoint: Float = 1.0
    var stfMidtones: Float = 0.5

    /// Image flip settings (applied in debayer shader).
    var flipX: Bool = false
    var flipY: Bool = false

    /// Display rotation in radians (applied in blit shader for visual orientation).
    var displayRotationRad: Float = 0.0

    /// Bayer pattern offsets (set from camera info or settings).
    var bayerOffsetX: UInt32 = 0
    var bayerOffsetY: UInt32 = 0

    /// Nonisolated-safe flag for reading autoStretchEnabled from capture thread.
    private let _autoStretchFlag = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    /// Nonisolated-safe copy of stfStrength for capture thread reads.
    private let _stfStrengthPointer = UnsafeMutablePointer<Float>.allocate(capacity: 1)
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
        _autoStretchFlag.initialize(to: 0)
        _stfStrengthPointer.initialize(to: 0.15)
    }

    deinit {
        _processing.deallocate()
        _captureFrameCount.deallocate()
        _autoStretchFlag.deallocate()
        _stfStrengthPointer.deallocate()
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

        // Drop partial frames — Alpaca may deliver incomplete data if the connection is slow
        let expectedSize = width * height * bytesPerPixel
        guard buffer.count >= expectedSize else {
            OSAtomicCompareAndSwap32(1, 0, _processing)
            return
        }

        // Copy the buffer since it will be reused by the capture thread
        let dataCopy = Data(buffer)

        // Compute STF stats on capture thread (cheap, avoids main thread work)
        let wantSTF = _autoStretchFlag.pointee != 0
        let stfStrengthSnapshot = _stfStrengthPointer.pointee
        let stfParams: (black: Float, white: Float, mid: Float)?
        if wantSTF {
            stfParams = Self.computeSTFParamsSync(
                data: dataCopy, width: width, height: height,
                bytesPerPixel: bytesPerPixel, targetBackground: stfStrengthSnapshot)
        } else {
            stfParams = nil
        }

        Task { @MainActor [weak self] in
            guard let self = self else { return }

            // Apply STF params if computed
            if let stf = stfParams {
                self.stfBlackPoint = stf.black
                self.stfWhitePoint = stf.white
                self.stfMidtones = stf.mid
            }

            let useSTF = self.autoStretchEnabled
            let bp = useSTF ? self.stfBlackPoint : Float(0.0)
            let wp = useSTF ? self.stfWhitePoint : Float(1.0)
            let mid = useSTF ? self.stfMidtones : Float(0.5)

            dataCopy.withUnsafeBytes { rawBuffer in
                guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                self.displayTexture = self.pipeline?.processFrame(
                    rawData: ptr,
                    width: width,
                    height: height,
                    bytesPerPixel: bytesPerPixel,
                    blackPoint: bp,
                    whitePoint: wp,
                    midtones: mid,
                    useSTF: useSTF,
                    bayerOffsetX: self.bayerOffsetX,
                    bayerOffsetY: self.bayerOffsetY,
                    flipX: self.flipX,
                    flipY: self.flipY
                )
            }

            if self.displayTexture == nil {
                self.debugMessage = "[Preview] pipeline returned nil texture! \(width)x\(height) bpp=\(bytesPerPixel) pipe=\(self.pipeline != nil)"
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

            // Allow next frame to be queued BEFORE star detection
            // so capture thread can grab the next frame while detection runs
            OSAtomicCompareAndSwap32(1, 0, self._processing)

            // Trigger star detection callback (may be slow — runs after unlocking)
            self.onFrameProcessed?()
        }
    }

    /// Process a frame that is already in BGRA8 format (e.g., decoded JPEG from a Canon EVF).
    /// Bypasses Bayer debayering — uploads BGRA bytes directly to a Metal texture.
    nonisolated func processBGRAFrame(
        buffer: UnsafeBufferPointer<UInt8>,
        width: Int,
        height: Int
    ) {
        let captureTime = CFAbsoluteTimeGetCurrent()
        let captureCount = UInt64(OSAtomicIncrement64(_captureFrameCount))

        guard OSAtomicCompareAndSwap32(0, 1, _processing) else { return }

        let expectedSize = width * height * 4
        guard buffer.count >= expectedSize, let device = self.device else {
            OSAtomicCompareAndSwap32(1, 0, _processing)
            return
        }

        let dataCopy = Data(buffer)

        Task { @MainActor [weak self] in
            guard let self else { return }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .shared
            if let tex = device.makeTexture(descriptor: descriptor) {
                dataCopy.withUnsafeBytes { rawBuffer in
                    if let base = rawBuffer.baseAddress {
                        tex.replace(region: MTLRegionMake2D(0, 0, width, height),
                                    mipmapLevel: 0,
                                    withBytes: base,
                                    bytesPerRow: width * 4)
                        self.displayTexture = tex
                    }
                }
            }

            // Frame rate
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

            OSAtomicCompareAndSwap32(1, 0, self._processing)
            self.onFrameProcessed?()
        }
    }

    /// Reset frame rate tracking (call when capture starts/stops).
    func resetFrameRate() {
        lastFrameTime = 0
        frameRate = 0
        lastFrameTimestamp = 0
    }

    // MARK: - STF Auto-Stretch

    /// Compute STF parameters (black point, white point, midtones balance) from raw image data.
    ///
    /// Algorithm:
    ///   - Black point c0: median − 2.8σ (MAD-based, robust background estimate)
    ///   - White point c1: 99.9th percentile (clips hot pixels, preserves stars)
    ///   - Midtones balance m: solves MTF(m, x) = targetBackground where
    ///       x = (median − c0) / (c1 − c0)  (background position in actual data range)
    ///       MTF(m, x) = (m−1)·x / ((2m−1)·x − m)  maps 0→0, m→0.5, 1→1
    ///   - Closed-form inverse: m = x·(1−t) / (x·(1−2t) + t)
    ///
    /// Called from the capture thread — must be nonisolated.
    private nonisolated static func computeSTFParamsSync(
        data: Data, width: Int, height: Int, bytesPerPixel: Int,
        targetBackground: Float = 0.15
    ) -> (black: Float, white: Float, mid: Float) {
        let shadowsClipping: Float = -2.8

        // Sample luminance values (subsample for speed — every 4th pixel)
        let pixelCount = width * height
        let step = 4
        let sampleCount = pixelCount / step
        guard sampleCount > 100 else {
            return (0.0, 1.0, 0.5)
        }

        var samples = [Float]()
        samples.reserveCapacity(sampleCount)

        data.withUnsafeBytes { rawBuffer in
            if bytesPerPixel == 2 {
                let raw16 = rawBuffer.bindMemory(to: UInt16.self)
                for i in stride(from: 0, to: min(pixelCount, raw16.count), by: step) {
                    samples.append(Float(raw16[i]) / 65535.0)
                }
            } else {
                let raw8 = rawBuffer.bindMemory(to: UInt8.self)
                for i in stride(from: 0, to: min(pixelCount, raw8.count), by: step) {
                    samples.append(Float(raw8[i]) / 255.0)
                }
            }
        }

        guard !samples.isEmpty else { return (0.0, 1.0, 0.5) }

        samples.sort()
        let n = samples.count
        let median = (n % 2 == 0) ? (samples[n/2 - 1] + samples[n/2]) / 2.0 : samples[n/2]

        // MAD → sigma-equivalent (Gaussian consistency factor 1.4826)
        var deviations = samples.map { abs($0 - median) }
        deviations.sort()
        let rawMAD = (n % 2 == 0) ? (deviations[n/2 - 1] + deviations[n/2]) / 2.0 : deviations[n/2]
        let mad = rawMAD * 1.4826

        // Black point: 2.8σ below median (clips dark background noise floor)
        let c0 = max(median + shadowsClipping * mad, 0.0)

        // White point: 99.9th percentile — retains stars, clips hot pixels
        let c1 = samples[min(Int(Float(n) * 0.999), n - 1)]

        // Require a meaningful data range
        guard c1 > c0 + 1e-4 else { return (c0, c0 + 0.01, 0.5) }

        // Background position within actual data range [c0, c1]
        let x = (median - c0) / (c1 - c0)

        // Midtones balance m such that MTF(m, x) = targetBackground.
        // Closed-form solution of (m−1)·x / ((2m−1)·x − m) = t:
        //   m = x·(1−t) / (x·(1−2t) + t)
        let t = targetBackground
        let midtones = x * (1.0 - t) / (x * (1.0 - 2.0 * t) + t)

        return (
            black: c0,
            white: c1,
            mid: max(0.001, min(0.999, midtones))
        )
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
