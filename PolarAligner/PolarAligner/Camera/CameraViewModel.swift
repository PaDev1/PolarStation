import Foundation
import CoreGraphics
import ImageIO
import Metal
import PolarCore

/// Camera connection source.
enum CameraSource: String, CaseIterable {
    case usb = "USB"
    case alpaca = "ASCOM Alpaca"
}

/// Manages camera lifecycle: discovery, connection, capture, and frame forwarding to Metal preview.
@MainActor
final class CameraViewModel: ObservableObject {

    // MARK: - Published state

    @Published var cameraSource: CameraSource = .usb
    @Published var discoveredCameras: [ASICameraInfo] = []
    @Published var selectedCameraIndex: Int = -1
    @Published var isConnected = false
    @Published var isCapturing = false
    @Published var captureWidth: Int = 0
    @Published var captureHeight: Int = 0
    @Published var statusMessage = "Select a camera and connect"
    @Published var errorMessage: String?

    // Alpaca connection settings (set from SettingsView / CameraTabView)
    var alpacaHost: String = "192.168.8.30"
    var alpacaPort: UInt32 = 11111
    var alpacaDeviceNumber: UInt32 = 0

    // Alpaca device discovery
    @Published var alpacaDevices: [AlpacaDeviceInfo] = []
    @Published var selectedAlpacaDevice: Int = -1
    @Published var isDiscoveringAlpacaDevices = false

    // Capture sequence
    @Published var isSaving = false
    @Published var capturedCount: Int = 0
    @Published var targetCount: Int = 0

    // Star detection
    @Published var detectedStars: [DetectedStar] = []
    @Published var starDetectionEnabled = true
    @Published var starDetectorModelLoaded = false
    @Published var starDetectorStatus = "Model not loaded"

    /// Debug log lines for the guide tab debug strip.
    @Published var debugLog: String = ""
    private var debugLines: [String] = []
    private let maxDebugLines = 30

    // Sensor cooling
    @Published var sensorTempC: Double?
    @Published var coolerPowerPercent: Int?
    @Published var coolerEnabled = false
    /// Target cooler temperature in Celsius. nil = cooler off.
    @Published var coolerTargetC: Int? = nil

    let previewViewModel = CameraPreviewViewModel()

    // MARK: - Internal

    private var cameraBridge: ASICameraBridge?
    private var alpacaCameraBridge: AlpacaCameraBridge?
    private var frameGrabber: FrameGrabber?
    private var alpacaFrameGrabber: AlpacaFrameGrabber?
    private let frameForwarder = FrameForwarder()
    private let starDetector = CoreMLDetector()
    /// When true, bypass CoreML and use ClassicalDetector directly.
    @Published var forceClassicalDetector = true
    private let classicalDetector = ClassicalDetector()
    private var tempPollTimer: Timer?

    var selectedCamera: ASICameraInfo? {
        guard selectedCameraIndex >= 0, selectedCameraIndex < discoveredCameras.count else { return nil }
        return discoveredCameras[selectedCameraIndex]
    }

    init() {
        frameForwarder.previewViewModel = previewViewModel
        loadStarDetectorModel()

        // Run star detection on every frame.
        previewViewModel.onFrameProcessed = { [weak self] in
            guard let self else { return }
            self.runStarDetection()
        }
    }

    /// Load the Core ML star detection model from the app bundle.
    func loadStarDetectorModel() {
        do {
            try starDetector.loadModel(named: "StarDetector")
            starDetectorModelLoaded = true
            starDetectorStatus = "CoreML UNet loaded"
            appendDebug("[Model] CoreML StarDetector loaded OK")
        } catch {
            starDetectorModelLoaded = false
            starDetectorStatus = "Fallback: Classical (\(error.localizedDescription))"
            appendDebug("[Model] CoreML failed: \(error.localizedDescription) → using ClassicalDetector")
        }
    }

    /// Run star detection on the current display texture.
    func runStarDetection() {
        if !starDetectionEnabled {
            appendDebug("[Det] skip: detection disabled")
            return
        }
        guard let texture = previewViewModel.displayTexture else {
            appendDebug("[Det] skip: no displayTexture")
            return
        }
        guard let device = previewViewModel.device else {
            appendDebug("[Det] skip: no Metal device")
            return
        }
        guard let commandQueue = previewViewModel.commandQueue else {
            appendDebug("[Det] skip: no commandQueue")
            return
        }

        runStarDetection(on: texture, device: device, commandQueue: commandQueue)
    }

