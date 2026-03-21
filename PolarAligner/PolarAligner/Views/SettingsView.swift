import SwiftUI
import PolarCore

struct SettingsView: View {
    @EnvironmentObject var dssTileService: DSSTileService
    @ObservedObject var mountService: MountService
    @ObservedObject var plateSolveService: PlateSolveService
    @ObservedObject var coordinator: AlignmentCoordinator
    @ObservedObject var cameraViewModel: CameraViewModel
    @ObservedObject var guideCameraViewModel: CameraViewModel
    @ObservedObject var filterWheelViewModel: FilterWheelViewModel
    @ObservedObject var focuserViewModel: FocuserViewModel
    @ObservedObject var domeViewModel: DomeViewModel
    @ObservedObject var rotatorViewModel: RotatorViewModel
    @ObservedObject var switchViewModel: SwitchViewModel
    @ObservedObject var safetyMonitorViewModel: SafetyMonitorViewModel
    @ObservedObject var observingConditionsViewModel: ObservingConditionsViewModel
    @ObservedObject var coverCalibratorViewModel: CoverCalibratorViewModel

    // Mount connection
    @AppStorage("mountProtocol") private var mountProtocolRaw: String = MountProtocolChoice.lx200.rawValue
    @AppStorage("mountSerialPort") private var serialPort: String = ""
    @AppStorage("mountBaudRate") private var baudRateStored: Int = 9600
    @AppStorage("mountLx200TcpHost") private var lx200TcpHost: String = "192.168.4.1"
    @AppStorage("mountLx200TcpPort") private var lx200TcpPortStored: Int = 4030
    @AppStorage("mountAlpacaHost") private var alpacaHost: String = "192.168.1.1"
    @AppStorage("mountAlpacaPort") private var alpacaPortStored: Int = 11111
    @State private var availablePorts: [String] = []
    @State private var mountError: String?

    private var mountProtocol: MountProtocolChoice {
        MountProtocolChoice(rawValue: mountProtocolRaw) ?? .lx200
    }
    private var baudRate: UInt32 { UInt32(baudRateStored) }
    private var lx200TcpPort: UInt32 { UInt32(lx200TcpPortStored) }
    private var alpacaPort: UInt32 { UInt32(alpacaPortStored) }

    private var mountProtocolBinding: Binding<MountProtocolChoice> {
        Binding(
            get: { MountProtocolChoice(rawValue: mountProtocolRaw) ?? .lx200 },
            set: { mountProtocolRaw = $0.rawValue }
        )
    }

    // Observer location
    @AppStorage("observerLat") private var observerLat: Double = 60.17
    @AppStorage("observerLon") private var observerLon: Double = 24.94

    // Telescope & Optics
    @AppStorage("focalLengthMM") private var focalLengthMM: Double = 200.0
    @AppStorage("pixelSizeMicrons") private var pixelSizeMicrons: Double = 2.9
    @AppStorage("sensorWidthPx") private var sensorWidthPx: Int = 1920
    @AppStorage("sensorHeightPx") private var sensorHeightPx: Int = 1080
    @AppStorage("bayerPattern") private var bayerPattern: String = "RGGB"
    @AppStorage("cameraFlipX") private var cameraFlipX: Bool = false
    @AppStorage("cameraFlipY") private var cameraFlipY: Bool = false
    @AppStorage("guideFocalLengthMM") private var guideFocalLengthMM: Double = 200.0
    @AppStorage("guidePixelSizeMicrons") private var guidePixelSizeMicrons: Double = 2.9

    // Camera
    @AppStorage("cameraSource") private var cameraSourceRaw: String = CameraSource.usb.rawValue
    @State private var discoveredCameras: [ASICameraInfo] = []
    @State private var selectedCameraIndex: Int = -1
    @State private var isDiscoveringCameras = false
    @AppStorage("exposureMs") private var exposureMs: Double = 500
    @AppStorage("gain") private var gain: Double = 300
    @AppStorage("binning") private var binning: Int = 2
    @AppStorage("cameraAlpacaHost") private var cameraAlpacaHost: String = "192.168.8.30"
    @AppStorage("cameraAlpacaPort") private var cameraAlpacaPort: Int = 11111

    // Guide camera
    @AppStorage("guideCameraSource") private var guideCameraSourceRaw: String = CameraSource.usb.rawValue
    @State private var guideDiscoveredCameras: [ASICameraInfo] = []
    @State private var guideSelectedCameraIndex: Int = -1
    @State private var isDiscoveringGuideCameras = false
    @AppStorage("guideExposureMs") private var guideExposureMs: Double = 500
    @AppStorage("guideGain") private var guideGain: Double = 300
    @AppStorage("guideBinning") private var guideBinning: Int = 2
    @AppStorage("guideCameraAlpacaHost") private var guideCameraAlpacaHost: String = "192.168.8.30"
    @AppStorage("guideCameraAlpacaPort") private var guideCameraAlpacaPort: Int = 11111
    @AppStorage("guideCapturePrefix") private var guideCapturePrefix: String = "guide"

    // Filter wheel
    @AppStorage("filterWheelAlpacaHost") private var filterWheelAlpacaHost: String = "192.168.8.30"
    @AppStorage("filterWheelAlpacaPort") private var filterWheelAlpacaPort: Int = 11111

    // Focuser
    @AppStorage("focuserAlpacaHost") private var focuserAlpacaHost: String = "192.168.8.30"
    @AppStorage("focuserAlpacaPort") private var focuserAlpacaPort: Int = 11111

    // Dome
    @AppStorage("domeAlpacaHost") private var domeAlpacaHost: String = "192.168.8.30"
    @AppStorage("domeAlpacaPort") private var domeAlpacaPort: Int = 11111

    // Rotator
    @AppStorage("rotatorAlpacaHost") private var rotatorAlpacaHost: String = "192.168.8.30"
    @AppStorage("rotatorAlpacaPort") private var rotatorAlpacaPort: Int = 11111

    // Switch
    @AppStorage("switchAlpacaHost") private var switchAlpacaHost: String = "192.168.8.30"
    @AppStorage("switchAlpacaPort") private var switchAlpacaPort: Int = 11111

    // Safety Monitor
    @AppStorage("safetyMonitorAlpacaHost") private var safetyMonitorAlpacaHost: String = "192.168.8.30"
    @AppStorage("safetyMonitorAlpacaPort") private var safetyMonitorAlpacaPort: Int = 11111

    // Observing Conditions
    @AppStorage("observingConditionsAlpacaHost") private var observingConditionsAlpacaHost: String = "192.168.8.30"
    @AppStorage("observingConditionsAlpacaPort") private var observingConditionsAlpacaPort: Int = 11111

    // Cover Calibrator
    @AppStorage("coverCalibratorAlpacaHost") private var coverCalibratorAlpacaHost: String = "192.168.8.30"
    @AppStorage("coverCalibratorAlpacaPort") private var coverCalibratorAlpacaPort: Int = 11111

    // Star catalog
    @AppStorage("starCatalogPath") private var starCatalogPath: String = ""
    @State private var catalogLoadError: String?
    @State private var isLoadingCatalog = false

    // Remote plate solving
    @AppStorage("astrometryNetApiKey") private var astrometryNetApiKey: String = ""
    @AppStorage("astrometryNetEnabled") private var astrometryNetEnabled: Bool = false
    @AppStorage("astrometryNetLocalMode") private var astrometryNetLocalMode: Bool = false
    @AppStorage("astrometryNetLocalURL") private var astrometryNetLocalURL: String = "http://localhost:8080/api"
    @State private var remoteTestStatus: String?
    @State private var isTestingRemote = false

