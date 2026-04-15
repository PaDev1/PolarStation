import Foundation
import AppKit
import CoreGraphics
import ImageIO

/// Frame grabber for Canon EDSDK live view (EVF).
/// Polls `EdsDownloadEvfImage` on a background thread, decodes the JPEG to BGRA,
/// and delivers frames through `FrameGrabberDelegate`.
final class CanonFrameGrabber {
    let camera: CanonCameraBridge

    /// Direct preview output. Canon JPEG frames are decoded to BGRA and uploaded
    /// straight to the display texture, bypassing Bayer debayering.
    weak var previewViewModel: CameraPreviewViewModel?

    /// Optional callback for each decoded frame as packed RGB888. Used to write
    /// EVF frames into a SER video file when the user is recording.
    var onRGBFrame: ((UnsafeBufferPointer<UInt8>, Int, Int) -> Void)?

    /// Reusable RGB buffer (BGRA → RGB conversion).
    private var rgbBuffer: UnsafeMutablePointer<UInt8>?
    private var rgbCapacity: Int = 0

    /// Called for diagnostic log messages (from capture thread).
    var onLog: ((String) -> Void)?

    /// Called on error.
    var onError: ((String) -> Void)?

    private var captureThread: Thread?
    private var isRunning = false
    private(set) var frameCount: UInt64 = 0

    /// Post-decode dimensions (set after first successful frame).
    private(set) var captureWidth: Int = 0
    private(set) var captureHeight: Int = 0

    /// Decoded BGRA buffer, reused across frames.
    private var rgbaBuffer: UnsafeMutablePointer<UInt8>?
    private var rgbaCapacity: Int = 0

    /// Poll interval between EVF frame requests. Canon EVF runs ~30fps max; ~33ms is fine.
    var pollIntervalMs: Int = 33

    init(camera: CanonCameraBridge) {
        self.camera = camera
    }

    deinit {
        stop()
        rgbaBuffer?.deallocate()
        rgbBuffer?.deallocate()
    }

    func start() throws {
        guard !isRunning else { return }

        // Enable live view on the camera
        try CanonCameraBridge.sdkQueue.sync {
            try camera.startLiveView()
        }

        isRunning = true
        frameCount = 0
        let thread = Thread { [weak self] in
            self?.captureLoop()
        }
        thread.name = "com.polaraligner.canon-frame-grabber"
        thread.qualityOfService = .userInteractive
        captureThread = thread
        thread.start()
    }

    func stop() {
        isRunning = false
        captureThread?.cancel()
        captureThread = nil

        CanonCameraBridge.sdkQueue.sync {
            try? camera.stopLiveView()
        }
    }

    // MARK: - Private

    private func captureLoop() {
        onLog?("Canon EVF loop start")

        while isRunning && !Thread.current.isCancelled {
            // Fetch JPEG frame from camera (runs on SDK queue)
            var jpegData: Data?
            CanonCameraBridge.sdkQueue.sync {
                jpegData = camera.downloadEvfJPEG()
            }

            if let jpeg = jpegData {
                processFrame(jpeg: jpeg)
            }

            Thread.sleep(forTimeInterval: Double(pollIntervalMs) / 1000.0)
        }

        onLog?("Canon EVF loop end (frames=\(frameCount))")
    }

    private func processFrame(jpeg: Data) {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            onLog?("JPEG decode failed")
            return
        }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4
        let size = bytesPerRow * height

        // (Re)allocate buffer if size changed
        if size != rgbaCapacity {
            rgbaBuffer?.deallocate()
            rgbaBuffer = .allocate(capacity: size)
            rgbaCapacity = size
        }
        guard let buffer = rgbaBuffer else { return }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue |
                                      CGBitmapInfo.byteOrder32Little.rawValue)
        guard let ctx = CGContext(data: buffer, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: colorSpace, bitmapInfo: bitmapInfo.rawValue) else {
            return
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        captureWidth = width
        captureHeight = height
        frameCount += 1

        let ubp = UnsafeBufferPointer(start: UnsafePointer(buffer), count: size)
        previewViewModel?.processBGRAFrame(buffer: ubp, width: width, height: height)

        // If recording, convert BGRA → packed RGB and emit to the SER writer
        if let onRGB = onRGBFrame {
            let rgbSize = width * height * 3
            if rgbSize != rgbCapacity {
                rgbBuffer?.deallocate()
                rgbBuffer = .allocate(capacity: rgbSize)
                rgbCapacity = rgbSize
            }
            guard let dst = rgbBuffer else { return }
            // BGRA byteOrder32Little = bytes in memory: B, G, R, A
            // SER RGB ColorID = R, G, B
            for i in 0..<(width * height) {
                let bgraOff = i * 4
                let rgbOff = i * 3
                dst[rgbOff]     = buffer[bgraOff + 2] // R
                dst[rgbOff + 1] = buffer[bgraOff + 1] // G
                dst[rgbOff + 2] = buffer[bgraOff]     // B
            }
            let rgbBuf = UnsafeBufferPointer(start: UnsafePointer(dst), count: rgbSize)
            onRGB(rgbBuf, width, height)
        }
    }
}
