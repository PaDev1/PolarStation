import Foundation
import Metal

/// Manages camera lifecycle: discovery, connection, capture, and frame forwarding to Metal preview.
@MainActor
final class CameraViewModel: ObservableObject {

    // MARK: - Published state

    @Published var discoveredCameras: [ASICameraInfo] = []
    @Published var selectedCameraIndex: Int = -1
    @Published var isConnected = false
    @Published var isCapturing = false
    @Published var captureWidth: Int = 0
    @Published var captureHeight: Int = 0
    @Published var statusMessage = "Select a camera and connect"
    @Published var errorMessage: String?

    // Capture sequence
    @Published var isSaving = false
    @Published var capturedCount: Int = 0
    @Published var targetCount: Int = 0

    // Star detection
    @Published var detectedStars: [DetectedStar] = []
    @Published var starDetectionEnabled = true
    @Published var starDetectorModelLoaded = false
    @Published var starDetectorStatus = "Model not loaded"

    // Sensor cooling
    @Published var sensorTempC: Double?
    @Published var coolerPowerPercent: Int?
    @Published var coolerEnabled = false
    /// Target cooler temperature in Celsius. nil = cooler off.
    @Published var coolerTargetC: Int? = nil

    let previewViewModel = CameraPreviewViewModel()

    // MARK: - Internal

    private var cameraBridge: ASICameraBridge?
    private var frameGrabber: FrameGrabber?
    private let frameForwarder = FrameForwarder()
    private let starDetector = CoreMLDetector()
    private var detectionFrameSkip: UInt64 = 0
    private var tempPollTimer: Timer?

    var selectedCamera: ASICameraInfo? {
        guard selectedCameraIndex >= 0, selectedCameraIndex < discoveredCameras.count else { return nil }
        return discoveredCameras[selectedCameraIndex]
    }

    init() {
        frameForwarder.previewViewModel = previewViewModel
        loadStarDetectorModel()

        // Run star detection every few frames (not every frame to save CPU)
        previewViewModel.onFrameProcessed = { [weak self] in
            guard let self else { return }
            self.detectionFrameSkip += 1
            // Detect every 5th frame (~2-6 Hz depending on camera FPS)
            if self.detectionFrameSkip % 5 == 0 {
                self.runStarDetection()
            }
        }
    }

    /// Load the Core ML star detection model from the app bundle.
    func loadStarDetectorModel() {
        do {
            try starDetector.loadModel(named: "StarDetector")
            starDetectorModelLoaded = true
            starDetectorStatus = "Model loaded (CoreML UNet)"
            print("[StarDetector] Core ML model loaded successfully")
        } catch {
            starDetectorModelLoaded = false
            starDetectorStatus = "Model failed: \(error.localizedDescription)"
            print("[StarDetector] Failed to load model: \(error)")
        }
    }

    /// Run star detection on the current display texture.
    func runStarDetection() {
        guard starDetectionEnabled,
              let texture = previewViewModel.displayTexture,
              let device = previewViewModel.device,
              let commandQueue = previewViewModel.commandQueue else { return }

        do {
            let stars = try starDetector.detectStars(in: texture, device: device, commandQueue: commandQueue)
            detectedStars = stars
        } catch {
            print("[StarDetector] Detection error: \(error)")
        }
    }

    // MARK: - Cooling

    var hasCooler: Bool {
        selectedCamera?.hasCooler == true
    }

