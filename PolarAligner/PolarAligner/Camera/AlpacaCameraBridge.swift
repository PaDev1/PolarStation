import Foundation
import PolarCore

/// Swift wrapper around the Rust AlpacaCameraController.
/// Provides a similar interface shape to ASICameraBridge for interchangeable use.
final class AlpacaCameraBridge {
    private let controller = AlpacaCameraController()
    private(set) var info: AlpacaCameraInfo?
    private(set) var isOpen = false

    /// Current binning (set from CameraSettings).
    private(set) var currentBin: Int = 1

    /// Connect to an Alpaca camera at the given host:port/device.
    func open(host: String, port: UInt32, deviceNumber: UInt32 = 0) throws {
        let camInfo = try controller.connect(host: host, port: port, deviceNumber: deviceNumber)
        info = camInfo
        isOpen = true
    }

    func close() throws {
        try controller.disconnect()
        isOpen = false
        info = nil
    }

    /// Check if the ASCOM device reports itself as connected.
    /// Uses the standard Alpaca GET /connected property.
    func healthCheck() -> Bool {
        controller.isConnected()
    }

    /// Configure binning and gain.
    func configure(bin: Int, gain: Int) throws {
        try controller.setBinning(bin: UInt8(bin))
        try controller.setGain(gain: Int32(gain))
        currentBin = bin
    }

    /// Start a single exposure (duration in seconds).
    func startExposure(durationSecs: Double) throws {
        try controller.startExposure(durationSecs: durationSecs)
    }

    /// Poll whether the image is ready for download.
    func isImageReady() throws -> Bool {
        try controller.isImageReady()
    }

    /// Download the raw image bytes (16-bit LE pixel data).
    func downloadImage() throws -> Data {
        try controller.downloadImage()
    }

    func getTemperature() throws -> Double {
        try controller.getTemperature()
    }

    func setCooler(enabled: Bool, targetCelsius: Double) throws {
        try controller.setCooler(enabled: enabled, targetCelsius: targetCelsius)
    }

    func abortExposure() throws {
        try controller.abortExposure()
    }

    /// Convert AlpacaCameraInfo to ASICameraInfo for compatibility with existing UI.
    func toASICameraInfo() -> ASICameraInfo? {
        guard let info = info else { return nil }

        // Determine Bayer pattern from sensor type + offsets
        let bayerPattern: ASIBayerPattern
        if info.sensorType >= 2 {
            // Color sensor: use bayer offsets to determine pattern
            // offset (0,0)=RGGB, (1,0)=GRBG, (0,1)=GBRG, (1,1)=BGGR
            let idx = Int(info.bayerOffsetY) * 2 + Int(info.bayerOffsetX)
            bayerPattern = ASIBayerPattern(rawValue: Int32(idx)) ?? .rg
        } else {
            bayerPattern = .rg
        }

        // Generate supported bins list (1..maxBin)
        let bins = (1...Int(max(info.maxBin, 1))).map { $0 }

        return ASICameraInfo(
            name: info.name + " (Alpaca)",
            cameraID: -1,  // Not a real ASI camera ID
            maxWidth: Int(info.width),
            maxHeight: Int(info.height),
            isColorCamera: info.sensorType >= 2,
            bayerPattern: bayerPattern,
            supportedBins: bins,
            pixelSize: info.pixelSizeX,
            hasCooler: info.hasCooler,
            isUSB3: false,
            bitDepth: info.maxAdu > 4095 ? 16 : 12,
            electronPerADU: 0
        )
    }
}
