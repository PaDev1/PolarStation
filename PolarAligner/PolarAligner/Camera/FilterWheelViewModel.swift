import Foundation
import PolarCore

/// Manages filter wheel lifecycle: discovery, connection, and filter selection.
@MainActor
final class FilterWheelViewModel: ObservableObject {

    // MARK: - Published state

    @Published var isConnected = false
    @Published var filterNames: [String] = []
    @Published var currentPosition: Int = -1
    @Published var isMoving = false
    @Published var statusMessage = "Not connected"

    // Alpaca device discovery
    @Published var alpacaDevices: [AlpacaDeviceInfo] = []
    @Published var selectedAlpacaDevice: Int = -1
    @Published var isDiscoveringDevices = false

    // MARK: - Internal

    private let bridge = AlpacaFilterWheelBridge()
    private var positionTimer: Timer?

    // MARK: - Discovery

    func discoverDevices(host: String, port: UInt32) {
        isDiscoveringDevices = true
        let h = host
        let p = port
        DispatchQueue.global(qos: .userInitiated).async {
            let devices = (try? PolarCore.discoverAlpacaFilterwheels(host: h, port: UInt16(p))) ?? []
            DispatchQueue.main.async {
                self.alpacaDevices = devices
                if self.selectedAlpacaDevice < 0, !devices.isEmpty {
                    self.selectedAlpacaDevice = 0
                }
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
                let names = info?.filterNames ?? []
                let pos = info?.position ?? -1
                print("[FilterWheel] Connected: \(info?.name ?? "?"), position=\(pos), names=\(names)")
                DispatchQueue.main.async {
                    self.isConnected = true
                    self.filterNames = names
                    self.currentPosition = Int(pos)
                    self.isMoving = self.currentPosition == -1
                    self.statusMessage = info?.name ?? "Connected"
                    self.startPositionPolling()
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = "Failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func disconnect() {
        stopPositionPolling()
        try? bridge.close()
        isConnected = false
        filterNames = []
        currentPosition = -1
        isMoving = false
        statusMessage = "Not connected"
    }

    // MARK: - Filter selection

    func selectFilter(position: Int) {
        guard isConnected, position >= 0, position < filterNames.count else { return }
        isMoving = true
        currentPosition = -1
        DispatchQueue.global(qos: .userInitiated).async {
            try? self.bridge.setPosition(Int16(position))
        }
    }

    func refreshPosition() {
        guard isConnected else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let pos = (try? self.bridge.getPosition()) ?? -1
            DispatchQueue.main.async {
                self.currentPosition = Int(pos)
                self.isMoving = pos == -1
            }
        }
    }

    // MARK: - Position polling

    private func startPositionPolling() {
        stopPositionPolling()
        positionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPosition()
            }
        }
    }

    private func stopPositionPolling() {
        positionTimer?.invalidate()
        positionTimer = nil
    }
}
