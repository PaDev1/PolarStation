import Foundation

/// Delegate protocol for receiving captured frames.
protocol FrameGrabberDelegate: AnyObject {
    /// Called on the capture thread when a new frame is available.
    /// `buffer` contains raw pixel data; `width`/`height` are post-binning dimensions.
    func frameGrabber(_ grabber: FrameGrabber, didCapture buffer: UnsafeBufferPointer<UInt8>,
                      width: Int, height: Int, bytesPerPixel: Int, frameNumber: UInt64)
}

/// Runs a background thread that continuously grabs frames from the ASI camera.
///
/// Usage:
/// ```
/// let grabber = FrameGrabber(camera: bridge, settings: settings)
/// grabber.delegate = self
/// try grabber.start()
/// // ... later ...
/// grabber.stop()
/// ```
final class FrameGrabber {
    let camera: ASICameraBridge
    var settings: CameraSettings

    weak var delegate: FrameGrabberDelegate?

    private var captureThread: Thread?
    private var isRunning = false
    private var frameBuffer: UnsafeMutablePointer<UInt8>?
    private var bufferSize: Int = 0
    private(set) var frameCount: UInt64 = 0
    private(set) var droppedFrames: Int = 0

    /// Post-binning dimensions.
    private(set) var captureWidth: Int = 0
    private(set) var captureHeight: Int = 0

    init(camera: ASICameraBridge, settings: CameraSettings) {
        self.camera = camera
        self.settings = settings
    }

    deinit {
        stop()
        deallocateBuffer()
    }

    /// Configure the camera and start the capture loop.
    func start() throws {
        guard let info = camera.info else {
            throw ASICameraError.cameraClosed
        }
        guard !isRunning else { return }

        // Compute post-binning dimensions
        captureWidth = info.maxWidth / settings.binning
        captureHeight = info.maxHeight / settings.binning

        // Ensure width is multiple of 8, height multiple of 2
        captureWidth = (captureWidth / 8) * 8
        captureHeight = (captureHeight / 2) * 2

        // Configure camera
        try camera.setROIFormat(
            width: captureWidth,
            height: captureHeight,
            bin: settings.binning,
            imageType: settings.imageFormat
        )
        try camera.setExposure(microseconds: settings.exposureMicroseconds)
        try camera.setGain(settings.gain)

        // Enable cooler if requested
        if let target = settings.coolerTargetC {
            try camera.setCoolerTarget(celsius: target)
        }

        // Allocate frame buffer
        allocateBuffer()

        // Start video mode
        try camera.startVideoCapture()

        // Start capture thread
        isRunning = true
        frameCount = 0
        let thread = Thread { [weak self] in
            self?.captureLoop()
        }
        thread.name = "com.polaraligner.frame-grabber"
        thread.qualityOfService = .userInteractive
        captureThread = thread
        thread.start()
    }

    /// Stop the capture loop and video mode.
    func stop() {
        isRunning = false
        captureThread?.cancel()
        captureThread = nil

        if camera.isCapturing {
            try? camera.stopVideoCapture()
        }
    }

    /// Update settings while capturing. Stops and restarts the capture.
    func updateSettings(_ newSettings: CameraSettings) throws {
        let wasRunning = isRunning
        if wasRunning { stop() }
        settings = newSettings
        if wasRunning { try start() }
    }

    // MARK: - Private

    private func allocateBuffer() {
        deallocateBuffer()
        bufferSize = settings.bufferSize(width: captureWidth, height: captureHeight)
        frameBuffer = .allocate(capacity: bufferSize)
    }

    private func deallocateBuffer() {
        frameBuffer?.deallocate()
        frameBuffer = nil
        bufferSize = 0
    }

    private func captureLoop() {
        guard let buffer = frameBuffer else { return }

        while isRunning && !Thread.current.isCancelled {
            let success = camera.getVideoData(
                buffer: buffer,
                bufferSize: bufferSize,
                waitMs: settings.captureTimeoutMs
            )

            if success {
                frameCount += 1
                let ubp = UnsafeBufferPointer(start: UnsafePointer(buffer), count: bufferSize)
                delegate?.frameGrabber(
                    self,
                    didCapture: ubp,
                    width: captureWidth,
                    height: captureHeight,
                    bytesPerPixel: settings.bytesPerPixel,
                    frameNumber: frameCount
                )
            } else {
                droppedFrames += 1
            }
        }
    }
}