    private var astrometryBaseURL: String {
        astrometryNetLocalMode ? astrometryNetLocalURL : AstrometryNetService.remoteBaseURL
    }

    // Auto-connect flags
    @AppStorage("autoConnectMount") private var autoConnectMount: Bool = false
    @AppStorage("autoConnectCamera") private var autoConnectCamera: Bool = false
    @AppStorage("autoConnectGuideCamera") private var autoConnectGuideCamera: Bool = false
    @AppStorage("autoConnectFilterWheel") private var autoConnectFilterWheel: Bool = false
    @AppStorage("autoConnectFocuser") private var autoConnectFocuser: Bool = false

    // Cooling
    @State private var coolerTarget: Int = -10

    // Capture
    @AppStorage("captureFolder") private var captureFolder: String = ""
    @AppStorage("captureFormat") private var captureFormat: String = "fits"
    @AppStorage("captureColorMode") private var captureColorMode: String = "rgb"
    @AppStorage("capturePrefix") private var capturePrefix: String = "capture"

    // AI Assistant
    @AppStorage("llmProvider") private var llmProviderRaw: String = LLMProvider.claude.rawValue
    @AppStorage("llmApiEndpoint") private var llmApiEndpoint: String = LLMProvider.claude.defaultEndpoint
    @AppStorage("llmApiKey") private var llmApiKey: String = ""
    @AppStorage("llmModel") private var llmModel: String = LLMProvider.claude.defaultModel
    @StateObject private var llmService = LLMService()

    enum MountProtocolChoice: String, CaseIterable {
        case lx200 = "LX200 Serial (USB)"
        case lx200tcp = "LX200 TCP/WiFi (AM5)"
        case alpaca = "ASCOM Alpaca (Wi-Fi)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Settings")
                    .font(.title)

