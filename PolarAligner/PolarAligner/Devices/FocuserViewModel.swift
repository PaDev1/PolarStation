import Foundation
import PolarCore

/// Manages focuser lifecycle: discovery, connection, position control, and temperature monitoring.
@MainActor
final class FocuserViewModel: ObservableObject {

    @Published var isConnected = false
    @Published var position: Int32 = 0
    @Published var maxStep: Int32 = 0
    @Published var temperature: Double = -999
    @Published var tempComp: Bool = false
    @Published var isMoving = false
    @Published var statusMessage = "Not connected"

    @Published var alpacaDevices: [AlpacaDeviceInfo] = []
    @Published var selectedAlpacaDevice: Int = -1
    @Published var isDiscoveringDevices = false

    private let bridge = AlpacaFocuserBridge()
    private var pollTimer: Timer?
    private var tempPollTimer: Timer?
    private var isPolling = false

    // MARK: - Discovery

    func discoverDevices(host: String, port: UInt32) {
        isDiscoveringDevices = true
        DispatchQueue.global(qos: .userInitiated).async {
            let devices = (try? PolarCore.discoverAlpacaFocusers(host: host, port: UInt16(port))) ?? []
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
                    self.position = info?.position ?? 0
                    self.maxStep = info?.maxStep ?? 0
                    self.temperature = info?.temperature ?? -999
                    self.tempComp = info?.tempComp ?? false
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

    func moveTo(position: Int32) {
        guard isConnected else { return }
        isMoving = true
        DispatchQueue.global(qos: .userInitiated).async {
            try? self.bridge.move(position: position)
        }
    }

    func halt() {
        guard isConnected else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            try? self.bridge.halt()
        }
    }

    func setTempComp(_ enabled: Bool) {
        guard isConnected else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            try? self.bridge.setTempComp(enabled)
            DispatchQueue.main.async { self.tempComp = enabled }
        }
    }

    // MARK: - Polling

    func refreshStatus() {
        guard isConnected, !isPolling else { return }
        isPolling = true
        DispatchQueue.global(qos: .userInitiated).async {
            let pos = (try? self.bridge.getPosition()) ?? self.bridge.info?.position ?? 0
            let moving = (try? self.bridge.isMoving()) ?? false
            DispatchQueue.main.async {
                self.position = pos
                self.isMoving = moving
                self.isPolling = false
            }
        }
    }

    private func refreshTemperature() {
        guard isConnected else { return }
        DispatchQueue.global(qos: .utility).async {
            let temp = (try? self.bridge.getTemperature()) ?? -999
            DispatchQueue.main.async {
                self.temperature = temp
            }
        }
    }

    private func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
        // Temperature changes slowly — poll at 15s
        tempPollTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshTemperature() }
        }
        refreshTemperature()
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        tempPollTimer?.invalidate()
        tempPollTimer = nil
    }
}

// MARK: - Bridge

final class AlpacaFocuserBridge {
    private let controller = AlpacaFocuserController()
    private(set) var info: AlpacaFocuserInfo?
    private(set) var isOpen = false

    func open(host: String, port: UInt32, deviceNumber: UInt32 = 0) throws {
        let focuserInfo = try controller.connect(host: host, port: port, deviceNumber: deviceNumber)
        info = focuserInfo
        isOpen = true
    }

    func close() throws {
        try controller.disconnect()
        isOpen = false
        info = nil
    }

    func getPosition() throws -> Int32 { try controller.getPosition() }
    func isMoving() throws -> Bool { try controller.isMoving() }
    func getTemperature() throws -> Double { try controller.getTemperature() }
    func move(position: Int32) throws { try controller.moveTo(position: position) }
    func halt() throws { try controller.halt() }
    func setTempComp(_ enabled: Bool) throws { try controller.setTempComp(enabled: enabled) }
}
