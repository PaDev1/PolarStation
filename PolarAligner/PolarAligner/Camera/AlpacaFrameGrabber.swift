import Foundation

/// Capture loop for ASCOM Alpaca cameras.
/// Exposure-based: start → poll ready → download → repeat.
/// Delivers frames through the same FrameGrabberDelegate protocol as FrameGrabber.
final class AlpacaFrameGrabber {
    let camera: AlpacaCameraBridge
    var settings: CameraSettings

    weak var delegate: FrameGrabberDelegate?

    /// Called on error (from capture thread). Used to surface errors to UI.
    var onError: ((String) -> Void)?

    /// Called for diagnostic log messages (from capture thread).
    var onLog: ((String) -> Void)?

    /// Called when each new exposure begins. Arg is duration in seconds.
    var onExposureStarted: ((Double) -> Void)?

    /// Stop after this many frames (0 = run indefinitely). Set before start().
    var maxFrames: Int = 0

    private var captureThread: Thread?
    private var isRunning = false
    private(set) var frameCount: UInt64 = 0

    /// Post-binning dimensions.
    private(set) var captureWidth: Int = 0
    private(set) var captureHeight: Int = 0

    init(camera: AlpacaCameraBridge, settings: CameraSettings) {
        self.camera = camera
        self.settings = settings
    }

    deinit {
        stop()
    }