    /// Run star detection on a specific texture (used by simulator to bypass debayer).
    func runStarDetection(on texture: MTLTexture, device: MTLDevice, commandQueue: MTLCommandQueue) {
        guard starDetectionEnabled else {
            appendDebug("[Det] disabled")
            return
        }

        let fmt = texture.pixelFormat.rawValue
        let storage = texture.storageMode.rawValue
        let modelLoaded = starDetectorModelLoaded
        let useClassical = forceClassicalDetector || !starDetectorModelLoaded
        appendDebug("[Det] tex=\(texture.width)x\(texture.height) fmt=\(fmt) storage=\(storage) model=\(modelLoaded) classical=\(useClassical)")

        do {
            let detector: StarDetectorProtocol = useClassical ? classicalDetector : starDetector
            let stars = try detector.detectStars(in: texture, device: device, commandQueue: commandQueue)
            detectedStars = stars
            // Log CoreML diagnostics if available
            if !useClassical {
                appendDebug("[Det] \(starDetector.lastDiagnostic)")
            }
            if let s = stars.first {
                appendDebug("[Det] found \(stars.count) stars, best: x=\(String(format:"%.1f",s.x)) y=\(String(format:"%.1f",s.y)) snr=\(String(format:"%.1f",s.snr)) fwhm=\(String(format:"%.1f",s.fwhm))")
            } else {
                appendDebug("[Det] found 0 stars")
            }
        } catch {
            appendDebug("[Det] ERROR: \(error)")
        }
    }