                // MARK: - Mount Connection
                GroupBox("Mount Connection") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Protocol", selection: mountProtocolBinding) {
                            ForEach(MountProtocolChoice.allCases, id: \.self) { p in
                                Text(p.rawValue).tag(p)
                            }
                        }
                        .pickerStyle(.segmented)

                        if mountProtocol == .lx200 {
                            lx200Settings
                        } else if mountProtocol == .lx200tcp {
                            lx200TcpSettings
                        } else {
                            alpacaSettings
                        }

                        // Connection status
                        HStack {
                            Circle()
                                .fill(mountService.isConnected ? .green : .red)
                                .frame(width: 10, height: 10)
                            Text(mountService.isConnected
                                 ? "Connected (\(mountService.backendName ?? ""))"
                                 : "Not connected")
                                .foregroundStyle(.secondary)

                            Spacer()

                            if mountService.isConnected {
                                Button("Sync Clock") {
                                    syncMountTime()
                                }
                                .buttonStyle(.bordered)
                                .help("Send computer time and observer location to mount")

                                Button("Disconnect") {
                                    autoConnectMount = false
                                    Task {
                                        try? await mountService.disconnect()
                                    }
                                }
                                .buttonStyle(.bordered)
                            } else {
                                Button("Connect") {
                                    connectMount()
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(mountProtocol == .alpaca && mountService.selectedAlpacaDevice < 0)
                            }
                        }

                        if let err = mountError {
                            Text(err)
                                .foregroundStyle(.red)
                                .font(.caption)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // MARK: - Observer Location
                GroupBox("Observer Location") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Latitude")
                                .frame(width: 80, alignment: .trailing)
                            TextField("Latitude", value: $observerLat, format: .number.precision(.fractionLength(4)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                            Text("N")
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Longitude")
                                .frame(width: 80, alignment: .trailing)
                            TextField("Longitude", value: $observerLon, format: .number.precision(.fractionLength(4)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                            Text("E")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // MARK: - Telescope & Imaging
                GroupBox("Imaging Optics") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Focal Length")
                                .frame(width: 90, alignment: .trailing)
                            TextField("mm", value: $focalLengthMM, format: .number.precision(.fractionLength(0)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                            Text("mm")
                                .foregroundStyle(.secondary)
                        }
                        imagingOpticsSummary
                    }
                    .padding(.vertical, 4)
                }

                GroupBox("Guide Optics") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Focal Length")
                                .frame(width: 90, alignment: .trailing)
                            TextField("mm", value: $guideFocalLengthMM, format: .number.precision(.fractionLength(0)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                            Text("mm")
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Pixel Size")
                                .frame(width: 90, alignment: .trailing)
                            TextField("μm", value: $guidePixelSizeMicrons, format: .number.precision(.fractionLength(2)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                            Text("μm")
                                .foregroundStyle(.secondary)
                        }
                        guideOpticsSummary
                    }
                    .padding(.vertical, 4)
                }

                // MARK: - Star Catalog
                GroupBox("Star Catalog") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Database")
                                .frame(width: 80, alignment: .trailing)
                            TextField("Path to .rkyv database", text: $starCatalogPath)
                                .textFieldStyle(.roundedBorder)
                            Button("Browse...") {
                                browseCatalog()
                            }
                        }
                        if starCatalogPath.isEmpty {
                            Text("Select a tetra3 star catalog database (.rkyv)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 88)
                        }

                        HStack {
                            Button("Load") {
                                loadCatalog()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(starCatalogPath.isEmpty || isLoadingCatalog)

                            if isLoadingCatalog {
                                ProgressView()
                                    .controlSize(.small)
                            }

                            if plateSolveService.isLoaded {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text(plateSolveService.databaseInfo ?? "Loaded")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let err = catalogLoadError {
                            Text(err)
                                .foregroundStyle(.red)
                                .font(.caption)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // MARK: - Remote Plate Solving
                GroupBox("Plate Solving — Astrometry.net API") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Enable as fallback when local solve fails", isOn: $astrometryNetEnabled)

                        Toggle("Use local server (Watney / astrometry-api-lite)", isOn: $astrometryNetLocalMode)

                        if astrometryNetLocalMode {
                            HStack {
                                Text("Server URL")
                                    .frame(width: 90, alignment: .trailing)
                                TextField("http://localhost:8080/api", text: $astrometryNetLocalURL)
                                    .textFieldStyle(.roundedBorder)
                            }
                            Text("Run Watney locally — same API, no internet needed. Get Watney at github.com/Jusas/WatneyAstrometry (macOS binary available).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            HStack {
                                Text("API Key")
                                    .frame(width: 90, alignment: .trailing)
                                SecureField("nova.astrometry.net API key", text: $astrometryNetApiKey)
                                    .textFieldStyle(.roundedBorder)
                            }
                            Text("Free key at nova.astrometry.net → My Profile.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Button("Test Connection") {
                                Task {
                                    isTestingRemote = true
                                    remoteTestStatus = nil
                                    defer { isTestingRemote = false }
                                    do {
                                        let svc = AstrometryNetService(baseURL: astrometryBaseURL)
                                        try await svc.testLogin(apiKey: astrometryNetLocalMode ? "local" : astrometryNetApiKey)
                                        remoteTestStatus = "Connected"
                                    } catch {
                                        remoteTestStatus = error.localizedDescription
                                    }
                                }
                            }
                            .disabled((!astrometryNetLocalMode && astrometryNetApiKey.isEmpty) || isTestingRemote)

                            if isTestingRemote {
                                ProgressView().controlSize(.small)
                            }

                            if let status = remoteTestStatus {
                                Text(status)
                                    .font(.caption)
                                    .foregroundStyle(status == "Connected" ? .green : .red)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                // MARK: - Sky Imagery Cache
                GroupBox("Sky Imagery (DSS)") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Disk cache: \(String(format: "%.1f", dssTileService.cacheSizeMB)) MB")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Purge Cache") {
                                dssTileService.purgeCache()
                            }
                            .controlSize(.small)
                        }
                        Text("DSS2 sky imagery from STScI. Toggle on the sky map with the photo icon. Tiles are cached to disk for offline use.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                    .onAppear { dssTileService.updateCacheSize() }
                }

                // MARK: - Camera
                GroupBox("Camera") {
                    VStack(alignment: .leading, spacing: 8) {
                        // Camera source picker
                        Picker("Source", selection: $cameraSourceRaw) {
                            ForEach(CameraSource.allCases, id: \.rawValue) { source in
                                Text(source.rawValue).tag(source.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: cameraSourceRaw) {
                            if cameraViewModel.isConnected {
                                cameraViewModel.disconnect()
                            }
                        }

                        if cameraSourceRaw == CameraSource.usb.rawValue {
                            // USB camera selection
                            HStack {
                                Picker("Camera", selection: $selectedCameraIndex) {
                                    Text("No camera selected").tag(-1)
                                    ForEach(Array(discoveredCameras.enumerated()), id: \.offset) { index, cam in
                                        Text(cam.name).tag(index)
                                    }
                                }
                                .frame(maxWidth: 300)

                                Button(action: discoverCameras) {
                                    Image(systemName: "arrow.clockwise")
                                }
                                .disabled(isDiscoveringCameras)
                                .help("Scan for connected cameras")

                                if isDiscoveringCameras {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }

                            if let cam = selectedCamera {
                                Text("\(cam.maxWidth)x\(cam.maxHeight) \(cam.isColorCamera ? "Color" : "Mono") \(String(format: "%.1fμm", cam.pixelSize)) \(cam.isUSB3 ? "USB3" : "USB2")\(cam.hasCooler ? " Cooled" : "")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            // Alpaca camera host/port
                            HStack {
                                Text("Host")
                                    .frame(width: 40, alignment: .trailing)
                                TextField("IP address", text: $cameraAlpacaHost)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 160)
                                Text("Port")
                                TextField("Port", value: $cameraAlpacaPort, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 70)
                            }

                            // Alpaca camera picker
                            HStack {
                                Picker("Camera", selection: $cameraViewModel.selectedAlpacaDevice) {
                                    Text("No camera found").tag(-1)
                                    ForEach(Array(cameraViewModel.alpacaDevices.enumerated()), id: \.offset) { index, dev in
                                        Text("\(dev.deviceName) (#\(dev.deviceNumber))").tag(index)
                                    }
                                }
                                .frame(maxWidth: 300)

                                Button(action: discoverAlpacaCameras) {
                                    Image(systemName: "arrow.clockwise")
                                }
                                .disabled(cameraViewModel.isDiscoveringAlpacaDevices)
                                .help("Scan for cameras on the Alpaca server")

                                if cameraViewModel.isDiscoveringAlpacaDevices {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                        }

                        HStack {
                            if cameraViewModel.isConnected {
                                Circle()
                                    .fill(.green)
                                    .frame(width: 10, height: 10)
                                Text("Connected")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Disconnect") {
                                    autoConnectCamera = false
                                    cameraViewModel.disconnect()
                                }
                                .buttonStyle(.bordered)
                            } else {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 10, height: 10)
                                Text("Not connected")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Connect") {
                                    connectCamera()
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(
                                    cameraSourceRaw == CameraSource.usb.rawValue
                                        ? selectedCameraIndex < 0
                                        : cameraViewModel.selectedAlpacaDevice < 0
                                )
                            }
                        }

                        Divider()

                        // Sensor properties
                        HStack {
                            Text("Pixel Size")
                                .frame(width: 80, alignment: .trailing)
                            TextField("μm", value: $pixelSizeMicrons, format: .number.precision(.fractionLength(2)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                            Text("μm")
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Sensor")
                                .frame(width: 80, alignment: .trailing)
                            TextField("W", value: $sensorWidthPx, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                            Text("\u{00D7}")
                            TextField("H", value: $sensorHeightPx, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 60)
                            Text("px")
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Bayer")
                                .frame(width: 80, alignment: .trailing)
                            Picker("", selection: $bayerPattern) {
                                Text("RGGB").tag("RGGB")
                                Text("BGGR").tag("BGGR")
                                Text("GRBG").tag("GRBG")
                                Text("GBRG").tag("GBRG")
                                Text("Mono").tag("MONO")
                            }
                            .pickerStyle(.menu)
                            .frame(width: 90)
                        }
                        HStack {
                            Text("Flip")
                                .frame(width: 80, alignment: .trailing)
                            Toggle("Horizontal", isOn: $cameraFlipX)
                                .toggleStyle(.checkbox)
                            Toggle("Vertical", isOn: $cameraFlipY)
                                .toggleStyle(.checkbox)
                        }

                        Divider()

                        HStack {
                            Text("Exposure")
                                .frame(width: 80, alignment: .trailing)
                            TextField("ms", value: $exposureMs, format: .number.precision(.fractionLength(0)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                .multilineTextAlignment(.trailing)
                                .onSubmit { exposureMs = clampedExposure(exposureMs) }
                            Text("ms")
                                .foregroundStyle(.secondary)
                            Stepper("",
                                    onIncrement: { exposureMs = clampedExposure((exposureMs * 1.1).rounded()) },
                                    onDecrement: { exposureMs = clampedExposure((exposureMs / 1.1).rounded()) })
                                .labelsHidden()
                            if exposureMs >= 1000 {
                                Text(String(format: "(%.1f s)", exposureMs / 1000))
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        HStack {
                            Text("Gain")
                                .frame(width: 80, alignment: .trailing)
                            Slider(value: $gain, in: 0...500, step: 10)
                            Text(String(format: "%.0f", gain))
                                .frame(width: 60)
                                .font(.system(.body, design: .monospaced))
                        }
                        HStack {
                            Text("Binning")
                                .frame(width: 80, alignment: .trailing)
                            Picker("", selection: $binning) {
                                if let cam = selectedCamera {
                                    ForEach(cam.supportedBins, id: \.self) { b in
                                        Text("\(b)x\(b) (\(cam.maxWidth / b)x\(cam.maxHeight / b))").tag(b)
                                    }
                                } else {
                                    Text("1x1").tag(1)
                                    Text("2x2").tag(2)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }

                        // Sensor Cooling
                        if cameraViewModel.hasCooler && cameraViewModel.isConnected {
                            Divider()

                            Text("Sensor Cooling")
                                .font(.headline)

                            HStack {
                                Text("Sensor")
                                    .frame(width: 80, alignment: .trailing)
                                if let temp = cameraViewModel.sensorTempC {
                                    Text(String(format: "%.1f °C", temp))
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundStyle(temp <= Double(coolerTarget + 2) && cameraViewModel.coolerEnabled ? .green : .primary)
                                } else {
                                    Text("--")
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()

                                if let power = cameraViewModel.coolerPowerPercent, cameraViewModel.coolerEnabled {
                                    Text("Power: \(power)%")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(power > 90 ? .red : .secondary)
                                }
                            }

                            HStack {
                                Text("Target")
                                    .frame(width: 80, alignment: .trailing)
                                TextField("°C", value: $coolerTarget, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 60)
                                    .multilineTextAlignment(.trailing)
                                Text("°C")
                                    .foregroundStyle(.secondary)
                                Stepper("", value: $coolerTarget, in: -40...30)
                                    .labelsHidden()
                            }

                            HStack(spacing: 12) {
                                Spacer().frame(width: 80)

                                if cameraViewModel.coolerEnabled {
                                    Button("Turn Off") {
                                        cameraViewModel.setCoolerOff()
                                    }
                                    .buttonStyle(.bordered)

                                    Button("Warmup") {
                                        cameraViewModel.warmup()
                                    }
                                    .buttonStyle(.bordered)
                                    .help("Gradually raise to ambient temperature before disconnecting")
                                } else {
                                    Button("Cool to \(coolerTarget)°C") {
                                        cameraViewModel.setCoolerOn(targetCelsius: coolerTarget)
                                    }
                                    .buttonStyle(.borderedProminent)
                                }

                                if cameraViewModel.coolerEnabled {
                                    if let target = cameraViewModel.coolerTargetC {
                                        Text("Target: \(target)°C")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                // MARK: - Guide Camera
                GroupBox("Guide Camera") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Source", selection: $guideCameraSourceRaw) {
                            ForEach(CameraSource.allCases, id: \.rawValue) { source in
                                Text(source.rawValue).tag(source.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: guideCameraSourceRaw) {
                            if guideCameraViewModel.isConnected {
                                guideCameraViewModel.disconnect()
                            }
                        }

                        if guideCameraSourceRaw == CameraSource.usb.rawValue {
                            HStack {
                                Picker("Camera", selection: $guideSelectedCameraIndex) {
                                    Text("No camera selected").tag(-1)
                                    ForEach(Array(guideDiscoveredCameras.enumerated()), id: \.offset) { index, cam in
                                        Text(cam.name).tag(index)
                                    }
                                }
                                .frame(maxWidth: 300)

                                Button(action: discoverGuideCameras) {
                                    Image(systemName: "arrow.clockwise")
                                }
                                .disabled(isDiscoveringGuideCameras)
                                .help("Scan for connected cameras")

                                if isDiscoveringGuideCameras {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }

                            if let cam = selectedGuideCamera {
                                Text("\(cam.maxWidth)x\(cam.maxHeight) \(cam.isColorCamera ? "Color" : "Mono") \(String(format: "%.1fμm", cam.pixelSize)) \(cam.isUSB3 ? "USB3" : "USB2")\(cam.hasCooler ? " Cooled" : "")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            HStack {
                                Text("Host")
                                    .frame(width: 40, alignment: .trailing)
                                TextField("IP address", text: $guideCameraAlpacaHost)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 160)
                                Text("Port")
                                TextField("Port", value: $guideCameraAlpacaPort, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 70)
                            }

                            HStack {
                                Picker("Camera", selection: $guideCameraViewModel.selectedAlpacaDevice) {
                                    Text("No camera found").tag(-1)
                                    ForEach(Array(guideCameraViewModel.alpacaDevices.enumerated()), id: \.offset) { index, dev in
                                        Text("\(dev.deviceName) (#\(dev.deviceNumber))").tag(index)
                                    }
                                }
                                .frame(maxWidth: 300)

                                Button(action: discoverGuideAlpacaCameras) {
                                    Image(systemName: "arrow.clockwise")
                                }
                                .disabled(guideCameraViewModel.isDiscoveringAlpacaDevices)
                                .help("Scan for cameras on the Alpaca server")

                                if guideCameraViewModel.isDiscoveringAlpacaDevices {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                        }

                        HStack {
                            if guideCameraViewModel.isConnected {
                                Circle()
                                    .fill(.green)
                                    .frame(width: 10, height: 10)
                                Text("Connected")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Disconnect") {
                                    autoConnectGuideCamera = false
                                    guideCameraViewModel.disconnect()
                                }
                                .buttonStyle(.bordered)
                            } else {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 10, height: 10)
                                Text("Not connected")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Connect") {
                                    connectGuideCamera()
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(
                                    guideCameraSourceRaw == CameraSource.usb.rawValue
                                        ? guideSelectedCameraIndex < 0
                                        : guideCameraViewModel.selectedAlpacaDevice < 0
                                )
                            }
                        }

                        Divider()

                        HStack {
                            Text("Exposure")
                                .frame(width: 80, alignment: .trailing)
                            TextField("ms", value: $guideExposureMs, format: .number.precision(.fractionLength(0)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                .multilineTextAlignment(.trailing)
                                .onSubmit { guideExposureMs = clampedExposure(guideExposureMs) }
                            Text("ms")
                                .foregroundStyle(.secondary)
                            Stepper("",
                                    onIncrement: { guideExposureMs = clampedExposure((guideExposureMs * 1.1).rounded()) },
                                    onDecrement: { guideExposureMs = clampedExposure((guideExposureMs / 1.1).rounded()) })
                                .labelsHidden()
                            if guideExposureMs >= 1000 {
                                Text(String(format: "(%.1f s)", guideExposureMs / 1000))
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        HStack {
                            Text("Gain")
                                .frame(width: 80, alignment: .trailing)
                            Slider(value: $guideGain, in: 0...500, step: 10)
                            Text(String(format: "%.0f", guideGain))
                                .frame(width: 60)
                                .font(.system(.body, design: .monospaced))
                        }
                        HStack {
                            Text("Binning")
                                .frame(width: 80, alignment: .trailing)
                            Picker("", selection: $guideBinning) {
                                if let cam = selectedGuideCamera {
                                    ForEach(cam.supportedBins, id: \.self) { b in
                                        Text("\(b)x\(b) (\(cam.maxWidth / b)x\(cam.maxHeight / b))").tag(b)
                                    }
                                } else {
                                    Text("1x1").tag(1)
                                    Text("2x2").tag(2)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }

                        HStack {
                            Text("Prefix")
                                .frame(width: 80, alignment: .trailing)
                            TextField("File prefix", text: $guideCapturePrefix)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 160)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // MARK: - Filter Wheel
                GroupBox("Filter Wheel") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Host")
                                .frame(width: 40, alignment: .trailing)
                            TextField("IP address", text: $filterWheelAlpacaHost)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 160)
                            Text("Port")
                            TextField("Port", value: $filterWheelAlpacaPort, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)
                        }

                        HStack {
                            Picker("Device", selection: $filterWheelViewModel.selectedAlpacaDevice) {
                                Text("No filter wheel found").tag(-1)
                                ForEach(Array(filterWheelViewModel.alpacaDevices.enumerated()), id: \.offset) { index, dev in
                                    Text("\(dev.deviceName) (#\(dev.deviceNumber))").tag(index)
                                }
                            }
                            .frame(maxWidth: 300)

                            Button(action: discoverFilterWheels) {
                                Image(systemName: "arrow.clockwise")
                            }
                            .disabled(filterWheelViewModel.isDiscoveringDevices)
                            .help("Scan for filter wheels on the Alpaca server")

                            if filterWheelViewModel.isDiscoveringDevices {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }

                        HStack {
                            if filterWheelViewModel.isConnected {
                                Circle()
                                    .fill(.green)
                                    .frame(width: 10, height: 10)
                                Text(filterWheelViewModel.statusMessage)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Disconnect") {
                                    autoConnectFilterWheel = false
                                    filterWheelViewModel.disconnect()
                                }
                                .buttonStyle(.bordered)
                            } else {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 10, height: 10)
                                Text("Not connected")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Connect") {
                                    connectFilterWheel()
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(filterWheelViewModel.selectedAlpacaDevice < 0)
                            }
                        }

                        if filterWheelViewModel.isConnected {
                            Divider()

                            HStack {
                                Text("Filter")
                                    .frame(width: 80, alignment: .trailing)

                                if filterWheelViewModel.filterNames.isEmpty {
                                    Text("Slot \(filterWheelViewModel.currentPosition >= 0 ? "\(filterWheelViewModel.currentPosition)" : "?")")
                                        .font(.system(.body, design: .monospaced))
                                } else {
                                    Picker("", selection: Binding(
                                        get: { filterWheelViewModel.currentPosition },
                                        set: { filterWheelViewModel.selectFilter(position: $0) }
                                    )) {
                                        ForEach(Array(filterWheelViewModel.filterNames.enumerated()), id: \.offset) { index, name in
                                            let label = name.isEmpty ? "Slot \(index)" : "\(index): \(name)"
                                            Text(label).tag(index)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(maxWidth: 250)
                                }

                                if filterWheelViewModel.isMoving {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Moving...")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Text("\(filterWheelViewModel.filterNames.count) slots, position: \(filterWheelViewModel.currentPosition)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 88)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // MARK: - Focuser
                alpacaDeviceSection(
                    title: "Focuser",
                    host: $focuserAlpacaHost,
                    port: $focuserAlpacaPort,
                    devices: focuserViewModel.alpacaDevices,
                    selectedDevice: $focuserViewModel.selectedAlpacaDevice,
                    isDiscovering: focuserViewModel.isDiscoveringDevices,
                    isConnected: focuserViewModel.isConnected,
                    statusMessage: focuserViewModel.statusMessage,
                    onDiscover: { focuserViewModel.discoverDevices(host: focuserAlpacaHost, port: UInt32(focuserAlpacaPort)) },
                    onConnect: {
                        let idx = focuserViewModel.selectedAlpacaDevice
                        let devNum: UInt32 = (idx >= 0 && idx < focuserViewModel.alpacaDevices.count)
                            ? focuserViewModel.alpacaDevices[idx].deviceNumber : 0
                        focuserViewModel.connect(host: focuserAlpacaHost, port: UInt32(focuserAlpacaPort), deviceNumber: devNum)
                        autoConnectFocuser = true
                    },
                    onDisconnect: {
                        focuserViewModel.disconnect()
                        autoConnectFocuser = false
                    }
                )

                // MARK: - Rotator
                alpacaDeviceSection(
                    title: "Rotator",
                    host: $rotatorAlpacaHost,
                    port: $rotatorAlpacaPort,
                    devices: rotatorViewModel.alpacaDevices,
                    selectedDevice: $rotatorViewModel.selectedAlpacaDevice,
                    isDiscovering: rotatorViewModel.isDiscoveringDevices,
                    isConnected: rotatorViewModel.isConnected,
                    statusMessage: rotatorViewModel.statusMessage,
                    onDiscover: { rotatorViewModel.discoverDevices(host: rotatorAlpacaHost, port: UInt32(rotatorAlpacaPort)) },
                    onConnect: {
                        let idx = rotatorViewModel.selectedAlpacaDevice
                        let devNum: UInt32 = (idx >= 0 && idx < rotatorViewModel.alpacaDevices.count)
                            ? rotatorViewModel.alpacaDevices[idx].deviceNumber : 0
                        rotatorViewModel.connect(host: rotatorAlpacaHost, port: UInt32(rotatorAlpacaPort), deviceNumber: devNum)
                    },
                    onDisconnect: { rotatorViewModel.disconnect() }
                )

                // MARK: - Dome
                alpacaDeviceSection(
                    title: "Dome",
                    host: $domeAlpacaHost,
                    port: $domeAlpacaPort,
                    devices: domeViewModel.alpacaDevices,
                    selectedDevice: $domeViewModel.selectedAlpacaDevice,
                    isDiscovering: domeViewModel.isDiscoveringDevices,
                    isConnected: domeViewModel.isConnected,
                    statusMessage: domeViewModel.statusMessage,
                    onDiscover: { domeViewModel.discoverDevices(host: domeAlpacaHost, port: UInt32(domeAlpacaPort)) },
                    onConnect: {
                        let idx = domeViewModel.selectedAlpacaDevice
                        let devNum: UInt32 = (idx >= 0 && idx < domeViewModel.alpacaDevices.count)
                            ? domeViewModel.alpacaDevices[idx].deviceNumber : 0
                        domeViewModel.connect(host: domeAlpacaHost, port: UInt32(domeAlpacaPort), deviceNumber: devNum)
                    },
                    onDisconnect: { domeViewModel.disconnect() }
                )

                // MARK: - Switch
                alpacaDeviceSection(
                    title: "Switch",
                    host: $switchAlpacaHost,
                    port: $switchAlpacaPort,
                    devices: switchViewModel.alpacaDevices,
                    selectedDevice: $switchViewModel.selectedAlpacaDevice,
                    isDiscovering: switchViewModel.isDiscoveringDevices,
                    isConnected: switchViewModel.isConnected,
                    statusMessage: switchViewModel.statusMessage,
                    onDiscover: { switchViewModel.discoverDevices(host: switchAlpacaHost, port: UInt32(switchAlpacaPort)) },
                    onConnect: {
                        let idx = switchViewModel.selectedAlpacaDevice
                        let devNum: UInt32 = (idx >= 0 && idx < switchViewModel.alpacaDevices.count)
                            ? switchViewModel.alpacaDevices[idx].deviceNumber : 0
                        switchViewModel.connect(host: switchAlpacaHost, port: UInt32(switchAlpacaPort), deviceNumber: devNum)
                    },
                    onDisconnect: { switchViewModel.disconnect() }
                )

                // MARK: - Safety Monitor
                alpacaDeviceSection(
                    title: "Safety Monitor",
                    host: $safetyMonitorAlpacaHost,
                    port: $safetyMonitorAlpacaPort,
                    devices: safetyMonitorViewModel.alpacaDevices,
                    selectedDevice: $safetyMonitorViewModel.selectedAlpacaDevice,
                    isDiscovering: safetyMonitorViewModel.isDiscoveringDevices,
                    isConnected: safetyMonitorViewModel.isConnected,
                    statusMessage: safetyMonitorViewModel.statusMessage,
                    onDiscover: { safetyMonitorViewModel.discoverDevices(host: safetyMonitorAlpacaHost, port: UInt32(safetyMonitorAlpacaPort)) },
                    onConnect: {
                        let idx = safetyMonitorViewModel.selectedAlpacaDevice
                        let devNum: UInt32 = (idx >= 0 && idx < safetyMonitorViewModel.alpacaDevices.count)
                            ? safetyMonitorViewModel.alpacaDevices[idx].deviceNumber : 0
                        safetyMonitorViewModel.connect(host: safetyMonitorAlpacaHost, port: UInt32(safetyMonitorAlpacaPort), deviceNumber: devNum)
                    },
                    onDisconnect: { safetyMonitorViewModel.disconnect() }
                )

                // MARK: - Observing Conditions
                alpacaDeviceSection(
                    title: "Observing Conditions",
                    host: $observingConditionsAlpacaHost,
                    port: $observingConditionsAlpacaPort,
                    devices: observingConditionsViewModel.alpacaDevices,
                    selectedDevice: $observingConditionsViewModel.selectedAlpacaDevice,
                    isDiscovering: observingConditionsViewModel.isDiscoveringDevices,
                    isConnected: observingConditionsViewModel.isConnected,
                    statusMessage: observingConditionsViewModel.statusMessage,
                    onDiscover: { observingConditionsViewModel.discoverDevices(host: observingConditionsAlpacaHost, port: UInt32(observingConditionsAlpacaPort)) },
                    onConnect: {
                        let idx = observingConditionsViewModel.selectedAlpacaDevice
                        let devNum: UInt32 = (idx >= 0 && idx < observingConditionsViewModel.alpacaDevices.count)
                            ? observingConditionsViewModel.alpacaDevices[idx].deviceNumber : 0
                        observingConditionsViewModel.connect(host: observingConditionsAlpacaHost, port: UInt32(observingConditionsAlpacaPort), deviceNumber: devNum)
                    },
                    onDisconnect: { observingConditionsViewModel.disconnect() }
                )

                // MARK: - Cover Calibrator
                alpacaDeviceSection(
                    title: "Cover Calibrator",
                    host: $coverCalibratorAlpacaHost,
                    port: $coverCalibratorAlpacaPort,
                    devices: coverCalibratorViewModel.alpacaDevices,
                    selectedDevice: $coverCalibratorViewModel.selectedAlpacaDevice,
                    isDiscovering: coverCalibratorViewModel.isDiscoveringDevices,
                    isConnected: coverCalibratorViewModel.isConnected,
                    statusMessage: coverCalibratorViewModel.statusMessage,
                    onDiscover: { coverCalibratorViewModel.discoverDevices(host: coverCalibratorAlpacaHost, port: UInt32(coverCalibratorAlpacaPort)) },
                    onConnect: {
                        let idx = coverCalibratorViewModel.selectedAlpacaDevice
                        let devNum: UInt32 = (idx >= 0 && idx < coverCalibratorViewModel.alpacaDevices.count)
                            ? coverCalibratorViewModel.alpacaDevices[idx].deviceNumber : 0
                        coverCalibratorViewModel.connect(host: coverCalibratorAlpacaHost, port: UInt32(coverCalibratorAlpacaPort), deviceNumber: devNum)
                    },
                    onDisconnect: { coverCalibratorViewModel.disconnect() }
                )

                // MARK: - Capture Output
                GroupBox("Capture Output") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Folder")
                                .frame(width: 80, alignment: .trailing)
                            TextField("Capture folder", text: $captureFolder)
                                .textFieldStyle(.roundedBorder)
                            Button("Browse...") {
                                browseFolder()
                            }
                        }
                        if captureFolder.isEmpty {
                            Text("Default: ~/Pictures/PolarStation/")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 88)
                        }

                        HStack {
                            Text("Format")
                                .frame(width: 80, alignment: .trailing)
                            Picker("", selection: $captureFormat) {
                                Text("FITS").tag("fits")
                                Text("TIFF").tag("tiff")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(maxWidth: 200)
                        }

                        if selectedCamera?.isColorCamera == true {
                            HStack {
                                Text("Color")
                                    .frame(width: 80, alignment: .trailing)
                                Picker("", selection: $captureColorMode) {
                                    Text("RGB").tag("rgb")
                                    Text("Luminance").tag("luminance")
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .frame(maxWidth: 200)
                            }
                        }

                        HStack {
                            Text("Prefix")
                                .frame(width: 80, alignment: .trailing)
                            TextField("File prefix", text: $capturePrefix)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 160)
                            Text("e.g. \(capturePrefix.isEmpty ? "capture" : capturePrefix)_20260311_214530_001.\(captureFormat)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // MARK: - Info
                // MARK: - AI Assistant
                GroupBox("AI Assistant") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Provider", selection: Binding(
                            get: { LLMProvider(rawValue: llmProviderRaw) ?? .claude },
                            set: { newProvider in
                                llmProviderRaw = newProvider.rawValue
                                llmApiEndpoint = newProvider.defaultEndpoint
                                llmModel = newProvider.defaultModel
                                llmService.connectionStatus = .notConfigured
                            }
                        )) {
                            ForEach(LLMProvider.allCases) { provider in
                                Text(provider.rawValue).tag(provider)
                            }
                        }
                        .frame(maxWidth: 300)

                        HStack {
                            Text("Endpoint")
                                .frame(width: 60, alignment: .trailing)
                            TextField("API endpoint URL", text: $llmApiEndpoint)
                                .textFieldStyle(.roundedBorder)
                        }

                        HStack {
                            Text("API Key")
                                .frame(width: 60, alignment: .trailing)
                            SecureField("API key", text: $llmApiKey)
                                .textFieldStyle(.roundedBorder)
                        }

                        HStack {
                            Text("Model")
                                .frame(width: 60, alignment: .trailing)
                            TextField("Model name", text: $llmModel)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 300)
                        }

                        HStack {
                            Button("Test Connection") {
                                let provider = LLMProvider(rawValue: llmProviderRaw) ?? .claude
                                let endpoint = llmApiEndpoint.isEmpty ? provider.defaultEndpoint : llmApiEndpoint
                                let model = llmModel.isEmpty ? provider.defaultModel : llmModel
                                let key = llmApiKey
                                llmService.isTestingConnection = true
                                Task {
                                    let status = await llmService.testConnection(
                                        provider: provider,
                                        endpoint: endpoint,
                                        apiKey: key,
                                        model: model
                                    )
                                    llmService.connectionStatus = status
                                    llmService.isTestingConnection = false
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(llmService.isTestingConnection || llmApiKey.isEmpty)

                            if llmService.isTestingConnection {
                                ProgressView()
                                    .controlSize(.small)
                            }

                            Spacer()

                            Circle()
                                .fill(llmStatusColor)
                                .frame(width: 10, height: 10)
                            Text(llmStatusLabel)
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }

                        // Show full error message below button row
                        if case .failed(let msg) = llmService.connectionStatus {
                            Text(msg)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(.red.opacity(0.08))
                                .cornerRadius(6)
                        }
                    }
                    .padding(.vertical, 4)
                }

                GroupBox("About") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PolarCore v\(PolarCore.polarCoreVersion())")
                        Text("Database: \(plateSolveService.databaseInfo ?? "Not loaded")")
                            .foregroundStyle(.secondary)
                        Text("Sky imagery: Digitized Sky Survey (DSS2)")
                            .foregroundStyle(.secondary)
                        Text("The Digitized Sky Surveys were produced at the Space Telescope Science Institute under U.S. Government grant NAG W-2166. Images based on photographic data from the UK Schmidt Telescope (copyright \u{00A9} Royal Observatory Edinburgh) and Palomar Observatory (copyright \u{00A9} California Institute of Technology).")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .padding(.vertical, 4)
                }
            }
            .padding()
        }
        .frame(minWidth: 400)
        .onAppear {
            refreshPorts()
            discoverCameras()
            discoverGuideCameras()
            syncLocationToCoordinator()
            applyBayerPattern()
            applyCameraFlip()
        }
        .onChange(of: observerLat) { syncLocationToCoordinator() }
        .onChange(of: observerLon) { syncLocationToCoordinator() }
        .onChange(of: focalLengthMM) {
            plateSolveService.setFOV(focalLengthMM: focalLengthMM, sensorWidthMM: pixelSizeMicrons * Double(sensorWidthPx) / 1000.0)
        }
        .onChange(of: selectedCameraIndex) {
            if let cam = selectedCamera {
                pixelSizeMicrons = cam.pixelSize
                sensorWidthPx = Int(cam.maxWidth)
                sensorHeightPx = Int(cam.maxHeight)
                if !cam.isColorCamera {
                    bayerPattern = "MONO"
                } else {
                    switch cam.bayerPattern {
                    case .rg: bayerPattern = "RGGB"
                    case .bg: bayerPattern = "BGGR"
                    case .gr: bayerPattern = "GRBG"
                    case .gb: bayerPattern = "GBRG"
                    }
                }
                applyBayerPattern()
            }
        }
        .onChange(of: cameraViewModel.isConnected) {
            if cameraViewModel.isConnected, let cam = cameraViewModel.selectedCamera {
                pixelSizeMicrons = cam.pixelSize
                sensorWidthPx = Int(cam.maxWidth)
                sensorHeightPx = Int(cam.maxHeight)
                if !cam.isColorCamera {
                    bayerPattern = "MONO"
                } else {
                    switch cam.bayerPattern {
                    case .rg: bayerPattern = "RGGB"
                    case .bg: bayerPattern = "BGGR"
                    case .gr: bayerPattern = "GRBG"
                    case .gb: bayerPattern = "GBRG"
                    }
                }
                applyBayerPattern()
            }
        }
        .onChange(of: guideSelectedCameraIndex) {
            if let cam = selectedGuideCamera {
                guidePixelSizeMicrons = cam.pixelSize
            }
        }
        .onChange(of: bayerPattern) {
            applyBayerPattern()
        }
        .onChange(of: cameraFlipX) {
            applyCameraFlip()
        }
        .onChange(of: cameraFlipY) {
            applyCameraFlip()
        }
    }

    private func applyBayerPattern() {
        let (ox, oy): (UInt32, UInt32) = switch bayerPattern {
        case "BGGR": (1, 1)
        case "GRBG": (1, 0)
        case "GBRG": (0, 1)
        default:     (0, 0)  // RGGB or MONO
        }
        cameraViewModel.previewViewModel.bayerOffsetX = ox
        cameraViewModel.previewViewModel.bayerOffsetY = oy
    }

    private func applyCameraFlip() {
        cameraViewModel.previewViewModel.flipX = cameraFlipX
        cameraViewModel.previewViewModel.flipY = cameraFlipY
    }

    // MARK: - LX200 settings

    private var lx200Settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Serial Port", selection: $serialPort) {
                    Text("Select...").tag("")
                    ForEach(availablePorts, id: \.self) { port in
                        Text(port).tag(port)
                    }
                }
                .frame(maxWidth: 300)

                Button(action: refreshPorts) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh serial ports")
            }

            Picker("Baud Rate", selection: $baudRateStored) {
                Text("9600").tag(9600)
                Text("19200").tag(19200)
                Text("38400").tag(38400)
                Text("115200").tag(115200)
            }
            .frame(maxWidth: 200)
        }
    }

    // MARK: - LX200 TCP/WiFi settings

    private var lx200TcpSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Host")
                    .frame(width: 40, alignment: .trailing)
                TextField("IP address", text: $lx200TcpHost)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                Text("Port")
                TextField("Port", value: $lx200TcpPortStored, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
            }

            Text("AM5 WiFi default: 192.168.4.1:4030")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Alpaca settings

    private var alpacaSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Host")
                    .frame(width: 40, alignment: .trailing)
                TextField("IP address", text: $alpacaHost)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                Text("Port")
                TextField("Port", value: $alpacaPortStored, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
            }

            HStack {
                Picker("Device", selection: $mountService.selectedAlpacaDevice) {
                    Text("No mount found").tag(-1)
                    ForEach(Array(mountService.alpacaDevices.enumerated()), id: \.offset) { index, dev in
                        Text("\(dev.deviceName) (#\(dev.deviceNumber))").tag(index)
                    }
                }
                .frame(maxWidth: 300)

                Button(action: discoverAlpacaMounts) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(mountService.isDiscoveringDevices)
                .help("Scan for mounts on the Alpaca server")

                if mountService.isDiscoveringDevices {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Helpers

    private var selectedCamera: ASICameraInfo? {
        guard selectedCameraIndex >= 0, selectedCameraIndex < discoveredCameras.count else { return nil }
        return discoveredCameras[selectedCameraIndex]
    }

    private var selectedGuideCamera: ASICameraInfo? {
        guard guideSelectedCameraIndex >= 0, guideSelectedCameraIndex < guideDiscoveredCameras.count else { return nil }
        return guideDiscoveredCameras[guideSelectedCameraIndex]
    }

    private var imagingOpticsSummary: some View {
        let arcsecPerPix = pixelSizeMicrons * 206.265 / focalLengthMM
        let effectiveArcsec = arcsecPerPix * Double(binning)
        let imageWidth = sensorWidthPx / binning
        let imageHeight = sensorHeightPx / binning
        let sensorW = pixelSizeMicrons * Double(sensorWidthPx) / 1000.0
        let sensorH = pixelSizeMicrons * Double(sensorHeightPx) / 1000.0
        let fovW = effectiveArcsec * Double(imageWidth) / 3600.0
        let fovH = effectiveArcsec * Double(imageHeight) / 3600.0
        return VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "%.2f\u{2033}/px (%.2f\u{2033}/px at %dx bin)", arcsecPerPix, effectiveArcsec, binning))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(String(format: "FOV: %.2f\u{00B0} \u{00D7} %.2f\u{00B0} (%dx%d px)", fovW, fovH, imageWidth, imageHeight))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(String(format: "Sensor: %.1f \u{00D7} %.1f mm", sensorW, sensorH))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var guideOpticsSummary: some View {
        let arcsecPerPix = guidePixelSizeMicrons * 206.265 / guideFocalLengthMM
        let effectiveArcsec = arcsecPerPix * Double(guideBinning)
        return Text(String(format: "%.2f\u{2033}/px (%.2f\u{2033}/px at %dx bin)", arcsecPerPix, effectiveArcsec, guideBinning))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var llmStatusColor: Color {
        switch llmService.connectionStatus {
        case .notConfigured: return .gray
        case .connected: return .green
        case .failed: return .red
        }
    }

    private var llmStatusLabel: String {
        switch llmService.connectionStatus {
        case .notConfigured: return "Not configured"
        case .connected: return "Connected"
        case .failed: return "Failed"
        }
    }

    /// Clamp exposure to valid range: 1 ms – 600,000 ms (10 min).
    private func clampedExposure(_ value: Double) -> Double {
        max(1, min(value, 600_000))
    }

    // MARK: - Actions

    private func connectCamera() {
        if cameraSourceRaw == CameraSource.alpaca.rawValue {
            cameraViewModel.cameraSource = .alpaca
            cameraViewModel.alpacaHost = cameraAlpacaHost
            cameraViewModel.alpacaPort = UInt32(cameraAlpacaPort)
            // Pass selected device number
            let idx = cameraViewModel.selectedAlpacaDevice
            if idx >= 0, idx < cameraViewModel.alpacaDevices.count {
                cameraViewModel.alpacaDeviceNumber = cameraViewModel.alpacaDevices[idx].deviceNumber
            } else {
                cameraViewModel.alpacaDeviceNumber = 0
            }
            cameraViewModel.connect()
        } else {
            cameraViewModel.cameraSource = .usb
            cameraViewModel.discoveredCameras = discoveredCameras
            cameraViewModel.selectedCameraIndex = selectedCameraIndex
            cameraViewModel.connect()
        }
        autoConnectCamera = true
    }

    private func connectGuideCamera() {
        if guideCameraSourceRaw == CameraSource.alpaca.rawValue {
            guideCameraViewModel.cameraSource = .alpaca
            guideCameraViewModel.alpacaHost = guideCameraAlpacaHost
            guideCameraViewModel.alpacaPort = UInt32(guideCameraAlpacaPort)
            let idx = guideCameraViewModel.selectedAlpacaDevice
            if idx >= 0, idx < guideCameraViewModel.alpacaDevices.count {
                guideCameraViewModel.alpacaDeviceNumber = guideCameraViewModel.alpacaDevices[idx].deviceNumber
            } else {
                guideCameraViewModel.alpacaDeviceNumber = 0
            }
            guideCameraViewModel.connect()
        } else {
            guideCameraViewModel.cameraSource = .usb
            guideCameraViewModel.discoveredCameras = guideDiscoveredCameras
            guideCameraViewModel.selectedCameraIndex = guideSelectedCameraIndex
            guideCameraViewModel.connect()
        }
        autoConnectGuideCamera = true
    }

    private func discoverGuideAlpacaCameras() {
        guideCameraViewModel.discoverAlpacaCameras(host: guideCameraAlpacaHost, port: UInt32(guideCameraAlpacaPort))
    }

    private func discoverGuideCameras() {
        isDiscoveringGuideCameras = true
        DispatchQueue.global(qos: .userInitiated).async {
            var cameras = (try? ASICameraBridge.listCameras()) ?? []
            // Deduplicate by camera ID (ASI SDK can return same camera twice)
            var seen = Set<Int32>()
            cameras = cameras.filter { seen.insert($0.cameraID).inserted }
            DispatchQueue.main.async {
                guideDiscoveredCameras = cameras
                if guideSelectedCameraIndex < 0, !cameras.isEmpty {
                    guideSelectedCameraIndex = 0
                }
                isDiscoveringGuideCameras = false
            }
        }
    }

    private func discoverFilterWheels() {
        filterWheelViewModel.discoverDevices(host: filterWheelAlpacaHost, port: UInt32(filterWheelAlpacaPort))
    }

    private func connectFilterWheel() {
        let idx = filterWheelViewModel.selectedAlpacaDevice
        let deviceNumber: UInt32
        if idx >= 0, idx < filterWheelViewModel.alpacaDevices.count {
            deviceNumber = filterWheelViewModel.alpacaDevices[idx].deviceNumber
        } else {
            deviceNumber = 0
        }
        filterWheelViewModel.connect(
            host: filterWheelAlpacaHost,
            port: UInt32(filterWheelAlpacaPort),
            deviceNumber: deviceNumber
        )
        autoConnectFilterWheel = true
    }

    private func discoverAlpacaCameras() {
        cameraViewModel.discoverAlpacaCameras(host: cameraAlpacaHost, port: UInt32(cameraAlpacaPort))
    }

    private func discoverCameras() {
        isDiscoveringCameras = true
        DispatchQueue.global(qos: .userInitiated).async {
            let cameras = (try? ASICameraBridge.listCameras()) ?? []
            DispatchQueue.main.async {
                discoveredCameras = cameras
                if selectedCameraIndex < 0, !cameras.isEmpty {
                    selectedCameraIndex = 0
                }
                isDiscoveringCameras = false
            }
        }
    }

    private func refreshPorts() {
        availablePorts = mountService.serialPorts()
        if serialPort.isEmpty, let first = availablePorts.first {
            serialPort = first
        }
    }

    private func discoverAlpacaMounts() {
        mountService.discoverMounts(host: alpacaHost, port: alpacaPort)
    }

    private func connectMount() {
        mountError = nil
        Task {
            do {
                switch mountProtocol {
                case .lx200:
                    guard !serialPort.isEmpty else {
                        mountError = "Select a serial port"
                        return
                    }
                    try await mountService.connectLx200(devicePath: serialPort, baudRate: baudRate)
                case .lx200tcp:
                    try await mountService.connectLx200Tcp(host: lx200TcpHost, port: lx200TcpPort)
                case .alpaca:
                    let idx = mountService.selectedAlpacaDevice
                    let deviceNumber: UInt32
                    if idx >= 0, idx < mountService.alpacaDevices.count {
                        deviceNumber = mountService.alpacaDevices[idx].deviceNumber
                    } else {
                        deviceNumber = 0
                    }
                    try await mountService.connectAlpaca(host: alpacaHost, port: alpacaPort, deviceNumber: deviceNumber)
                }
                autoConnectMount = true
            } catch {
                mountError = error.localizedDescription
            }
        }
    }

    private func browseCatalog() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data]
        panel.prompt = "Select Star Catalog"
        panel.message = "Choose a tetra3 star catalog database (.rkyv file)"
        if panel.runModal() == .OK, let url = panel.url {
            starCatalogPath = url.path
            loadCatalog()
        }
    }

    private func loadCatalog() {
        guard !starCatalogPath.isEmpty else { return }
        catalogLoadError = nil
        isLoadingCatalog = true
        Task {
            do {
                try await plateSolveService.loadDatabase(from: starCatalogPath)
                catalogLoadError = nil
            } catch {
                catalogLoadError = error.localizedDescription
            }
            isLoadingCatalog = false
        }
    }

    private func browseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Capture Folder"
        if panel.runModal() == .OK, let url = panel.url {
            captureFolder = url.path
        }
    }

    private func syncMountTime() {
        let lat = observerLat
        let lon = observerLon
        let utcOffset = Double(TimeZone.current.secondsFromGMT()) / 3600.0
        Task {
            do {
                try await mountService.syncDatetime(observerLat: lat, observerLon: lon, utcOffsetHours: utcOffset)
                mountError = nil
            } catch {
                mountError = "Time sync failed: \(error.localizedDescription)"
            }
        }
    }

    private func syncLocationToCoordinator() {
        coordinator.observerLatDeg = observerLat
        coordinator.observerLonDeg = observerLon
    }

    // MARK: - Reusable Alpaca Device Section

    @ViewBuilder
    private func alpacaDeviceSection(
        title: String,
        host: Binding<String>,
        port: Binding<Int>,
        devices: [AlpacaDeviceInfo],
        selectedDevice: Binding<Int>,
        isDiscovering: Bool,
        isConnected: Bool,
        statusMessage: String,
        onDiscover: @escaping () -> Void,
        onConnect: @escaping () -> Void,
        onDisconnect: @escaping () -> Void
    ) -> some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Host")
                        .frame(width: 40, alignment: .trailing)
                    TextField("IP address", text: host)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                    Text("Port")
                    TextField("Port", value: port, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                }

                HStack {
                    Picker("Device", selection: selectedDevice) {
                        Text("No \(title.lowercased()) found").tag(-1)
                        ForEach(Array(devices.enumerated()), id: \.offset) { index, dev in
                            Text("\(dev.deviceName) (#\(dev.deviceNumber))").tag(index)
                        }
                    }
                    .frame(maxWidth: 300)

                    Button(action: onDiscover) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isDiscovering)

                    if isDiscovering {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                HStack {
                    if isConnected {
                        Circle()
                            .fill(.green)
                            .frame(width: 10, height: 10)
                        Text(statusMessage)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Disconnect", action: onDisconnect)
                            .buttonStyle(.bordered)
                    } else {
                        Circle()
                            .fill(.red)
                            .frame(width: 10, height: 10)
                        Text("Not connected")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Connect", action: onConnect)
                            .buttonStyle(.borderedProminent)
                            .disabled(selectedDevice.wrappedValue < 0)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}
