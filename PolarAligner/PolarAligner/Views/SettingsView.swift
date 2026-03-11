import SwiftUI
import PolarCore

struct SettingsView: View {
    @ObservedObject var mountService: MountService
    @ObservedObject var plateSolveService: PlateSolveService
    @ObservedObject var coordinator: AlignmentCoordinator
    @ObservedObject var cameraViewModel: CameraViewModel

    // Mount connection
    @State private var mountProtocol: MountProtocolChoice = .lx200
    @State private var serialPort: String = ""
    @State private var baudRate: UInt32 = 9600
    @State private var lx200TcpHost: String = "192.168.4.1"
    @State private var lx200TcpPort: UInt32 = 4030
    @State private var alpacaHost: String = "192.168.1.1"
    @State private var alpacaPort: UInt32 = 11111
    @State private var availablePorts: [String] = []
    @State private var discoveredAlpaca: [String] = []
    @State private var mountError: String?
    @State private var isDiscovering = false

    // Observer location
    @AppStorage("observerLat") private var observerLat: Double = 60.17
    @AppStorage("observerLon") private var observerLon: Double = 24.94

    // Telescope
    @AppStorage("focalLengthMM") private var focalLengthMM: Double = 200.0

    // Camera
    @State private var discoveredCameras: [ASICameraInfo] = []
    @State private var selectedCameraIndex: Int = -1
    @State private var isDiscoveringCameras = false
    @AppStorage("exposureMs") private var exposureMs: Double = 500
    @AppStorage("gain") private var gain: Double = 300
    @AppStorage("binning") private var binning: Int = 2

    // Star catalog
    @AppStorage("starCatalogPath") private var starCatalogPath: String = ""
    @State private var catalogLoadError: String?
    @State private var isLoadingCatalog = false

    // Cooling
    @State private var coolerTarget: Int = -10

    // Capture
    @AppStorage("captureFolder") private var captureFolder: String = ""
    @AppStorage("captureFormat") private var captureFormat: String = "fits"
    @AppStorage("captureColorMode") private var captureColorMode: String = "rgb"
    @AppStorage("capturePrefix") private var capturePrefix: String = "capture"

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
                        Picker("Protocol", selection: $mountProtocol) {
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
                                Button("Disconnect") {
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

                // MARK: - Telescope
                GroupBox("Telescope") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Focal Length")
                                .frame(width: 80, alignment: .trailing)
                            TextField("mm", value: $focalLengthMM, format: .number.precision(.fractionLength(0)))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                            Text("mm")
                                .foregroundStyle(.secondary)
                        }
                        let sensorWidthMM = selectedCamera.map { Double($0.maxWidth) * $0.pixelSize / 1000.0 } ?? 11.14
                        let effectiveSensorMM = sensorWidthMM / Double(binning)
                        let fov = 2.0 * atan(effectiveSensorMM / (2.0 * focalLengthMM)) * 180.0 / .pi
                        let cameraLabel = selectedCamera?.name ?? "unknown camera"
                        Text(String(format: "FOV: %.2f° (%@ %dx%d bin)", fov, cameraLabel, binning, binning))
                            .font(.caption)
                            .foregroundStyle(.secondary)
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

                // MARK: - Camera
                GroupBox("Camera") {
                    VStack(alignment: .leading, spacing: 8) {
                        // Camera selection
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
                            // Camera info
                            Text("\(cam.maxWidth)x\(cam.maxHeight) \(cam.isColorCamera ? "Color" : "Mono") \(String(format: "%.1fμm", cam.pixelSize)) \(cam.isUSB3 ? "USB3" : "USB2")\(cam.hasCooler ? " Cooled" : "")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
                                    cameraViewModel.discoveredCameras = discoveredCameras
                                    cameraViewModel.selectedCameraIndex = selectedCameraIndex
                                    cameraViewModel.connect()
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(selectedCameraIndex < 0)
                            }
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
                            Text("Default: ~/Pictures/PolarAligner/")
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
                GroupBox("About") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PolarCore v\(PolarCore.polarCoreVersion())")
                        Text("Database: \(plateSolveService.databaseInfo ?? "Not loaded")")
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
            syncLocationToCoordinator()
        }
        .onChange(of: observerLat) { syncLocationToCoordinator() }
        .onChange(of: observerLon) { syncLocationToCoordinator() }
        .onChange(of: focalLengthMM) {
            plateSolveService.setFOV(focalLengthMM: focalLengthMM)
        }
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

            Picker("Baud Rate", selection: $baudRate) {
                Text("9600").tag(UInt32(9600))
                Text("19200").tag(UInt32(19200))
                Text("38400").tag(UInt32(38400))
                Text("115200").tag(UInt32(115200))
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
                TextField("Port", value: $lx200TcpPort, format: .number)
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
                TextField("Port", value: $alpacaPort, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
            }

            HStack {
                Button("Discover") {
                    discoverAlpacaDevices()
                }
                .disabled(isDiscovering)

                if isDiscovering {
                    ProgressView()
                        .controlSize(.small)
                }

                ForEach(discoveredAlpaca, id: \.self) { device in
                    Button(device) {
                        let parts = device.split(separator: ":")
                        if parts.count == 2 {
                            alpacaHost = String(parts[0])
                            alpacaPort = UInt32(parts[1]) ?? 11111
                        }
                    }
                    .buttonStyle(.bordered)
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

    /// Clamp exposure to valid range: 1 ms – 600,000 ms (10 min).
    private func clampedExposure(_ value: Double) -> Double {
        max(1, min(value, 600_000))
    }

    // MARK: - Actions

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

    private func discoverAlpacaDevices() {
        isDiscovering = true
        Task {
            discoveredAlpaca = await mountService.discoverAlpaca(timeoutMs: 3000)
            isDiscovering = false
        }
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
                    try await mountService.connectAlpaca(host: alpacaHost, port: alpacaPort)
                }
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

    private func syncLocationToCoordinator() {
        coordinator.observerLatDeg = observerLat
        coordinator.observerLonDeg = observerLon
    }
}