    func setCoolerOn(targetCelsius: Int) {
        guard let bridge = cameraBridge, isConnected, hasCooler else { return }
        coolerTargetC = targetCelsius
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try bridge.setCoolerTarget(celsius: targetCelsius)
                Task { @MainActor [weak self] in
                    self?.coolerEnabled = true
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.errorMessage = "Cooler error: \(error.localizedDescription)"
                }
            }
        }
    }

    func setCoolerOff() {
        guard let bridge = cameraBridge, isConnected else { return }
        coolerTargetC = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try bridge.setControlValue(kASI_COOLER_ON, value: 0)
                Task { @MainActor [weak self] in
                    self?.coolerEnabled = false
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.errorMessage = "Cooler error: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Gradually warm up the sensor by raising the target temperature in steps.
    func warmup() {
        guard let bridge = cameraBridge, isConnected, hasCooler, coolerEnabled else { return }
        // Set target to +20°C (ambient) — the cooler will gradually warm
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try bridge.setControlValue(kASI_TARGET_TEMP, value: 20)
                Task { @MainActor [weak self] in
                    self?.coolerTargetC = 20
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.errorMessage = "Warmup error: \(error.localizedDescription)"
                }
            }
        }
    }

    func startTemperaturePolling() {
        stopTemperaturePolling()
        pollTemperature()
        tempPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollTemperature()
            }
        }
    }

    func stopTemperaturePolling() {
        tempPollTimer?.invalidate()
        tempPollTimer = nil
    }

    private func pollTemperature() {
        guard let bridge = cameraBridge, isConnected, hasCooler else { return }
        DispatchQueue.global(qos: .utility).async {
            let temp = try? bridge.getTemperature()
            let power = try? bridge.getControlValue(kASI_COOLER_POWER_PERC).value
            let coolerOn = try? bridge.getControlValue(kASI_COOLER_ON).value
            Task { @MainActor [weak self] in
                self?.sensorTempC = temp
                self?.coolerPowerPercent = power
                self?.coolerEnabled = (coolerOn ?? 0) != 0
            }
        }
    }

    // MARK: - Discovery

    func discoverCameras() {
        DispatchQueue.global(qos: .userInitiated).async {
            let cameras = (try? ASICameraBridge.listCameras()) ?? []
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.discoveredCameras = cameras
                if self.selectedCameraIndex < 0, !cameras.isEmpty {
                    self.selectedCameraIndex = 0
                }
            }
        }
    }

    // MARK: - Connection

    func connect() {
        guard let cam = selectedCamera else {
            errorMessage = "No camera selected"
            return
        }
        guard !isConnected else { return }

        errorMessage = nil
        statusMessage = "Connecting to \(cam.name)..."

        let cameraID = cam.cameraID
        let name = cam.name
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let bridge = ASICameraBridge(cameraID: cameraID)
                try bridge.open()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.cameraBridge = bridge
                    self.isConnected = true
                    self.statusMessage = "Connected to \(name)"
                    if self.hasCooler {
                        self.startTemperaturePolling()
                    }
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.errorMessage = error.localizedDescription
                    self?.statusMessage = "Connection failed"
                }
            }
        }
    }

    func disconnect() {
        stopCapture()
        stopTemperaturePolling()
        if let bridge = cameraBridge {
            DispatchQueue.global(qos: .userInitiated).async {
                try? bridge.close()
            }
        }
        cameraBridge = nil
        isConnected = false
        coolerEnabled = false
        sensorTempC = nil
        coolerPowerPercent = nil
        coolerTargetC = nil
        previewViewModel.displayTexture = nil
        statusMessage = "Disconnected"
    }

    /// Connect if needed, then call completion on main actor.
    private func ensureConnected(then completion: @escaping @MainActor () -> Void) {
        if isConnected {
            completion()
            return
        }
        guard let cam = selectedCamera else {
            errorMessage = "No camera selected"
            return
        }
        errorMessage = nil
        statusMessage = "Connecting..."

        let cameraID = cam.cameraID
        let name = cam.name
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let bridge = ASICameraBridge(cameraID: cameraID)
                try bridge.open()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.cameraBridge = bridge
                    self.isConnected = true
                    self.statusMessage = "Connected to \(name)"
                    if self.hasCooler {
                        self.startTemperaturePolling()
                    }
                    completion()
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.errorMessage = error.localizedDescription
                    self?.statusMessage = "Connection failed"
                }
            }
        }
    }

    // MARK: - Live Preview (no saving)

    func startLive(settings: CameraSettings) {
        ensureConnected { [weak self] in
            self?.frameForwarder.onSaveFrame = nil
            self?.frameForwarder.onFrameReceived = nil
            self?.startCaptureInternal(settings: settings)
        }
    }

    // MARK: - Capture Sequence (with saving)

    func startCaptureSequence(
        count: Int,
        settings: CameraSettings,
        format: CaptureFormat,
        colorMode: CaptureColorMode = .rgb,
        folder: URL,
        prefix: String
    ) {
        ensureConnected { [weak self] in
            guard let self else { return }
            self.beginCaptureSequence(
                count: count, settings: settings,
                format: format, colorMode: colorMode, folder: folder, prefix: prefix
            )
        }
    }

    private func beginCaptureSequence(
        count: Int,
        settings: CameraSettings,
        format: CaptureFormat,
        colorMode: CaptureColorMode,
        folder: URL,
        prefix: String
    ) {
        guard let cam = selectedCamera else { return }
        if isCapturing { stopCapture() }

        capturedCount = 0
        targetCount = count
        isSaving = true
        errorMessage = nil

        // Gather metadata
        let bayerStr = bayerPatternString(cam.bayerPattern)
        let lat = UserDefaults.standard.double(forKey: "observerLat")
        let lon = UserDefaults.standard.double(forKey: "observerLon")
        let timestamp = FrameSaver.captureTimestamp()

        // Ensure folder exists
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Sequence counter (capture thread only)
        var seqNum = 0

        frameForwarder.onSaveFrame = { [weak self] data, w, h, bpp, _ in
            seqNum += 1
            let num = seqNum

            DispatchQueue.global(qos: .utility).async {
                let metadata = CaptureMetadata(
                    cameraName: cam.name,
                    exposureMs: settings.exposureMs,
                    gain: settings.gain,
                    binning: settings.binning,
                    pixelSizeMicrons: cam.pixelSize,
                    bayerPattern: bayerStr,
                    isColorCamera: cam.isColorCamera,
                    width: w,
                    height: h,
                    bytesPerPixel: bpp,
                    observerLat: lat != 0 ? lat : nil,
                    observerLon: lon != 0 ? lon : nil
                )

                let filename = String(format: "%@_%@_%03d.%@", prefix, timestamp, num, format.fileExtension)
                let fileURL = folder.appendingPathComponent(filename)

                do {
                    try FrameSaver.save(data: data, metadata: metadata, format: format,
                                        colorMode: colorMode, to: fileURL)
                } catch {
                    Task { @MainActor [weak self] in
                        self?.errorMessage = "Save error: \(error.localizedDescription)"
                    }
                }

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.capturedCount = num
                    self.statusMessage = "Captured \(num)/\(self.targetCount)"
                    if num >= self.targetCount {
                        self.finishCaptureSequence()
                    }
                }
            }
        }

        frameForwarder.onFrameReceived = nil
        startCaptureInternal(settings: settings)
        statusMessage = "Capturing 0/\(count)..."
    }

    private func finishCaptureSequence() {
        stopCapture()
        isSaving = false
        frameForwarder.onSaveFrame = nil
        statusMessage = "Capture complete (\(capturedCount) frames saved)"
    }

    // MARK: - Core Capture

    func stopCapture() {
        guard isCapturing else { return }
        frameGrabber?.stop()
        frameGrabber = nil
        isCapturing = false
        frameForwarder.onSaveFrame = nil
        frameForwarder.onFrameReceived = nil
        if isSaving {
            isSaving = false
        }
        if isConnected && !isSaving {
            statusMessage = "Connected (idle)"
        }
    }

    private func startCaptureInternal(settings: CameraSettings) {
        guard let bridge = cameraBridge, isConnected else {
            errorMessage = "Camera not connected"
            return
        }
        guard !isCapturing else { return }

        errorMessage = nil

        let grabber = FrameGrabber(camera: bridge, settings: settings)
        grabber.delegate = frameForwarder
        self.frameGrabber = grabber

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try grabber.start()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isCapturing = true
                    self.captureWidth = grabber.captureWidth
                    self.captureHeight = grabber.captureHeight
                    if !self.isSaving {
                        self.statusMessage = "Live \(grabber.captureWidth)x\(grabber.captureHeight)"
                    }
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.errorMessage = error.localizedDescription
                    self?.statusMessage = "Capture failed"
                    self?.isSaving = false
                }
            }
        }
    }

    // MARK: - Helpers

    private func bayerPatternString(_ pattern: ASIBayerPattern) -> String {
        switch pattern {
        case .rg: return "RGGB"
        case .bg: return "BGGR"
        case .gr: return "GRBG"
        case .gb: return "GBRG"
        }
    }
}

// MARK: - Frame forwarding bridge (not MainActor — called from capture thread)

private class FrameForwarder: FrameGrabberDelegate {
    weak var previewViewModel: CameraPreviewViewModel?
    var onFrameReceived: (@Sendable (UInt64) -> Void)?
    var onSaveFrame: ((Data, Int, Int, Int, UInt64) -> Void)?

    func frameGrabber(_ grabber: FrameGrabber, didCapture buffer: UnsafeBufferPointer<UInt8>,
                      width: Int, height: Int, bytesPerPixel: Int, frameNumber: UInt64) {
        // Forward to Metal preview
        previewViewModel?.processFrame(buffer: buffer, width: width, height: height, bytesPerPixel: bytesPerPixel)

        // Save frame if handler is set (copies the buffer)
        if let onSave = onSaveFrame {
            let dataCopy = Data(bytes: buffer.baseAddress!, count: buffer.count)
            onSave(dataCopy, width, height, bytesPerPixel, frameNumber)
        }

        // Notify for other handling
        onFrameReceived?(frameNumber)
    }
}
