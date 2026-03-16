import SwiftUI

@main
struct PolarAlignerApp: App {
    @StateObject private var appState = AppState()

    init() {
        UserDefaults.standard.register(defaults: [
            "observerLat": 60.17,
            "observerLon": 24.94,
            "focalLengthMM": 200.0,
            "pixelSizeMicrons": 2.9,
            "guideFocalLengthMM": 200.0,
            "guidePixelSizeMicrons": 2.9
        ])
    }
    @AppStorage("starCatalogPath") private var starCatalogPath: String = ""

    // Auto-connect: remember which devices were connected
    @AppStorage("autoConnectMount") private var autoConnectMount: Bool = false
    @AppStorage("autoConnectCamera") private var autoConnectCamera: Bool = false
    @AppStorage("autoConnectGuideCamera") private var autoConnectGuideCamera: Bool = false
    @AppStorage("autoConnectFilterWheel") private var autoConnectFilterWheel: Bool = false
    @AppStorage("autoConnectFocuser") private var autoConnectFocuser: Bool = false

    // Mount settings
    @AppStorage("mountProtocol") private var mountProtocolRaw: String = "LX200 Serial (USB)"
    @AppStorage("mountSerialPort") private var mountSerialPort: String = ""
    @AppStorage("mountBaudRate") private var mountBaudRate: Int = 9600
    @AppStorage("mountLx200TcpHost") private var mountLx200TcpHost: String = "192.168.4.1"
    @AppStorage("mountLx200TcpPort") private var mountLx200TcpPort: Int = 4030
    @AppStorage("mountAlpacaHost") private var mountAlpacaHost: String = "192.168.1.1"
    @AppStorage("mountAlpacaPort") private var mountAlpacaPort: Int = 11111

    // Camera settings
    @AppStorage("cameraSource") private var cameraSourceRaw: String = CameraSource.usb.rawValue
    @AppStorage("cameraAlpacaHost") private var cameraAlpacaHost: String = "192.168.8.30"
    @AppStorage("cameraAlpacaPort") private var cameraAlpacaPort: Int = 11111

    // Guide camera settings
    @AppStorage("guideCameraSource") private var guideCameraSourceRaw: String = CameraSource.usb.rawValue
    @AppStorage("guideCameraAlpacaHost") private var guideCameraAlpacaHost: String = "192.168.8.30"
    @AppStorage("guideCameraAlpacaPort") private var guideCameraAlpacaPort: Int = 11111

    // Filter wheel settings
    @AppStorage("filterWheelAlpacaHost") private var filterWheelAlpacaHost: String = "192.168.8.30"
    @AppStorage("filterWheelAlpacaPort") private var filterWheelAlpacaPort: Int = 11111

