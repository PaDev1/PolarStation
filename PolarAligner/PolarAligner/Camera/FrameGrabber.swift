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

    /// Called when each new exposure begins. Arg is duration in seconds.
    var onExposureStarted: ((Double) -> Void)?

    /// When true, use ASI video mode (continuous streaming) instead of snap mode.
    var videoMode: Bool = false

    private var captureThread: Thread?
    private var isRunning = false
    /// Set true by the capture thread on entry, false on exit. Used by `stop()`
    /// to know when the thread is safe to discard.
    private var threadActive = false
    private let threadActiveLock = NSLock()
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

        // Desired ROI in sensor pixels (pre-binning). nil → full sensor.
        // Clamp to the actual sensor size so undersized cameras degrade
        // gracefully if a preset exceeds their dimensions.
        let roiW = min(settings.roiWidth ?? info.maxWidth, info.maxWidth)
        let roiH = min(settings.roiHeight ?? info.maxHeight, info.maxHeight)

        // Post-binning output dimensions — width multiple of 8, height multiple of 2.
        captureWidth = ((roiW / settings.binning) / 8) * 8
        captureHeight = ((roiH / settings.binning) / 2) * 2

        // Centre the ROI on the sensor (post-bin coordinates). Floor the start
        // position to a multiple of 4×2 for SDK alignment requirements.
        let maxOutW = info.maxWidth / settings.binning
        let maxOutH = info.maxHeight / settings.binning
        var startX = max(0, (maxOutW - captureWidth) / 2)
        var startY = max(0, (maxOutH - captureHeight) / 2)
        startX = (startX / 4) * 4
        startY = (startY / 2) * 2

        // Configure camera. ORDER MATTERS: setStartPos must come after
        // setROIFormat — changing format resets start position to (0, 0).
        try camera.setROIFormat(
            width: captureWidth,
            height: captureHeight,
            bin: settings.binning,
            imageType: settings.imageFormat
        )
        try camera.setStartPos(x: startX, y: startY)
        try camera.setExposure(microseconds: settings.exposureMicroseconds)
        try camera.setGain(settings.gain)

        // Enable cooler if requested
        if let target = settings.coolerTargetC {
            try camera.setCoolerTarget(celsius: target)
        }

        // Allocate frame buffer
        allocateBuffer()

        isRunning = true
        frameCount = 0
        threadActiveLock.lock()
        threadActive = true
        threadActiveLock.unlock()
        let thread = Thread { [weak self] in
            guard let self else { return }
            if self.videoMode {
                self.videoCaptureLoop()
            } else {
                self.captureLoop()
            }
            self.threadActiveLock.lock()
            self.threadActive = false
            self.threadActiveLock.unlock()
        }
        thread.name = "com.polaraligner.frame-grabber"
        thread.qualityOfService = .userInteractive
        captureThread = thread
        thread.start()
    }

    /// Stop the capture loop and wait for the capture thread to fully exit.
    /// Blocking is required so that no SDK call is in flight when the caller
    /// proceeds to start a new grabber on the same camera.
    func stop() {
        isRunning = false
        captureThread?.cancel()

        if videoMode {
            try? camera.stopVideoCapture()
        } else {
            try? camera.stopExposure()
        }

        // Wait for the capture thread to exit (max ~3s — should be near-instant).
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            threadActiveLock.lock()
            let active = threadActive
            threadActiveLock.unlock()
            if !active { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        captureThread = nil
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

    /// Video mode: continuous streaming via ASIStartVideoCapture / ASIGetVideoData.
    /// Higher frame rates than snap mode — used for planetary/lunar video recording.
    private func videoCaptureLoop() {
        guard let buffer = frameBuffer else { return }

        do {
            try camera.startVideoCapture()
        } catch {
            print("[FrameGrabber] startVideoCapture failed: \(error)")
            return
        }

        let waitMs = settings.captureTimeoutMs

        while isRunning && !Thread.current.isCancelled {
            let got = camera.getVideoData(buffer: buffer, bufferSize: bufferSize, waitMs: waitMs)
            if got {
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

        try? camera.stopVideoCapture()
    }

    /// Snap mode: repeated start/poll/download cycle.
    private func captureLoop() {
        guard let buffer = frameBuffer else { return }

        while isRunning && !Thread.current.isCancelled {
            // Start exposure
            do {
                try camera.startExposure()
                onExposureStarted?(settings.exposureMs / 1000.0)
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
