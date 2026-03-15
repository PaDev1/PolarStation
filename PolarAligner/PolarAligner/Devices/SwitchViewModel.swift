import Foundation
import PolarCore

/// Manages ASCOM switch device lifecycle: discovery, connection, and switch control.
@MainActor
final class SwitchViewModel: ObservableObject {

    @Published var isConnected = false
    @Published var maxSwitch: Int32 = 0
    @Published var switchNames: [String] = []
    @Published var switchStates: [Bool] = []
    @Published var switchValues: [Double] = []
    @Published var statusMessage = "Not connected"

    @Published var alpacaDevices: [AlpacaDeviceInfo] = []
    @Published var selectedAlpacaDevice: Int = -1
    @Published var isDiscoveringDevices = false

    private let bridge = AlpacaSwitchBridge()
    private var pollTimer: Timer?
    private var isPolling = false

    func discoverDevices(host: String, port: UInt32) {
        isDiscoveringDevices = true
        DispatchQueue.global(qos: .userInitiated).async {
            let devices = (try? PolarCore.discoverAlpacaSwitches(host: host, port: UInt16(port))) ?? []
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
                let count = Int(info?.maxSwitch ?? 0)
                var names: [String] = []
                var states: [Bool] = []
                var values: [Double] = []
                for i in 0..<count {
                    names.append((try? self.bridge.getSwitchName(Int32(i))) ?? "Switch \(i)")
                    states.append((try? self.bridge.getSwitch(Int32(i))) ?? false)
                    values.append((try? self.bridge.getSwitchValue(Int32(i))) ?? 0)
                }
                DispatchQueue.main.async {
                    self.isConnected = true
                    self.maxSwitch = info?.maxSwitch ?? 0
                    self.switchNames = names
                    self.switchStates = states
                    self.switchValues = values
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

    func setSwitch(id: Int32, state: Bool) {
        guard isConnected else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            try? self.bridge.setSwitch(id, state: state)
        }
    }

    func setSwitchValue(id: Int32, value: Double) {
        guard isConnected else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            try? self.bridge.setSwitchValue(id, value: value)
        }
    }

    func refreshStatus() {
        guard isConnected, !isPolling else { return }
        isPolling = true
        let count = Int(maxSwitch)
        DispatchQueue.global(qos: .userInitiated).async {
            var states: [Bool] = []
            var values: [Double] = []
            for i in 0..<count {
                states.append((try? self.bridge.getSwitch(Int32(i))) ?? false)
                values.append((try? self.bridge.getSwitchValue(Int32(i))) ?? 0)
            }
            DispatchQueue.main.async {
                self.switchStates = states
                self.switchValues = values
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

final class AlpacaSwitchBridge {
    private let controller = AlpacaSwitchController()
    private(set) var info: AlpacaSwitchInfo?
    private(set) var isOpen = false

    func open(host: String, port: UInt32, deviceNumber: UInt32 = 0) throws {
        let switchInfo = try controller.connect(host: host, port: port, deviceNumber: deviceNumber)
        info = switchInfo
        isOpen = true
    }

    func close() throws {
        try controller.disconnect()
        isOpen = false
        info = nil
    }

    func getMaxSwitch() throws -> Int32 { try controller.getMaxSwitch() }
    func getSwitchName(_ id: Int32) throws -> String { try controller.getSwitchName(id: id) }
    func getSwitch(_ id: Int32) throws -> Bool { try controller.getSwitch(id: id) }
    func getSwitchValue(_ id: Int32) throws -> Double { try controller.getSwitchValue(id: id) }
    func setSwitch(_ id: Int32, state: Bool) throws { try controller.setSwitch(id: id, state: state) }
    func setSwitchValue(_ id: Int32, value: Double) throws { try controller.setSwitchValue(id: id, value: value) }
    func getMinSwitchValue(_ id: Int32) throws -> Double { try controller.getMinSwitchValue(id: id) }
    func getMaxSwitchValue(_ id: Int32) throws -> Double { try controller.getMaxSwitchValue(id: id) }
}