    // Focuser settings
    @AppStorage("focuserAlpacaHost") private var focuserAlpacaHost: String = "192.168.8.30"
    @AppStorage("focuserAlpacaPort") private var focuserAlpacaPort: Int = 11111

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .task {
                    await autoLoadCatalog()
                    await autoConnectDevices()
                }
        }
        .defaultSize(width: 1200, height: 800)
    }

    private func autoLoadCatalog() async {
        if !starCatalogPath.isEmpty {
            do {
                try await appState.plateSolveService.loadDatabase(from: starCatalogPath)
                return
            } catch {
                print("Failed to load star catalog from \(starCatalogPath): \(error)")
            }
        }
        do {
            try await appState.plateSolveService.loadBundledDatabase()
        } catch {
            print("No star catalog loaded — set path in Settings")
        }
    }

    private func autoConnectDevices() async {
        // Mount
        if autoConnectMount {
            switch mountProtocolRaw {
            case "LX200 Serial (USB)":
                if !mountSerialPort.isEmpty {
                    try? await appState.mountService.connectLx200(
                        devicePath: mountSerialPort,
                        baudRate: UInt32(mountBaudRate)
                    )
                }
            case "LX200 TCP/WiFi (AM5)":
                try? await appState.mountService.connectLx200Tcp(
                    host: mountLx200TcpHost,
                    port: UInt32(mountLx200TcpPort)
                )
            case "ASCOM Alpaca (Wi-Fi)":
                appState.mountService.discoverMounts(
                    host: mountAlpacaHost,
                    port: UInt32(mountAlpacaPort)
                )
                try? await Task.sleep(for: .seconds(3))
                if !appState.mountService.alpacaDevices.isEmpty {
                    appState.mountService.selectedAlpacaDevice = 0
                    let devNum = appState.mountService.alpacaDevices[0].deviceNumber
                    try? await appState.mountService.connectAlpaca(
                        host: mountAlpacaHost,
                        port: UInt32(mountAlpacaPort),
                        deviceNumber: devNum
                    )
                }
            default:
                break
            }
        }

        // Camera
        if autoConnectCamera {
            if cameraSourceRaw == CameraSource.alpaca.rawValue {
                appState.cameraViewModel.cameraSource = .alpaca
                appState.cameraViewModel.alpacaHost = cameraAlpacaHost
                appState.cameraViewModel.alpacaPort = UInt32(cameraAlpacaPort)
                appState.cameraViewModel.discoverAlpacaCameras(
                    host: cameraAlpacaHost,
                    port: UInt32(cameraAlpacaPort)
                )
                try? await Task.sleep(for: .seconds(3))
                if !appState.cameraViewModel.alpacaDevices.isEmpty {
                    appState.cameraViewModel.selectedAlpacaDevice = 0
                    appState.cameraViewModel.alpacaDeviceNumber = appState.cameraViewModel.alpacaDevices[0].deviceNumber
                    appState.cameraViewModel.connect()
                }
            } else {
                appState.cameraViewModel.cameraSource = .usb
                appState.cameraViewModel.discoverCameras()
                try? await Task.sleep(for: .seconds(2))
                if !appState.cameraViewModel.discoveredCameras.isEmpty {
                    appState.cameraViewModel.selectedCameraIndex = 0
                    appState.cameraViewModel.connect()
                }
            }
        }

        // Guide camera
        if autoConnectGuideCamera {
            if guideCameraSourceRaw == CameraSource.alpaca.rawValue {
                appState.guideCameraViewModel.cameraSource = .alpaca
                appState.guideCameraViewModel.alpacaHost = guideCameraAlpacaHost
                appState.guideCameraViewModel.alpacaPort = UInt32(guideCameraAlpacaPort)
                appState.guideCameraViewModel.discoverAlpacaCameras(
                    host: guideCameraAlpacaHost,
                    port: UInt32(guideCameraAlpacaPort)
                )
                try? await Task.sleep(for: .seconds(3))
                if !appState.guideCameraViewModel.alpacaDevices.isEmpty {
                    appState.guideCameraViewModel.selectedAlpacaDevice = 0
                    appState.guideCameraViewModel.alpacaDeviceNumber = appState.guideCameraViewModel.alpacaDevices[0].deviceNumber
                    appState.guideCameraViewModel.connect()
                }
            } else {
                appState.guideCameraViewModel.cameraSource = .usb
                appState.guideCameraViewModel.discoverCameras()
                try? await Task.sleep(for: .seconds(2))
                if !appState.guideCameraViewModel.discoveredCameras.isEmpty {
                    appState.guideCameraViewModel.selectedCameraIndex = 0
                    appState.guideCameraViewModel.connect()
                }
            }
        }

        // Filter wheel
        if autoConnectFilterWheel {
            appState.filterWheelViewModel.discoverDevices(
                host: filterWheelAlpacaHost,
                port: UInt32(filterWheelAlpacaPort)
            )
            try? await Task.sleep(for: .seconds(3))
            if !appState.filterWheelViewModel.alpacaDevices.isEmpty {
                appState.filterWheelViewModel.selectedAlpacaDevice = 0
                let devNum = appState.filterWheelViewModel.alpacaDevices[0].deviceNumber
                appState.filterWheelViewModel.connect(
                    host: filterWheelAlpacaHost,
                    port: UInt32(filterWheelAlpacaPort),
                    deviceNumber: devNum
                )
            }
        }

        // Focuser
        if autoConnectFocuser {
            appState.focuserViewModel.discoverDevices(
                host: focuserAlpacaHost,
                port: UInt32(focuserAlpacaPort)
            )
            try? await Task.sleep(for: .seconds(3))
            if !appState.focuserViewModel.alpacaDevices.isEmpty {
                appState.focuserViewModel.selectedAlpacaDevice = 0
                let devNum = appState.focuserViewModel.alpacaDevices[0].deviceNumber
                appState.focuserViewModel.connect(
                    host: focuserAlpacaHost,
                    port: UInt32(focuserAlpacaPort),
                    deviceNumber: devNum
                )
            }
        }
    }
}