    /// Wait for the next fresh star detection result.
    /// Polls until `detectedStars` changes from its current value, or times out after 30s.
    /// Returns the detected stars (may be empty on timeout with no detection).
    func waitForFreshDetection(timeoutSeconds: Double = 30.0) async -> [DetectedStar] {
        let oldStars = detectedStars
        let startTime = ContinuousClock.now
        let timeout = Duration.seconds(timeoutSeconds)

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 200_000_000)
            let current = detectedStars
            if current.count != oldStars.count {
                return current
            }
            if !current.isEmpty, !oldStars.isEmpty,
               current[0].x != oldStars[0].x || current[0].y != oldStars[0].y {
                return current
            }
            if ContinuousClock.now - startTime > timeout {
                return current
            }
        }
        return []
    }

    /// Append a line to the visible debug log.
    func appendDebug(_ msg: String) {
        let ts = String(format: "%.1f", Date.now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1000))
        let line = "[\(ts)] \(msg)"
        debugLines.append(line)
        if debugLines.count > maxDebugLines {
            debugLines.removeFirst(debugLines.count - maxDebugLines)
        }
        debugLog = debugLines.joined(separator: "\n")
    }

    // MARK: - Cooling

    var hasCooler: Bool {
        selectedCamera?.hasCooler == true
    }

    func setCoolerOn(targetCelsius: Int) {
        guard isConnected, hasCooler else { return }
        coolerTargetC = targetCelsius
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                if let bridge = self.alpacaCameraBridge {
                    try bridge.setCooler(enabled: true, targetCelsius: Double(targetCelsius))
                } else if let bridge = self.cameraBridge {
                    try bridge.setCoolerTarget(celsius: targetCelsius)
                }
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
        guard isConnected else { return }
        coolerTargetC = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                if let bridge = self.alpacaCameraBridge {
                    try bridge.setCooler(enabled: false, targetCelsius: 0)
                } else if let bridge = self.cameraBridge {
                    try bridge.setControlValue(kASI_COOLER_ON, value: 0)
                }
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
        guard isConnected, hasCooler, coolerEnabled else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                if let bridge = self.alpacaCameraBridge {
                    try bridge.setCooler(enabled: true, targetCelsius: 20)
                } else if let bridge = self.cameraBridge {
                    try bridge.setControlValue(kASI_TARGET_TEMP, value: 20)
                }
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
        tempPollTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: true) { [weak self] _ in
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
        guard isConnected, hasCooler else { return }
        if let bridge = alpacaCameraBridge {
            DispatchQueue.global(qos: .utility).async {
                let temp = try? bridge.getTemperature()
                Task { @MainActor [weak self] in
                    self?.sensorTempC = temp
                }
            }
        } else if let bridge = cameraBridge {
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

    /// Discover cameras available on the Alpaca server.
    func discoverAlpacaCameras(host: String, port: UInt32) {
        isDiscoveringAlpacaDevices = true
        let h = host
        let p = port
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let devices = (try? PolarCore.discoverAlpacaCameras(host: h, port: UInt16(p))) ?? []
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.alpacaDevices = devices
                if self.selectedAlpacaDevice < 0, !devices.isEmpty {
                    self.selectedAlpacaDevice = 0
                }
                self.isDiscoveringAlpacaDevices = false
            }
        }
    }

    // MARK: - Connection

    func connect() {
        guard !isConnected else { return }

        if cameraSource == .alpaca {
            connectAlpaca()
        } else {
            connectUSB()
        }
    }

    private func connectUSB() {
        guard let cam = selectedCamera else {
            errorMessage = "No camera selected"
            return
        }
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

    private func connectAlpaca() {
        errorMessage = nil
        statusMessage = "Connecting to Alpaca camera..."

        let host = alpacaHost
        let port = alpacaPort
        let deviceNum = alpacaDeviceNumber
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let bridge = AlpacaCameraBridge()
                try bridge.open(host: host, port: port, deviceNumber: deviceNum)
                let camInfo = bridge.toASICameraInfo()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.alpacaCameraBridge = bridge
                    self.isConnected = true
                    // Update discovered cameras list with the Alpaca camera info
                    if let info = camInfo {
                        self.discoveredCameras = [info]
                        self.selectedCameraIndex = 0
                    }
                    self.statusMessage = "Connected to \(bridge.info?.name ?? "Alpaca camera")"
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
        if let bridge = alpacaCameraBridge {
            DispatchQueue.global(qos: .userInitiated).async {
                try? bridge.close()
            }
        }
        cameraBridge = nil
        alpacaCameraBridge = nil
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
        if cameraSource == .alpaca {
            connectAlpaca()
            // For Alpaca, we can't easily chain completion — just connect first
            // The user will press Live after connecting
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
        lastLiveSettings = settings
        appendDebug("[Live] startLive exp=\(settings.exposureMs)ms gain=\(settings.gain) bin=\(settings.binning) detEnabled=\(starDetectionEnabled) device=\(previewViewModel.device != nil) queue=\(previewViewModel.commandQueue != nil)")
        ensureConnected { [weak self] in
            guard let self else { return }
            self.frameForwarder.onSaveFrame = nil
            self.frameForwarder.onFrameReceived = nil

            // Auto-boost binning for Alpaca to speed up preview (network transfer is the bottleneck)
            var liveSettings = settings
            if self.cameraSource == .alpaca && liveSettings.binning < 2 {
                liveSettings.binning = 2
            }
            self.startCaptureInternal(settings: liveSettings)
        }
    }

    /// Stop live preview when switching tabs. Does nothing if saving frames.
    func pauseLiveView() {
        guard isCapturing && !isSaving else { return }
        wasLiveBeforePause = true
        stopCapture()
    }

    /// Restart live preview when switching back to tab.
    /// Uses the last live settings if none provided.
    func resumeLiveView(settings: CameraSettings? = nil) {
        guard wasLiveBeforePause && !isCapturing else { return }
        wasLiveBeforePause = false
        if let s = settings ?? lastLiveSettings {
            startLive(settings: s)
        }
    }

    private var wasLiveBeforePause = false
    private var lastLiveSettings: CameraSettings?

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

            // Skip frames beyond target (capture loop may deliver extra before stop propagates)
            guard num <= count else { return }

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
        alpacaFrameGrabber?.stop()
        alpacaFrameGrabber = nil
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
        guard isConnected else {
            errorMessage = "Camera not connected"
            return
        }
        guard !isCapturing else { return }

        errorMessage = nil

        if let bridge = alpacaCameraBridge {
            // Alpaca capture
            let grabber = AlpacaFrameGrabber(camera: bridge, settings: settings)
            grabber.delegate = frameForwarder
            grabber.onError = { [weak self] msg in
                Task { @MainActor [weak self] in
                    self?.errorMessage = "Alpaca: \(msg)"
                }
            }
            self.alpacaFrameGrabber = grabber

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    try grabber.start()
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.isCapturing = true
                        self.captureWidth = grabber.captureWidth
                        self.captureHeight = grabber.captureHeight
                        if !self.isSaving {
                            self.statusMessage = "Live \(grabber.captureWidth)x\(grabber.captureHeight) (Alpaca)"
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
        } else if let bridge = cameraBridge {
            // USB capture
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
        } else {
            errorMessage = "No camera backend connected"
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

    // MARK: - Frame export

    /// Returns a JPEG-encoded snapshot of the current display texture, or nil if no frame is available.
    /// Uses the fully-processed (debayered + STF-stretched) Metal texture shown in the preview,
    /// which is what should be sent to remote plate solvers — stars are more visible when stretched.
    func currentFrameJPEG(quality: CGFloat = 0.85) -> Data? {
        guard let texture = previewViewModel.displayTexture else { return nil }

        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        texture.getBytes(&pixels,
                         bytesPerRow: bytesPerRow,
                         from: MTLRegionMake2D(0, 0, width, height),
                         mipmapLevel: 0)

        // Build CGImage from BGRA texture data
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue |
                                                   CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else { return nil }

        let mutable = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutable, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }

        return mutable as Data
    }
}

// MARK: - Frame forwarding bridge (not MainActor — called from capture thread)

private class FrameForwarder: FrameGrabberDelegate {
    weak var previewViewModel: CameraPreviewViewModel?
    var onFrameReceived: (@Sendable (UInt64) -> Void)?
    var onSaveFrame: ((Data, Int, Int, Int, UInt64) -> Void)?

    func frameGrabber(_ grabber: FrameGrabber?, didCapture buffer: UnsafeBufferPointer<UInt8>,
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
