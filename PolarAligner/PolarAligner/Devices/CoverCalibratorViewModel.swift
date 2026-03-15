import Foundation
import PolarCore

/// Manages cover calibrator lifecycle: discovery, connection, cover and calibrator control.
@MainActor
final class CoverCalibratorViewModel: ObservableObject {

    @Published var isConnected = false
    @Published var coverState: Int32 = 0    // 0=NotPresent,1=Closed,2=Moving,3=Open,4=Unknown,5=Error
    @Published var calibratorState: Int32 = 0  // 0=NotPresent,1=Off,2=NotReady,3=Ready,4=Unknown,5=Error
    @Published var brightness: Int32 = 0
    @Published var maxBrightness: Int32 = 0
    @Published var statusMessage = "Not connected"

    @Published var alpacaDevices: [AlpacaDeviceInfo] = []
    @Published var selectedAlpacaDevice: Int = -1
    @Published var isDiscoveringDevices = false

    private let bridge = AlpacaCoverCalibratorBridge()
    private var pollTimer: Timer?
    private var isPolling = false

    var coverLabel: String {
        switch coverState {
        case 0: return "Not Present"
        case 1: return "Closed"
        case 2: return "Moving"
        case 3: return "Open"
        case 4: return "Unknown"
        default: return "Error"
        }
    }

    var calibratorLabel: String {
        switch calibratorState {
        case 0: return "Not Present"
        case 1: return "Off"
        case 2: return "Not Ready"
        case 3: return "Ready"
        case 4: return "Unknown"
        default: return "Error"
        }
    }

    func discoverDevices(host: String, port: UInt32) {
        isDiscoveringDevices = true
        DispatchQueue.global(qos: .userInitiated).async {
            let devices = (try? PolarCore.discoverAlpacaCovercalibrators(host: host, port: UInt16(port))) ?? []
            DispatchQueue.main.async {
                self.alpacaDevices = devices
                if self.selectedAlpacaDevice < 0, !devices.isEmpty { self.selectedAlpacaDevice = 0 }
                self.isDiscoveringDevices = false
            }
        }
    }

    func connect(host: String, port: UInt32, deviceNumber: UInt32) {
        statusMessage = "Connecting..."
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.bridge.open(host: host, port: port, deviceNumber: deviceNumber)
                let info = self.bridge.info
                DispatchQueue.main.async {
                    self.isConnected = true
                    self.coverState = info?.coverState ?? 4
                    self.calibratorState = info?.calibratorState ?? 4
                    self.brightness = info?.brightness ?? 0
                    self.maxBrightness = info?.maxBrightness ?? 0
                    self.statusMessage = info?.name ?? "Connected"
                    self.startPolling()
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = "Failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func disconnect() {
        stopPolling()
        try? bridge.close()
        isConnected = false
        statusMessage = "Not connected"
    }

    func openCover() {
        guard isConnected else { return }
        coverState = 2
        DispatchQueue.global(qos: .userInitiated).async {
            try? self.bridge.openCover()
        }
    }

    func closeCover() {
        guard isConnected else { return }
        coverState = 2
        DispatchQueue.global(qos: .userInitiated).async {
            try? self.bridge.closeCover()
        }
    }

    func haltCover() {
        guard isConnected else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            try? self.bridge.haltCover()
        }
    }

    func calibratorOn(brightness: Int32) {
        guard isConnected else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            try? self.bridge.calibratorOn(brightness: brightness)
        }
    }

    func calibratorOff() {
        guard isConnected else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            try? self.bridge.calibratorOff()
        }
    }

    func refreshStatus() {
        guard isConnected, !isPolling else { return }
        isPolling = true
        DispatchQueue.global(qos: .userInitiated).async {
            let cs = (try? self.bridge.getCoverState()) ?? 4
            let cal = (try? self.bridge.getCalibratorState()) ?? 4
            let br = (try? self.bridge.getBrightness()) ?? 0
            DispatchQueue.main.async {
                self.coverState = cs
                self.calibratorState = cal
                self.brightness = br
                self.isPolling = false
            }
        }
    }

    private func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}

// MARK: - Bridge

final class AlpacaCoverCalibratorBridge {
    private let controller = AlpacaCoverCalibratorController()
    private(set) var info: AlpacaCoverCalibratorInfo?
    private(set) var isOpen = false

    func open(host: String, port: UInt32, deviceNumber: UInt32 = 0) throws {
        let ccInfo = try controller.connect(host: host, port: port, deviceNumber: deviceNumber)
        info = ccInfo
        isOpen = true
    }

    func close() throws {
        try controller.disconnect()
        isOpen = false
        info = nil
    }

    func getCoverState() throws -> Int32 { try controller.getCoverState() }
    func getCalibratorState() throws -> Int32 { try controller.getCalibratorState() }
    func getBrightness() throws -> Int32 { try controller.getBrightness() }
    func getMaxBrightness() throws -> Int32 { try controller.getMaxBrightness() }
    func openCover() throws { try controller.openCover() }
    func closeCover() throws { try controller.closeCover() }
    func haltCover() throws { try controller.haltCover() }
    func calibratorOn(brightness: Int32) throws { try controller.calibratorOn(brightness: brightness) }
    func calibratorOff() throws { try controller.calibratorOff() }
}
