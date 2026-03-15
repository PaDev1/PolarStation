import Foundation
import PolarCore

/// Manages observing conditions (weather station) lifecycle: discovery, connection, and sensor monitoring.
@MainActor
final class ObservingConditionsViewModel: ObservableObject {

    @Published var isConnected = false
    @Published var temperature: Double = -999
    @Published var humidity: Double = -999
    @Published var dewpoint: Double = -999
    @Published var pressure: Double = -999
    @Published var windSpeed: Double = -999
    @Published var windDirection: Double = -999
    @Published var cloudCover: Double = -999
    @Published var skyBrightness: Double = -999
    @Published var skyTemperature: Double = -999
    @Published var starFwhm: Double = -999
    @Published var statusMessage = "Not connected"

    @Published var alpacaDevices: [AlpacaDeviceInfo] = []
    @Published var selectedAlpacaDevice: Int = -1
    @Published var isDiscoveringDevices = false

    private let bridge = AlpacaObservingConditionsBridge()
    private var pollTimer: Timer?
    private var isPolling = false

    func discoverDevices(host: String, port: UInt32) {
        isDiscoveringDevices = true
        DispatchQueue.global(qos: .userInitiated).async {
            let devices = (try? PolarCore.discoverAlpacaObservingconditions(host: host, port: UInt16(port))) ?? []
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
                    self.statusMessage = info?.name ?? "Connected"
                    self.refreshStatus()
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
            let temp = self.bridge.getTemperature()
            let hum = self.bridge.getHumidity()
            let dew = self.bridge.getDewpoint()
            let pres = self.bridge.getPressure()
            let ws = self.bridge.getWindSpeed()
            let wd = self.bridge.getWindDirection()
            let cc = self.bridge.getCloudCover()
            let sb = self.bridge.getSkyBrightness()
            let st = self.bridge.getSkyTemperature()
            let fwhm = self.bridge.getStarFwhm()
            DispatchQueue.main.async {
                self.temperature = temp
                self.humidity = hum
                self.dewpoint = dew
                self.pressure = pres
                self.windSpeed = ws
                self.windDirection = wd
                self.cloudCover = cc
                self.skyBrightness = sb
                self.skyTemperature = st
                self.starFwhm = fwhm
                self.isPolling = false
            }
        }
    }

    private func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}

// MARK: - Bridge

final class AlpacaObservingConditionsBridge {
    private let controller = AlpacaObservingConditionsController()
    private(set) var info: AlpacaObservingConditionsInfo?
    private(set) var isOpen = false

    func open(host: String, port: UInt32, deviceNumber: UInt32 = 0) throws {
        let ocInfo = try controller.connect(host: host, port: port, deviceNumber: deviceNumber)
        info = ocInfo
        isOpen = true
    }

    func close() throws {
        try controller.disconnect()
        isOpen = false
        info = nil
    }

    func getTemperature() -> Double { controller.getTemperature() }
    func getHumidity() -> Double { controller.getHumidity() }
    func getDewpoint() -> Double { controller.getDewpoint() }
    func getPressure() -> Double { controller.getPressure() }
    func getWindSpeed() -> Double { controller.getWindSpeed() }
    func getWindDirection() -> Double { controller.getWindDirection() }
    func getCloudCover() -> Double { controller.getCloudCover() }
    func getSkyBrightness() -> Double { controller.getSkyBrightness() }
    func getSkyTemperature() -> Double { controller.getSkyTemperature() }
    func getStarFwhm() -> Double { controller.getStarFwhm() }
}
