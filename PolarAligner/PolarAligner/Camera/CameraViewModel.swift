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

/// Marker camera IDs used for non-ASI devices in the unified USB camera list.
/// Canon cameras use cameraID = -(1000 + canonIndex) so their EDSDK index can be recovered.
let kCanonCameraIDBase: Int32 = -1000
@inline(__always) func isCanonCameraID(_ id: Int32) -> Bool { id <= kCanonCameraIDBase }
@inline(__always) func canonIndexFromCameraID(_ id: Int32) -> Int { Int(-(id - kCanonCameraIDBase)) }
@inline(__always) func canonCameraID(for index: Int) -> Int32 { kCanonCameraIDBase - Int32(index) }

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
    @Published var exposureStartDate: Date? = nil
    @Published var currentExposureSec: Double = 0

    // Video recording (ASI USB only)
    @Published var isRecordingVideo = false
    @Published var videoFrameCount: Int = 0
    private var serWriter: SERWriter?

    // ASI USB only: image format (RAW8 / RAW16). RAW8 halves the per-frame
    // bandwidth so you can hit the camera's full frame rate (e.g. 47 fps vs
    // 24 fps on the ASI585MC Pro). Useful for planetary video; RAW16 is better
    // for deep-sky work where bit depth matters. Persisted via UserDefaults.
    @Published var asiImageFormat: ASIImageFormat = {
        if let raw = UserDefaults.standard.object(forKey: "asiImageFormat") as? Int,
           let fmt = ASIImageFormat(rawValue: Int32(raw)) {
            return fmt
        }
        return .raw16
    }() {
        didSet {
            UserDefaults.standard.set(Int(asiImageFormat.rawValue), forKey: "asiImageFormat")
            appendDebug("[Cam] ASI format → \(asiImageFormat)")
        }
    }
    /// True when the connected camera supports RAW8/RAW16 selection (ASI USB only).
    var supportsImageFormatSelection: Bool { cameraBridge != nil }

    /// ASI USB only: ROI preset. Smaller ROI reads out fewer sensor rows so
    /// frame rate scales up proportionally (the real planetary-imaging win).
    /// Persisted via UserDefaults.
    @Published var asiRoiPreset: ASIRoiPreset = {
        if let raw = UserDefaults.standard.string(forKey: "asiRoiPreset"),
           let preset = ASIRoiPreset(rawValue: raw) {
            return preset
        }
        return .full
    }() {
        didSet {
            UserDefaults.standard.set(asiRoiPreset.rawValue, forKey: "asiRoiPreset")
            appendDebug("[Cam] ASI ROI → \(asiRoiPreset.rawValue)")
        }
    }

    /// ROI presets that fit within the currently connected USB camera's sensor.
    /// Different ASI models have very different sensor sizes (e.g. ASI585MC
    /// 3840×2160 vs ASI120MM 1280×960), so unavailable presets are filtered
    /// out of the picker rather than silently clamped.
    var availableRoiPresets: [ASIRoiPreset] {
        guard let cam = selectedCamera else { return ASIRoiPreset.allCases }
        return ASIRoiPreset.allCases.filter { preset in
            guard let d = preset.dimensions else { return true } // .full always OK
            return d.width <= cam.maxWidth && d.height <= cam.maxHeight
        }
    }

    /// Call after a camera connects so a saved preset that doesn't fit the new
    /// sensor falls back to `.full` (e.g. user swaps from ASI585 to ASI120).
    private func reconcileRoiPresetForConnectedCamera() {
        guard cameraBridge != nil else { return }
        if !availableRoiPresets.contains(asiRoiPreset) {
            appendDebug("[Cam] Saved ROI \(asiRoiPreset.rawValue) doesn't fit \(selectedCamera?.name ?? "camera"); reverting to Full")
            asiRoiPreset = .full
        }
    }

    // Canon-only: white balance preset
    @Published var canonWhiteBalance: CanonCameraBridge.WhiteBalance = .auto {
        didSet {
            applyCanonWhiteBalance()
        }
    }
    /// True when the connected camera supports white balance UI (Canon).
    var supportsWhiteBalance: Bool { canonCameraBridge != nil }

    /// Set the published WB without re-triggering the didSet → camera write
    /// (used when reading the current value from the camera on connect).
    fileprivate func _setCanonWhiteBalanceSilently(_ wb: CanonCameraBridge.WhiteBalance) {
        _suppressCanonWBApply = true
        canonWhiteBalance = wb
        _suppressCanonWBApply = false
    }
    private var _suppressCanonWBApply = false

    private func applyCanonWhiteBalance() {
        if _suppressCanonWBApply { return }
        guard let bridge = canonCameraBridge else { return }
        let wb = canonWhiteBalance
        CanonCameraBridge.sdkQueue.async { [weak self] in
            do {
                try bridge.setWhiteBalance(wb)
                Task { @MainActor [weak self] in
                    self?.appendDebug("[Canon] WB → \(wb.label)")
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.errorMessage = "Canon WB: \(error.localizedDescription)"
                }
            }
        }
    }

    // Star detection
    @Published var detectedStars: [DetectedStar] = []
    /// Incremented each time runStarDetection completes. Used by waitForFreshDetection
    /// to reliably detect a new camera frame without relying on star position comparison.
    private(set) var detectionStamp: Int = 0
    @Published var starDetectionEnabled = false

    /// User-selectable star-shape preset for the detector.
    /// Persisted via UserDefaults so the choice survives restarts.
    @Published var starDetectorMode: StarDetectorMode = StarDetectorMode(rawValue:
        UserDefaults.standard.string(forKey: "starDetectorMode") ?? StarDetectorMode.sharp.rawValue
    ) ?? .sharp {
        didSet {
            classicalDetector.config = starDetectorMode.config
            UserDefaults.standard.set(starDetectorMode.rawValue, forKey: "starDetectorMode")
            appendDebug("[Det] mode → \(starDetectorMode.rawValue)")
        }
    }

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

    /// Serial queue for all camera SDK / network operations (start, stop, configure,
    /// close, etc.). Keeps UI responsive — MainActor only flips @Published state,
    /// never waits for HTTP/SDK calls. Also serializes stop→start on the same
    /// camera so the new session doesn't race the old one.
    private let cameraOpQueue = DispatchQueue(label: "com.polaraligner.camera-ops", qos: .userInitiated)

    private var cameraBridge: ASICameraBridge?
    private var alpacaCameraBridge: AlpacaCameraBridge?
    private var canonCameraBridge: CanonCameraBridge?
    private var frameGrabber: FrameGrabber?
    private var alpacaFrameGrabber: AlpacaFrameGrabber?
    private var canonFrameGrabber: CanonFrameGrabber?
    private let frameForwarder = FrameForwarder()
    private let classicalDetector = ClassicalDetector()
    private var lastDetectionNanos: UInt64 = 0
    /// Guard against overlapping background detections — only one at a time.
    private var detectionInProgress = false
    private var tempPollTimer: Timer?
    private var healthCheckTimer: Timer?
    private var healthCheckCounter: Int = 0

    var selectedCamera: ASICameraInfo? {
        guard selectedCameraIndex >= 0, selectedCameraIndex < discoveredCameras.count else { return nil }
        return discoveredCameras[selectedCameraIndex]
    }

    init() {
        frameForwarder.previewViewModel = previewViewModel
        // Apply persisted star-shape preset to the detector
        classicalDetector.config = starDetectorMode.config

        // Notify when a new frame is processed (for star detection on demand)
        previewViewModel.onFrameProcessed = { [weak self] in
            guard let self else { return }
            // Only run automatic detection when explicitly enabled (guide tab visible)
            guard self.starDetectionEnabled else { return }
            self.runStarDetection()
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
    ///
    /// Detection is dispatched to a background thread so that the GPU wait and CPU
    /// peak-finding loop do not block the main actor (which caused the beach ball).
    func runStarDetection(on texture: MTLTexture, device: MTLDevice, commandQueue: MTLCommandQueue) {
        guard starDetectionEnabled else {
            appendDebug("[Det] disabled")
            return
        }
        // Skip if a detection is already running to avoid queuing a backlog of work.
        guard !detectionInProgress else {
            appendDebug("[Det] skip: detection already in progress")
            return
        }
        detectionInProgress = true

        let detector = classicalDetector

        Task.detached(priority: .userInitiated) { [weak self] in
            var stars: [DetectedStar] = []
            do {
                stars = try detector.detectStars(in: texture, device: device, commandQueue: commandQueue)
            } catch {
                await MainActor.run { [weak self] in self?.appendDebug("[Det] ERROR: \(error)") }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.detectedStars = stars
                self.detectionStamp &+= 1
                self.detectionInProgress = false
                if let s = stars.first {
                    self.appendDebug("[Det] found \(stars.count) stars, best: x=\(String(format:"%.1f",s.x)) y=\(String(format:"%.1f",s.y)) snr=\(String(format:"%.1f",s.snr)) fwhm=\(String(format:"%.1f",s.fwhm))")
                } else {
                    self.appendDebug("[Det] found 0 stars")
                }
            }
        }
    }

    /// Wait for the next fresh star detection result.
    /// Returns as soon as one new camera frame has been processed by the star detector.
    func waitForFreshDetection(timeoutSeconds: Double = 30.0) async -> [DetectedStar] {
        let wasEnabled = starDetectionEnabled
        starDetectionEnabled = true
        defer { starDetectionEnabled = wasEnabled }

        let oldStamp = detectionStamp
        let startTime = ContinuousClock.now
        let timeout = Duration.seconds(timeoutSeconds)

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if detectionStamp != oldStamp {
                return detectedStars
            }
            if ContinuousClock.now - startTime > timeout {
                return detectedStars
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
            // ASI cameras (ZWO USB)
            var cameras = (try? ASICameraBridge.listCameras()) ?? []
            // Deduplicate by camera ID
            var seen = Set<Int32>()
            cameras = cameras.filter { seen.insert($0.cameraID).inserted }

            // Canon cameras (EDSDK) — append as pseudo-ASICameraInfo with marker IDs
            if let canonList = try? CanonCameraBridge.listCameras() {
                for (i, info) in canonList.enumerated() {
                    let pseudo = ASICameraInfo(
                        name: info.productName + " (Canon)",
                        cameraID: canonCameraID(for: i),
                        maxWidth: 0, maxHeight: 0,
                        isColorCamera: true,
                        bayerPattern: .rg,
                        supportedBins: [1],
                        pixelSize: 0,
                        hasCooler: false,
                        isUSB3: true,
                        bitDepth: 14,
                        electronPerADU: 0
                    )
                    cameras.append(pseudo)
                }
            }

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
            // Unified USB path: route to Canon or ASI based on selected camera
            if let id = selectedCamera?.cameraID, isCanonCameraID(id) {
                connectCanon(edsIndex: canonIndexFromCameraID(id))
            } else {
                connectUSB()
            }
        }
    }

    private func connectCanon(edsIndex: Int) {
        errorMessage = nil
        statusMessage = "Connecting to Canon camera..."

        let index = edsIndex

        // EDSDK on macOS requires initialization + event pump on the main thread
        // BEFORE any session is opened. Set both up now.
        do {
            try CanonCameraBridge.initializeSDK()
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Canon SDK init failed"
            return
        }
        CanonEventPump.shared.retain()

        CanonCameraBridge.sdkQueue.async { [weak self] in
            do {
                let bridge = CanonCameraBridge()
                try bridge.open(at: index)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.canonCameraBridge = bridge
                    self.isConnected = true
                    let name = bridge.info?.productName ?? "Canon camera"
                    self.statusMessage = "Connected to \(name)"
                    self.startHealthCheck()
                    // Wire up the still-captured handler to auto-download RAW
                    bridge.onStillCaptured = { [weak self] dirItem in
                        guard let self else {
                            EdsRelease(dirItem)
                            return
                        }
                        self.handleCanonStillCaptured(dirItem: dirItem)
                    }
                    // Read current WB from the camera so the UI matches.
                    CanonCameraBridge.sdkQueue.async { [weak self] in
                        if let wb = try? bridge.getWhiteBalance() {
                            Task { @MainActor [weak self] in
                                // Set _wrapper to avoid triggering the didSet → re-applying
                                self?._setCanonWhiteBalanceSilently(wb)
                            }
                        }
                    }
                }
            } catch {
                CanonEventPump.shared.release()
                Task { @MainActor [weak self] in
                    self?.errorMessage = error.localizedDescription
                    self?.statusMessage = "Connection failed"
                }
            }
        }
    }

    private func handleCanonStillCaptured(dirItem: EdsDirectoryItemRef) {
        // Download the newly captured image to the user's capture folder.
        CanonCameraBridge.sdkQueue.async { [weak self] in
            guard let self, let bridge = self.canonCameraBridge else {
                EdsRelease(dirItem)
                return
            }
            let folderPath = UserDefaults.standard.string(forKey: "captureFolder") ?? ""
            let folder: URL
            if folderPath.isEmpty {
                folder = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Pictures/PolarStation")
            } else {
                folder = URL(fileURLWithPath: folderPath)
            }
            let prefix = UserDefaults.standard.string(forKey: "capturePrefix") ?? "canon"
            do {
                let saved = try bridge.downloadImage(dirItem: dirItem, toFolder: folder, filenamePrefix: prefix)
                Task { @MainActor [weak self] in
                    self?.statusMessage = "Saved \(saved.lastPathComponent)"
                    self?.appendDebug("[Canon] Saved \(saved.lastPathComponent)")
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.errorMessage = "Canon download: \(error.localizedDescription)"
                }
            }
            EdsRelease(dirItem)
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
                    self.reconcileRoiPresetForConnectedCamera()
                    self.startHealthCheck()
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
                    self.startHealthCheck()
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
        // Close runs on the same serial queue as stop/start so it's strictly ordered
        // after any pending grabber shutdown — no race on the underlying bridge.
        if let bridge = cameraBridge {
            cameraOpQueue.async { try? bridge.close() }
        }
        if let bridge = alpacaCameraBridge {
            cameraOpQueue.async { try? bridge.close() }
        }
        if let bridge = canonCameraBridge {
            cameraOpQueue.async {
                CanonCameraBridge.sdkQueue.sync { bridge.close() }
            }
            CanonEventPump.shared.release()
        }
        cameraBridge = nil
        alpacaCameraBridge = nil
        canonCameraBridge = nil
        isConnected = false
        coolerEnabled = false
        sensorTempC = nil
        coolerPowerPercent = nil
        coolerTargetC = nil
        previewViewModel.displayTexture = nil
        stopHealthCheck()
        statusMessage = "Disconnected"
    }

    // MARK: - Connection Health Check

    func startHealthCheck() {
        stopHealthCheck()
        // Check once per minute
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkConnectionHealth()
            }
        }
    }

    func stopHealthCheck() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
    }

    private func checkConnectionHealth() {
        guard isConnected else { return }

        if let bridge = alpacaCameraBridge {
            // Alpaca: try a lightweight GET
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let alive = bridge.healthCheck()
                Task { @MainActor [weak self] in
                    guard let self, self.isConnected else { return }
                    if !alive {
                        self.appendDebug("[Health] Alpaca camera lost")
                        self.stopCapture()
                        self.disconnect()
                        self.errorMessage = "Camera disconnected"
                    }
                }
            }
        } else if let bridge = cameraBridge {
            // USB: check if camera ID still in connected list
            let cameraID = bridge.cameraID
            ASICameraBridge.sdkQueue.async { [weak self] in
                let count = ASICameraBridge.connectedCameraCount()
                var found = false
                for i in 0..<count {
                    if let info = try? ASICameraBridge.cameraInfo(at: i), info.cameraID == cameraID {
                        found = true
                        break
                    }
                }
                Task { @MainActor [weak self] in
                    guard let self, self.isConnected else { return }
                    if !found {
                        self.appendDebug("[Health] USB camera unplugged")
                        self.stopCapture()
                        self.disconnect()
                        self.errorMessage = "Camera disconnected"
                    }
                }
            }
        }
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

            self.startCaptureInternal(settings: settings)
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
        // Canon: use native still shutter — RAW file is downloaded via DirItemRequestTransfer.
        if canonCameraBridge != nil {
            beginCanonStillCapture(count: count, folder: folder, prefix: prefix)
            return
        }

        ensureConnected { [weak self] in
            guard let self else { return }
            self.beginCaptureSequence(
                count: count, settings: settings,
                format: format, colorMode: colorMode, folder: folder, prefix: prefix
            )
        }
    }

    /// Canon still capture: press the shutter `count` times. Each image is
    /// delivered asynchronously by the ObjectEvent handler and saved via
    /// `handleCanonStillCaptured`.
    private func beginCanonStillCapture(count: Int, folder: URL, prefix: String) {
        guard let bridge = canonCameraBridge else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        UserDefaults.standard.set(folder.path, forKey: "captureFolder")
        UserDefaults.standard.set(prefix, forKey: "capturePrefix")

        capturedCount = 0
        targetCount = count
        isSaving = true
        statusMessage = "Canon: shooting 0/\(count)..."
        appendDebug("[Canon] still sequence count=\(count)")

        CanonCameraBridge.sdkQueue.async { [weak self] in
            for i in 0..<count {
                do {
                    try bridge.takePicture()
                    Task { @MainActor [weak self] in
                        self?.capturedCount = i + 1
                        self?.statusMessage = "Canon: shooting \(i + 1)/\(count)..."
                    }
                    // Let the camera finish the shot + transfer before next shutter
                    Thread.sleep(forTimeInterval: 1.5)
                } catch {
                    Task { @MainActor [weak self] in
                        self?.errorMessage = "Canon shutter: \(error.localizedDescription)"
                    }
                    break
                }
            }
            Task { @MainActor [weak self] in
                self?.isSaving = false
                self?.statusMessage = "Canon: \(self?.capturedCount ?? 0) frames shot"
            }
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
        appendDebug("[Cam] beginCaptureSequence count=\(count) exp=\(settings.exposureMs)ms isCapturing=\(isCapturing)")
        if isCapturing { stopCapture() }

        capturedCount = 0
        targetCount = count
        isSaving = true
        errorMessage = nil

        // Gather metadata
        let bayerStr = bayerPatternString(cam.bayerPattern)
        let lat = UserDefaults.standard.double(forKey: "observerLat")
        let lon = UserDefaults.standard.double(forKey: "observerLon")
        let solvedRA = UserDefaults.standard.object(forKey: "lastSolvedRA") as? Double
        let solvedDec = UserDefaults.standard.object(forKey: "lastSolvedDec") as? Double
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
                    observerLon: lon != 0 ? lon : nil,
                    solvedRA: solvedRA,
                    solvedDec: solvedDec
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
        startCaptureInternal(settings: settings, maxFrames: count)
        statusMessage = "Capturing 0/\(count)..."
    }

    private func finishCaptureSequence() {
        stopCapture()
        isSaving = false
        frameForwarder.onSaveFrame = nil
        statusMessage = "Capture complete (\(capturedCount) frames saved)"
    }

    // MARK: - Video Recording (ASI USB only)

    /// Start recording video to a SER file using ASI video mode.
    /// Only works with USB ASI cameras (not Alpaca).
    func startVideoRecording(settings: CameraSettings, folder: URL, prefix: String) {
        // Canon path: tap the EVF JPEG stream and write each decoded frame as RGB SER
        if canonCameraBridge != nil {
            beginCanonVideoRecording(folder: folder, prefix: prefix)
            return
        }
        guard cameraSource == .usb, cameraBridge != nil else {
            errorMessage = "Video recording requires USB camera"
            return
        }
        guard !isCapturing else {
            appendDebug("[Video] Cannot start: capture already running")
            return
        }

        ensureConnected { [weak self] in
            guard let self else { return }
            self.beginVideoRecording(settings: settings, folder: folder, prefix: prefix)
        }
    }

    /// True when the Canon record path auto-started live view, so stop should also stop live.
    private var canonLiveStartedByRecording = false

    /// Canon EVF → SER recording. Live view must be running; if not, we start it.
    private func beginCanonVideoRecording(folder: URL, prefix: String) {
        guard let bridge = canonCameraBridge else { return }

        // Ensure live view is running so we have a frame stream to tap
        canonLiveStartedByRecording = false
        if !isCapturing {
            canonLiveStartedByRecording = true
            startCaptureInternal(settings: CameraSettings())
        }

        guard let grabber = canonFrameGrabber else {
            errorMessage = "Canon: live view not active"
            return
        }

        // Wait for first frame so we know the dimensions, then create the SER writer.
        // Frame size doesn't change during EVF, so this only happens once.
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let timestamp = FrameSaver.captureTimestamp()
        let filename = "\(prefix)_\(timestamp).ser"
        let fileURL = folder.appendingPathComponent(filename)

        videoFrameCount = 0
        isRecordingVideo = true
        statusMessage = "Recording (Canon EVF)..."
        appendDebug("[Canon] Recording to \(filename)")

        // Defer SER writer creation until the first frame arrives — we need w/h.
        var writer: SERWriter?
        var writerLock = NSLock()
        grabber.onRGBFrame = { [weak self] rgbBuf, w, h in
            writerLock.lock()
            if writer == nil {
                writer = try? SERWriter(
                    url: fileURL,
                    width: w,
                    height: h,
                    bitsPerPixel: 8,
                    colorID: .rgb,
                    instrument: bridge.info?.productName ?? "Canon"
                )
                if writer == nil {
                    Task { @MainActor [weak self] in
                        self?.errorMessage = "Failed to create SER file"
                        self?.isRecordingVideo = false
                    }
                }
            }
            writer?.addFrame(rgbBuf)
            let count = writer?.frameCount ?? 0
            writerLock.unlock()
            Task { @MainActor [weak self] in
                self?.videoFrameCount = Int(count)
            }
        }

        // Stash the writer so finalize can find it
        self.canonSerWriter = { writer }
    }

    /// Box around the Canon SER writer so the closure-captured `writer` survives
    /// across frames and can be finalized on stop.
    private var canonSerWriter: (() -> SERWriter?)?

    private func beginVideoRecording(settings: CameraSettings, folder: URL, prefix: String) {
        guard let cam = selectedCamera else { return }
        if isCapturing { stopCapture() }

        // Compute dimensions
        let width = cam.maxWidth / settings.binning
        let height = cam.maxHeight / settings.binning
        let adjWidth = (width / 8) * 8
        let adjHeight = (height / 2) * 2

        // Determine SER color ID from bayer pattern
        let serColorID: SERWriter.ColorID
        if cam.isColorCamera {
            switch cam.bayerPattern {
            case .rg: serColorID = .bayerRGGB
            case .gr: serColorID = .bayerGRBG
            case .gb: serColorID = .bayerGBRG
            case .bg: serColorID = .bayerBGGR
            }
        } else {
            serColorID = .mono
        }

        let bitsPerPixel = settings.bytesPerPixel * 8
        let timestamp = FrameSaver.captureTimestamp()
        let filename = "\(prefix)_\(timestamp).ser"

        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fileURL = folder.appendingPathComponent(filename)

        do {
            let writer = try SERWriter(
                url: fileURL,
                width: adjWidth,
                height: adjHeight,
                bitsPerPixel: bitsPerPixel,
                colorID: serColorID,
                instrument: cam.name
            )
            self.serWriter = writer
        } catch {
            errorMessage = "Failed to create SER file: \(error.localizedDescription)"
            return
        }

        videoFrameCount = 0
        isRecordingVideo = true
        errorMessage = nil

        // Set up frame forwarding: preview + SER write
        frameForwarder.onSaveFrame = { [weak self] data, w, h, bpp, _ in
            guard let self, let writer = self.serWriter else { return }
            data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                let ubp = UnsafeBufferPointer(start: base, count: data.count)
                writer.addFrame(ubp)
            }
            Task { @MainActor [weak self] in
                self?.videoFrameCount = Int(writer.frameCount)
                self?.statusMessage = "Recording: \(writer.frameCount) frames"
            }
        }
        frameForwarder.onFrameReceived = nil

        // Start FrameGrabber in video mode
        guard let bridge = cameraBridge else { return }
        var videoSettings = settings
        videoSettings.imageFormat = asiImageFormat
        if let roi = asiRoiPreset.dimensions {
            videoSettings.roiWidth = roi.width
            videoSettings.roiHeight = roi.height
        }
        let grabber = FrameGrabber(camera: bridge, settings: videoSettings)
        grabber.videoMode = true
        grabber.delegate = frameForwarder
        self.frameGrabber = grabber
        isCapturing = true

        cameraOpQueue.async { [weak self] in
            do {
                try grabber.start()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.captureWidth = grabber.captureWidth
                    self.captureHeight = grabber.captureHeight
                    self.statusMessage = "Recording \(grabber.captureWidth)x\(grabber.captureHeight)"
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.isCapturing = false
                    self?.isRecordingVideo = false
                    self?.errorMessage = error.localizedDescription
                    self?.statusMessage = "Recording failed"
                }
            }
        }

        appendDebug("[Video] Recording to \(filename) \(adjWidth)x\(adjHeight) \(bitsPerPixel)bpp color=\(serColorID) isColor=\(cam.isColorCamera) bayer=\(cam.bayerPattern)")
    }

    /// Stop video recording and finalize the SER file.
    func stopVideoRecording() {
        guard isRecordingVideo else { return }
        appendDebug("[Video] Stopping, \(videoFrameCount) frames recorded")

        // Canon path: detach the RGB tap, finalize the SER writer, and only
        // stop live view if we auto-started it as part of recording.
        if canonCameraBridge != nil {
            canonFrameGrabber?.onRGBFrame = nil
            let writer = canonSerWriter?()
            canonSerWriter = nil
            writer?.finalize()
            isRecordingVideo = false
            statusMessage = "Video saved (\(videoFrameCount) frames)"
            if canonLiveStartedByRecording {
                stopCapture()
                canonLiveStartedByRecording = false
            }
            return
        }

        // ASI path: stop capture, finalize SER writer
        stopCapture()

        if let writer = serWriter {
            DispatchQueue.global(qos: .utility).async {
                writer.finalize()
            }
            serWriter = nil
        }

        isRecordingVideo = false
        frameForwarder.onSaveFrame = nil
        statusMessage = "Video saved (\(videoFrameCount) frames)"
    }

    // MARK: - Core Capture

    func stopCapture() {
        guard isCapturing else { return }
        appendDebug("[Cam] stopCapture isSaving=\(isSaving)")

        // Snapshot the grabbers and clear the VM's references synchronously on main
        // (so a subsequent startCaptureInternal can't double-start), then run the
        // actual .stop() calls — which do HTTP / SDK / thread-join work — on the
        // serial camera queue. UI never blocks on network.
        let usbGrabber = frameGrabber
        let alpacaGrabber = alpacaFrameGrabber
        let canonGrabber = canonFrameGrabber
        frameGrabber = nil
        alpacaFrameGrabber = nil
        canonFrameGrabber = nil

        cameraOpQueue.async {
            usbGrabber?.stop()
            alpacaGrabber?.stop()
            canonGrabber?.stop()
        }

        isCapturing = false
        exposureStartDate = nil
        frameForwarder.onSaveFrame = nil
        frameForwarder.onFrameReceived = nil
        if isSaving {
            isSaving = false
        }
        if isConnected && !isSaving {
            statusMessage = "Connected (idle)"
        }
    }

    private func startCaptureInternal(settings: CameraSettings, maxFrames: Int = 0) {
        guard isConnected else {
            errorMessage = "Camera not connected"
            return
        }
        guard !isCapturing else { return }

        // Claim the capturing slot synchronously so no second grabber can race in
        // before the background thread finishes configuring the camera.
        isCapturing = true
        errorMessage = nil

        if let bridge = alpacaCameraBridge {
            // Alpaca capture
            let mode = maxFrames > 0 ? "capture(n=\(maxFrames))" : "live"
            appendDebug("[Cam] startCaptureInternal \(mode) exp=\(settings.exposureMs)ms gain=\(settings.gain) bin=\(settings.binning)")
            let grabber = AlpacaFrameGrabber(camera: bridge, settings: settings)
            grabber.maxFrames = maxFrames
            grabber.delegate = frameForwarder
            grabber.onLog = { [weak self] msg in
                Task { @MainActor [weak self] in
                    self?.appendDebug("[Grabber] \(msg)")
                }
            }
            grabber.onError = { [weak self] msg in
                Task { @MainActor [weak self] in
                    self?.appendDebug("[Grabber] ERROR: \(msg)")
                    self?.errorMessage = "Alpaca: \(msg)"
                }
            }
            grabber.onExposureStarted = { [weak self] durationSec in
                Task { @MainActor [weak self] in
                    self?.exposureStartDate = Date()
                    self?.currentExposureSec = durationSec
                }
            }
            self.alpacaFrameGrabber = grabber

            cameraOpQueue.async { [weak self] in
                do {
                    try grabber.start()
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.captureWidth = grabber.captureWidth
                        self.captureHeight = grabber.captureHeight
                        if !self.isSaving {
                            self.statusMessage = "Live \(grabber.captureWidth)x\(grabber.captureHeight) (Alpaca)"
                        }
                    }
                } catch {
                    Task { @MainActor [weak self] in
                        self?.isCapturing = false
                        self?.errorMessage = error.localizedDescription
                        self?.statusMessage = "Capture failed"
                        self?.isSaving = false
                    }
                }
            }
        } else if let bridge = cameraBridge {
            // USB capture
            var asiSettings = settings
            asiSettings.imageFormat = asiImageFormat
            if let roi = asiRoiPreset.dimensions {
                asiSettings.roiWidth = roi.width
                asiSettings.roiHeight = roi.height
            }
            let grabber = FrameGrabber(camera: bridge, settings: asiSettings)
            grabber.delegate = frameForwarder
            // Use video mode for live preview — no per-frame startExposure overhead,
            // continuous sensor readout. Capture sequences (maxFrames > 0) still use
            // snap mode so each frame is a deliberate, individually-timed exposure.
            if maxFrames == 0 {
                grabber.videoMode = true
            }
            // Only update the exposure timer for capture sequences, not live view
            // (the timer UI is gated on isSaving, and short live-view exposures
            // would flood the main actor with @Published setters).
            if maxFrames > 0 {
                grabber.onExposureStarted = { [weak self] durationSec in
                    Task { @MainActor [weak self] in
                        self?.exposureStartDate = Date()
                        self?.currentExposureSec = durationSec
                    }
                }
            }
            self.frameGrabber = grabber

            cameraOpQueue.async { [weak self] in
                do {
                    try grabber.start()
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.captureWidth = grabber.captureWidth
                        self.captureHeight = grabber.captureHeight
                        if !self.isSaving {
                            self.statusMessage = "Live \(grabber.captureWidth)x\(grabber.captureHeight)"
                        }
                    }
                } catch {
                    Task { @MainActor [weak self] in
                        self?.isCapturing = false
                        self?.errorMessage = error.localizedDescription
                        self?.statusMessage = "Capture failed"
                        self?.isSaving = false
                    }
                }
            }
        } else if let bridge = canonCameraBridge {
            // Canon live view (JPEG EVF). Still capture uses takePicture() separately.
            appendDebug("[Cam] startCaptureInternal canon EVF")
            let grabber = CanonFrameGrabber(camera: bridge)
            grabber.previewViewModel = previewViewModel
            grabber.onLog = { [weak self] msg in
                Task { @MainActor [weak self] in
                    self?.appendDebug("[Canon] \(msg)")
                }
            }
            self.canonFrameGrabber = grabber

            cameraOpQueue.async { [weak self] in
                do {
                    try grabber.start()
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if !self.isSaving {
                            self.statusMessage = "Live (Canon EVF)"
                        }
                    }
                } catch {
                    Task { @MainActor [weak self] in
                        self?.isCapturing = false
                        self?.errorMessage = error.localizedDescription
                        self?.statusMessage = "Live view failed"
                    }
                }
            }
        } else {
            isCapturing = false
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
