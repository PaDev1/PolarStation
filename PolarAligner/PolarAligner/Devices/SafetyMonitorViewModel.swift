import Foundation
import PolarCore

/// Manages safety monitor lifecycle: discovery, connection, and safety status monitoring.
@MainActor
final class SafetyMonitorViewModel: ObservableObject {

    @Published var isConnected = false
    @Published var isSafe = false
    @Published var statusMessage = "Not connected"

    @Published var alpacaDevices: [AlpacaDeviceInfo] = []
    @Published var selectedAlpacaDevice: Int = -1
    @Published var isDiscoveringDevices = false

    private let bridge = AlpacaSafetyMonitorBridge()
    private var pollTimer: Timer?
    private var isPolling = false

    func discoverDevices(host: String, port: UInt32) {
        isDiscoveringDevices = true
        DispatchQueue.global(qos: .userInitiated).async {
            let devices = (try? PolarCore.discoverAlpacaSafetymonitors(host: host, port: UInt16(port))) ?? []
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
                    self.isSafe = info?.isSafe ?? false
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

    func refreshStatus() {
        guard isConnected, !isPolling else { return }
        isPolling = true
        DispatchQueue.global(qos: .userInitiated).async {
            let safe = (try? self.bridge.isSafe()) ?? false
            DispatchQueue.main.async {
                self.isSafe = safe
                self.isPolling = false
            }
        }
    }

    private func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}

// MARK: - Bridge

final class AlpacaSafetyMonitorBridge {
    private let controller = AlpacaSafetyMonitorController()
    private(set) var info: AlpacaSafetyMonitorInfo?
    private(set) var isOpen = false

    func open(host: String, port: UInt32, deviceNumber: UInt32 = 0) throws {
        let monitorInfo = try controller.connect(host: host, port: port, deviceNumber: deviceNumber)
        info = monitorInfo
        isOpen = true
    }

    func close() throws {
        try controller.disconnect()
        isOpen = false
        info = nil
    }

    func isSafe() throws -> Bool { try controller.isSafe() }
}
