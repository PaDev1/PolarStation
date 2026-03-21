import Foundation

/// Delegate protocol for receiving captured frames.
protocol FrameGrabberDelegate: AnyObject {
    /// Called on the capture thread when a new frame is available.
    /// `buffer` contains raw pixel data; `width`/`height` are post-binning dimensions.
    /// `grabber` is nil when called from AlpacaFrameGrabber.
    func frameGrabber(_ grabber: FrameGrabber?, didCapture buffer: UnsafeBufferPointer<UInt8>,
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

    /// Configure the camera and start the snap-mode capture loop.
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

        // Start capture thread (snap mode — no video capture)
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

    /// Stop the capture loop.
    func stop() {
        isRunning = false
        captureThread?.cancel()
        captureThread = nil

        // Stop any in-progress exposure
        try? camera.stopExposure()
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
            // Start exposure
            do {
                try camera.startExposure()
            } catch {
                droppedFrames += 1
                Thread.sleep(forTimeInterval: 0.1)
                continue
            }

            // Poll for exposure completion
            var completed = false
            let timeoutMs = settings.captureTimeoutMs
            let startTime = CFAbsoluteTimeGetCurrent()

            while isRunning && !Thread.current.isCancelled {
                let status = camera.getExposureStatus()
                if status == 1 { // ASI_EXP_SUCCESS
                    completed = true
                    break
                }
                if status == 2 { // ASI_EXP_FAILED
                    break
                }
                // Check timeout
                let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                if elapsed > Double(timeoutMs) { break }

                // Poll interval: short for fast exposures, longer for slow
                Thread.sleep(forTimeInterval: settings.exposureMs > 500 ? 0.1 : 0.01)
            }

            guard completed else {
                droppedFrames += 1
                continue
            }

            // Download the frame
            let success = camera.getDataAfterExp(buffer: buffer, bufferSize: bufferSize)
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