    /// Configure the camera and start the capture loop.
    func start() throws {
        guard let info = camera.info else {
            throw AlpacaCameraError.notConnected
        }
        guard !isRunning else { return }

        // Abort any lingering exposure before configuring — clears stuck Exposing/Download
        // state left over from a previous session or an aborted live view.
        try? camera.abortExposure()

        // Configure binning and gain.
        // Retry up to 12 times (6s total): ASCOM drivers can reject configure commands
        // for several seconds after abortExposure while transitioning back to Idle state.
        var configError: Error?
        for attempt in 1...12 {
            do {
                try camera.configure(bin: settings.binning, gain: settings.gain)
                onLog?("configure OK (attempt \(attempt))")
                configError = nil
                break
            } catch {
                configError = error
                onLog?("configure attempt \(attempt) failed: \(error.localizedDescription) — retrying in 500ms")
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        if let err = configError { throw err }

        // Compute post-binning dimensions
        captureWidth = Int(info.width) / settings.binning
        captureHeight = Int(info.height) / settings.binning

        // Ensure width is multiple of 8, height multiple of 2 (same as FrameGrabber)
        captureWidth = (captureWidth / 8) * 8
        captureHeight = (captureHeight / 2) * 2

        isRunning = true
        frameCount = 0
        let thread = Thread { [weak self] in
            self?.captureLoop()
        }
        thread.name = "com.polaraligner.alpaca-frame-grabber"
        thread.qualityOfService = .userInteractive
        captureThread = thread
        thread.start()
    }

    /// Stop the capture loop.
    func stop() {
        isRunning = false
        captureThread?.cancel()
        captureThread = nil
        // Try to abort any in-progress exposure
        try? camera.abortExposure()
    }

    private func captureLoop() {
        let exposureSecs = settings.exposureMs / 1000.0
        let mode = maxFrames > 0 ? "capture(\(maxFrames))" : "live"
        let msg = "Loop start: \(mode) \(captureWidth)x\(captureHeight) exp=\(String(format:"%.3f",exposureSecs))s"
        onLog?(msg)
        print("[AlpacaFrameGrabber] \(msg)")

        while isRunning && !Thread.current.isCancelled {
            // Check maxFrames before starting the next exposure
            if maxFrames > 0 && frameCount >= UInt64(maxFrames) {
                let done = "maxFrames \(maxFrames) reached, stopping"
                onLog?(done); print("[AlpacaFrameGrabber] \(done)")
                break
            }

            do {
                // Start exposure
                let exposureStart = Date()
                let startMsg = "startExposure \(String(format:"%.3f",exposureSecs))s (frame \(frameCount+1))"
                onLog?(startMsg); print("[AlpacaFrameGrabber] \(startMsg)")
                onExposureStarted?(exposureSecs)
                try camera.startExposure(durationSecs: exposureSecs)
                onLog?("startExposure returned OK")

                // Wait most of the exposure duration before polling.
                // Some Alpaca/INDIGO servers don't clear isImageReady immediately
                // after startExposure — polling too early picks up stale state from
                // the previous frame and downloads a premature image.
                let prePollWait = max(0.0, exposureSecs - 2.0)
                if prePollWait > 0 {
                    onLog?("pre-poll sleep \(String(format:"%.1f",prePollWait))s")
                    var waited = 0.0
                    while isRunning && !Thread.current.isCancelled && waited < prePollWait {
                        let chunk = min(0.5, prePollWait - waited)
                        Thread.sleep(forTimeInterval: chunk)
                        waited = Date().timeIntervalSince(exposureStart)
                    }
                    guard isRunning && !Thread.current.isCancelled else {
                        onLog?("stopped during pre-poll sleep"); continue
                    }
                }

                // Poll isImageReady (every 50ms) until ready or timeout.
                // Also require that at least 90% of the exposure time has elapsed
                // to reject any stale "ready" that slipped through the pre-poll wait.
                var ready = false
                // DSLRs via ASCOM can take 10-20s to download a RAW after exposure completes.
                let timeout = exposureSecs + 30.0
                while isRunning && !Thread.current.isCancelled {
                    let elapsed = Date().timeIntervalSince(exposureStart)
                    if let r = try? camera.isImageReady(), r,
                       elapsed >= exposureSecs * 0.9 {
                        let readyMsg = "imageReady=true at \(String(format:"%.2f",elapsed))s (90% guard=\(String(format:"%.2f",exposureSecs*0.9))s)"
                        onLog?(readyMsg); print("[AlpacaFrameGrabber] \(readyMsg)")
                        ready = true
                        break
                    }
                    if elapsed > timeout {
                        let toMsg = "TIMEOUT after \(String(format:"%.1f",elapsed))s"
                        onLog?(toMsg); print("[AlpacaFrameGrabber] \(toMsg)")
                        onError?("Timeout waiting for exposure")
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.05)
                }

                guard isRunning && ready else {
                    if !isRunning { onLog?("stopped during poll") }
                    continue
                }

                // Download image
                let dlStart = Date()
                onLog?("downloadImage...")
                let data = try camera.downloadImage()
                let dlTime = Date().timeIntervalSince(dlStart)
                let elapsed = Date().timeIntervalSince(exposureStart)
                frameCount += 1
                let dlMsg = "frame \(frameCount): \(data.count) bytes, dl=\(String(format:"%.2f",dlTime))s total=\(String(format:"%.2f",elapsed))s"
                onLog?(dlMsg); print("[AlpacaFrameGrabber] \(dlMsg)")

                // Deliver frame through delegate
                let bytesPerPixel = settings.bytesPerPixel
                let w = captureWidth
                let h = captureHeight

                data.withUnsafeBytes { rawBuffer in
                    guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                    let ubp = UnsafeBufferPointer(start: baseAddress, count: data.count)
                    delegate?.frameGrabber(
                        nil,
                        didCapture: ubp,
                        width: w,
                        height: h,
                        bytesPerPixel: bytesPerPixel,
                        frameNumber: frameCount
                    )
                }
            } catch {
                if isRunning {
                    let errMsg = "ERROR: \(error.localizedDescription)"
                    onLog?(errMsg); print("[AlpacaFrameGrabber] \(errMsg)")
                    onError?(error.localizedDescription)
                    Thread.sleep(forTimeInterval: 0.5)
                } else {
                    onLog?("error after stop (ignored): \(error.localizedDescription)")
                }
            }
        }
        let endMsg = "Loop ended (frameCount=\(frameCount))"
        onLog?(endMsg); print("[AlpacaFrameGrabber] \(endMsg)")
    }
}

enum AlpacaCameraError: Error, LocalizedError {
    case notConnected

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Alpaca camera not connected"
        }
    }
}
