import Foundation
import PolarCore

/// Manages rotator lifecycle: discovery, connection, and angle control.
@MainActor
final class RotatorViewModel: ObservableObject {

    @Published var isConnected = false
    @Published var position: Double = 0
    @Published var mechanicalPosition: Double = 0
    @Published var isMoving = false
    @Published var statusMessage = "Not connected"

    @Published var alpacaDevices: [AlpacaDeviceInfo] = []
    @Published var selectedAlpacaDevice: Int = -1
    @Published var isDiscoveringDevices = false

    private let bridge = AlpacaRotatorBridge()
    private var pollTimer: Timer?
    private var isPolling = false

    func discoverDevices(host: String, port: UInt32) {
        isDiscoveringDevices = true
        DispatchQueue.global(qos: .userInitiated).async {
            let devices = (try? PolarCore.discoverAlpacaRotators(host: host, port: UInt16(port))) ?? []
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
                    self.position = info?.position ?? 0
                    self.mechanicalPosition = info?.mechanicalPosition ?? 0
                    self.isMoving = info?.isMoving ?? false
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

    func moveAbsolute(degrees: Double) {
        guard isConnected else { return }
        isMoving = true
        DispatchQueue.global(qos: .userInitiated).async {
            try? self.bridge.moveAbsolute(position: degrees)
        }
    }

    func moveRelative(degrees: Double) {
        guard isConnected else { return }
        isMoving = true
        DispatchQueue.global(qos: .userInitiated).async {
            try? self.bridge.moveRelative(position: degrees)
        }
    }

    func halt() {
        guard isConnected else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            try? self.bridge.halt()
            DispatchQueue.main.async { self.isMoving = false }
        }
    }

    func refreshStatus() {
        guard isConnected, !isPolling else { return }
        isPolling = true
        DispatchQueue.global(qos: .userInitiated).async {
            let pos = (try? self.bridge.getPosition()) ?? 0
            let mech = (try? self.bridge.getMechanicalPosition()) ?? 0
            let moving = (try? self.bridge.isMoving()) ?? false
            DispatchQueue.main.async {
                self.position = pos
                self.mechanicalPosition = mech
                self.isMoving = moving
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

final class AlpacaRotatorBridge {
    private let controller = AlpacaRotatorController()
    private(set) var info: AlpacaRotatorInfo?
    private(set) var isOpen = false

    func open(host: String, port: UInt32, deviceNumber: UInt32 = 0) throws {
        let rotatorInfo = try controller.connect(host: host, port: port, deviceNumber: deviceNumber)
        info = rotatorInfo
        isOpen = true
    }

    func close() throws {
        try controller.disconnect()
        isOpen = false
        info = nil
    }

    func getPosition() throws -> Double { try controller.getPosition() }
    func getMechanicalPosition() throws -> Double { try controller.getMechanicalPosition() }
    func isMoving() throws -> Bool { try controller.isMoving() }
    func moveAbsolute(position: Double) throws { try controller.moveAbsolute(position: position) }
    func moveRelative(position: Double) throws { try controller.moveRelative(position: position) }
    func halt() throws { try controller.halt() }
}
