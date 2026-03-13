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

        // Configure binning and gain
        try camera.configure(bin: settings.binning, gain: settings.gain)

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
        print("[AlpacaFrameGrabber] Starting capture loop: \(captureWidth)x\(captureHeight), exposure=\(exposureSecs)s")

        while isRunning && !Thread.current.isCancelled {
            do {
                // Start exposure
                print("[AlpacaFrameGrabber] Starting exposure \(exposureSecs)s...")
                try camera.startExposure(durationSecs: exposureSecs)
                print("[AlpacaFrameGrabber] Exposure started, polling for ready...")

                // Poll until image is ready (every 50ms)
                var ready = false
                let pollStart = Date()
                let timeout = exposureSecs + 10.0 // generous timeout
                while isRunning && !Thread.current.isCancelled {
                    if let r = try? camera.isImageReady(), r {
                        ready = true
                        break
                    }
                    if Date().timeIntervalSince(pollStart) > timeout {
                        print("[AlpacaFrameGrabber] Timeout waiting for image ready")
                        onError?("Timeout waiting for exposure")
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.05)
                }

                guard isRunning && ready else { continue }

                // Download image
                let dlStart = Date()
                let data = try camera.downloadImage()
                let dlTime = Date().timeIntervalSince(dlStart)
                frameCount += 1
                print("[AlpacaFrameGrabber] Frame \(frameCount): \(data.count) bytes, download \(String(format: "%.2f", dlTime))s")

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
                    print("[AlpacaFrameGrabber] Error: \(error)")
                    onError?(error.localizedDescription)
                    Thread.sleep(forTimeInterval: 0.5)
                }
            }
        }
        print("[AlpacaFrameGrabber] Capture loop ended")
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
