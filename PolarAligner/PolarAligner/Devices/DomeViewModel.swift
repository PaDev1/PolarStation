import Foundation
import PolarCore

/// Manages dome lifecycle: discovery, connection, shutter and azimuth control.
@MainActor
final class DomeViewModel: ObservableObject {

    @Published var isConnected = false
    @Published var azimuth: Double = 0
    @Published var shutterStatus: Int32 = 1  // 0=open,1=closed,2=opening,3=closing,4=error
    @Published var isSlewing = false
    @Published var atHome = false
    @Published var atPark = false
    @Published var statusMessage = "Not connected"

    @Published var alpacaDevices: [AlpacaDeviceInfo] = []
    @Published var selectedAlpacaDevice: Int = -1
    @Published var isDiscoveringDevices = false

    private let bridge = AlpacaDomeBridge()
    private var pollTimer: Timer?
    private var isPolling = false

    var shutterLabel: String {
        switch shutterStatus {
        case 0: return "Open"
        case 1: return "Closed"
        case 2: return "Opening"
        case 3: return "Closing"
        default: return "Error"
        }
    }

    // MARK: - Discovery

    func discoverDevices(host: String, port: UInt32) {
        isDiscoveringDevices = true
        DispatchQueue.global(qos: .userInitiated).async {
            let devices = (try? PolarCore.discoverAlpacaDomes(host: host, port: UInt16(port))) ?? []
            DispatchQueue.main.async {
                self.alpacaDevices = devices
                if self.selectedAlpacaDevice < 0, !devices.isEmpty { self.selectedAlpacaDevice = 0 }
                self.isDiscoveringDevices = false
            }
        }
    }

    // MARK: - Connection

    func connect(host: String, port: UInt32, deviceNumber: UInt32) {
        statusMessage = "Connecting..."
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.bridge.open(host: host, port: port, deviceNumber: deviceNumber)
                let info = self.bridge.info
                DispatchQueue.main.async {
                    self.isConnected = true
                    self.azimuth = info?.azimuth ?? 0
                    self.shutterStatus = info?.shutterStatus ?? 1
                    self.atHome = info?.atHome ?? false
                    self.atPark = info?.atPark ?? false
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

    // MARK: - Control

    func slewToAzimuth(_ az: Double) {
        guard isConnected else { return }
        isSlewing = true
        DispatchQueue.global(qos: .userInitiated).async {
            try? self.bridge.slewToAzimuth(az)
        }
    }

    func openShutter() {
        guard isConnected else { return }
        shutterStatus = 2
        DispatchQueue.global(qos: .userInitiated).async {
            try? self.bridge.openShutter()
        }
    }

    func closeShutter() {
        guard isConnected else { return }
        shutterStatus = 3
        DispatchQueue.global(qos: .userInitiated).async {
            try? self.bridge.closeShutter()
        }
    }

    func park() {
        guard isConnected else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            try? self.bridge.park()
            DispatchQueue.main.async { self.refreshFullStatus() }
        }
    }

    func findHome() {
        guard isConnected else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            try? self.bridge.findHome()
            DispatchQueue.main.async { self.refreshFullStatus() }
        }
    }

    func abortSlew() {
        guard isConnected else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            try? self.bridge.abortSlew()
            DispatchQueue.main.async { self.isSlewing = false }
        }
    }

    // MARK: - Polling

    /// Regular poll: azimuth, shutter, slewing only (3 GETs instead of 5).
    func refreshStatus() {
        guard isConnected, !isPolling else { return }
        isPolling = true
        DispatchQueue.global(qos: .userInitiated).async {
            let az = (try? self.bridge.getAzimuth()) ?? 0
            let shutter = (try? self.bridge.getShutterStatus()) ?? 1
            let slewing = (try? self.bridge.isSlewing()) ?? false
            DispatchQueue.main.async {
                self.azimuth = az
                self.shutterStatus = shutter
                self.isSlewing = slewing
                self.isPolling = false
            }
        }
    }

    /// Full refresh including athome/atpark. Call after park/home commands.
    func refreshFullStatus() {
        guard isConnected else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let az = (try? self.bridge.getAzimuth()) ?? 0
            let shutter = (try? self.bridge.getShutterStatus()) ?? 1
            let slewing = (try? self.bridge.isSlewing()) ?? false
            let home = (try? self.bridge.isAtHome()) ?? false
            let park = (try? self.bridge.isAtPark()) ?? false
            DispatchQueue.main.async {
                self.azimuth = az
                self.shutterStatus = shutter
                self.isSlewing = slewing
                self.atHome = home
                self.atPark = park
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

final class AlpacaDomeBridge {
    private let controller = AlpacaDomeController()
    private(set) var info: AlpacaDomeInfo?
    private(set) var isOpen = false

    func open(host: String, port: UInt32, deviceNumber: UInt32 = 0) throws {
        let domeInfo = try controller.connect(host: host, port: port, deviceNumber: deviceNumber)
        info = domeInfo
        isOpen = true
    }

    func close() throws {
        try controller.disconnect()
        isOpen = false
        info = nil
    }

    func getAzimuth() throws -> Double { try controller.getAzimuth() }
    func getShutterStatus() throws -> Int32 { try controller.getShutterStatus() }
    func isSlewing() throws -> Bool { try controller.isSlewing() }
    func isAtHome() throws -> Bool { try controller.atHome() }
    func isAtPark() throws -> Bool { try controller.atPark() }
    func slewToAzimuth(_ az: Double) throws { try controller.slewToAzimuth(azimuth: az) }
    func openShutter() throws { try controller.openShutter() }
    func closeShutter() throws { try controller.closeShutter() }
    func park() throws { try controller.park() }
    func findHome() throws { try controller.findHome() }
    func abortSlew() throws { try controller.abortSlew() }
}
