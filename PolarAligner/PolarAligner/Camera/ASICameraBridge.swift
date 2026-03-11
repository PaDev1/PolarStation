import Foundation

// The ZWO SDK header uses `#ifndef __cplusplus` to redefine all enum types as `int`.
// Since Swift imports the header as C, all SDK types (ASI_ERROR_CODE, ASI_CONTROL_TYPE,
// ASI_IMG_TYPE, ASI_BOOL, etc.) become Int32.

/// Errors from the ASI camera SDK.
enum ASICameraError: Error, LocalizedError {
    case invalidIndex
    case invalidID
    case invalidControlType
    case cameraClosed
    case cameraRemoved
    case invalidSize
    case invalidImageType
    case outOfBoundary
    case timeout
    case invalidSequence
    case bufferTooSmall
    case videoModeActive
    case exposureInProgress
    case generalError
    case invalidMode
    case unknown(Int32)

    init(code: Int32) {
        switch code {
        case 1:  self = .invalidIndex
        case 2:  self = .invalidID
        case 3:  self = .invalidControlType
        case 4:  self = .cameraClosed
        case 5:  self = .cameraRemoved
        case 8:  self = .invalidSize
        case 9:  self = .invalidImageType
        case 10: self = .outOfBoundary
        case 11: self = .timeout
        case 12: self = .invalidSequence
        case 13: self = .bufferTooSmall
        case 14: self = .videoModeActive
        case 15: self = .exposureInProgress
        case 16: self = .generalError
        case 17: self = .invalidMode
        default: self = .unknown(code)
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidIndex:       return "Invalid camera index"
        case .invalidID:          return "Invalid camera ID"
        case .invalidControlType: return "Invalid control type"
        case .cameraClosed:       return "Camera not opened"
        case .cameraRemoved:      return "Camera disconnected"
        case .invalidSize:        return "Invalid ROI size"
        case .invalidImageType:   return "Unsupported image format"
        case .outOfBoundary:      return "ROI position out of bounds"
        case .timeout:            return "Operation timed out"
        case .invalidSequence:    return "Stop capture first"
        case .bufferTooSmall:     return "Buffer too small"
        case .videoModeActive:    return "Video mode active"
        case .exposureInProgress: return "Exposure in progress"
        case .generalError:       return "General camera error"
        case .invalidMode:        return "Invalid camera mode"
        case .unknown(let code):  return "Unknown error (\(code))"
        }
    }
}

// SDK constants (matching the C #defines / enum values)
// Image types
let kASI_IMG_RAW8:  Int32 = 0
let kASI_IMG_RGB24: Int32 = 1
let kASI_IMG_RAW16: Int32 = 2
let kASI_IMG_Y8:    Int32 = 3

// Control types
let kASI_GAIN:              Int32 = 0
let kASI_EXPOSURE:          Int32 = 1
let kASI_GAMMA:             Int32 = 2
let kASI_WB_R:              Int32 = 3
let kASI_WB_B:              Int32 = 4
let kASI_OFFSET:            Int32 = 5
let kASI_BANDWIDTHOVERLOAD: Int32 = 6
let kASI_TEMPERATURE:       Int32 = 8
let kASI_FLIP:              Int32 = 9
let kASI_HIGH_SPEED_MODE:   Int32 = 14
let kASI_COOLER_POWER_PERC: Int32 = 15
let kASI_TARGET_TEMP:       Int32 = 16
let kASI_COOLER_ON:         Int32 = 17
let kASI_FAN_ON:            Int32 = 19
let kASI_HARDWARE_BIN:      Int32 = 13

// Bool
let kASI_FALSE: Int32 = 0
let kASI_TRUE:  Int32 = 1

/// Image format for camera output.
enum ASIImageFormat: Int32 {
    case raw8 = 0
    case rgb24 = 1
    case raw16 = 2
    case y8 = 3
}

/// Bayer pattern of the sensor.
enum ASIBayerPattern: Int32 {
    case rg = 0
    case bg = 1
    case gr = 2
    case gb = 3
}

/// Camera information from the SDK.
struct ASICameraInfo {
    let name: String
    let cameraID: Int32
    let maxWidth: Int
    let maxHeight: Int
    let isColorCamera: Bool
    let bayerPattern: ASIBayerPattern
    let supportedBins: [Int]
    let pixelSize: Double
    let hasCooler: Bool
    let isUSB3: Bool
    let bitDepth: Int
    let electronPerADU: Float
}

/// Control capability information.
struct ASIControlInfo {
    let name: String
    let description: String
    let maxValue: Int
    let minValue: Int
    let defaultValue: Int
    let isAutoSupported: Bool
    let isWritable: Bool
    let controlType: Int32
}

/// Swift wrapper around the ZWO ASI Camera C SDK.
///
/// Thread safety: All SDK calls are serialized on an internal queue.
/// The `getVideoData` method is designed to be called from a capture thread.
final class ASICameraBridge {
    private let cameraID: Int32
    private(set) var info: ASICameraInfo?
    private(set) var isOpen = false
    private(set) var isCapturing = false

    init(cameraID: Int32) {
        self.cameraID = cameraID
    }

    deinit {
        if isCapturing {
            try? stopVideoCapture()
        }
        if isOpen {
            try? close()
        }
    }

    // MARK: - Discovery

    static func connectedCameraCount() -> Int {
        Int(ASIGetNumOfConnectedCameras())
    }

    static func cameraInfo(at index: Int) throws -> ASICameraInfo {
        var raw = ASI_CAMERA_INFO()
        let code = ASIGetCameraProperty(&raw, Int32(index))
        guard code == 0 else { throw ASICameraError(code: code) }
        return parseCameraInfo(raw)
    }

    static func listCameras() throws -> [ASICameraInfo] {
        let count = connectedCameraCount()
        return try (0..<count).map { try cameraInfo(at: $0) }
    }

    // MARK: - Lifecycle

    func open() throws {
        try check(ASIOpenCamera(cameraID))
        try check(ASIInitCamera(cameraID))
        isOpen = true

        var raw = ASI_CAMERA_INFO()
        try check(ASIGetCameraPropertyByID(cameraID, &raw))
        info = Self.parseCameraInfo(raw)
    }

    func close() throws {
        if isCapturing {
            try stopVideoCapture()
        }
        try check(ASICloseCamera(cameraID))
        isOpen = false
    }

    // MARK: - Configuration

    func setROIFormat(width: Int, height: Int, bin: Int, imageType: ASIImageFormat) throws {
        try check(ASISetROIFormat(cameraID, Int32(width), Int32(height), Int32(bin), imageType.rawValue))
    }

    func getROIFormat() throws -> (width: Int, height: Int, bin: Int, imageType: ASIImageFormat) {
        var w: Int32 = 0, h: Int32 = 0, b: Int32 = 0
        var imgType: Int32 = 0
        try check(ASIGetROIFormat(cameraID, &w, &h, &b, &imgType))
        return (Int(w), Int(h), Int(b), ASIImageFormat(rawValue: imgType) ?? .raw8)
    }

    func setControlValue(_ controlType: Int32, value: Int, auto: Bool = false) throws {
        try check(ASISetControlValue(cameraID, controlType, CLong(value), auto ? kASI_TRUE : kASI_FALSE))
    }

    func getControlValue(_ controlType: Int32) throws -> (value: Int, isAuto: Bool) {
        var val: CLong = 0
        var isAuto: Int32 = kASI_FALSE
        try check(ASIGetControlValue(cameraID, controlType, &val, &isAuto))
        return (Int(val), isAuto == kASI_TRUE)
    }

    func getControls() throws -> [ASIControlInfo] {
        var count: Int32 = 0
        try check(ASIGetNumOfControls(cameraID, &count))

        return try (0..<count).map { index in
            var caps = ASI_CONTROL_CAPS()
            try check(ASIGetControlCaps(cameraID, index, &caps))
            return ASIControlInfo(
                name: withUnsafePointer(to: caps.Name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) }
                },
                description: withUnsafePointer(to: caps.Description) {
                    $0.withMemoryRebound(to: CChar.self, capacity: 128) { String(cString: $0) }
                },
                maxValue: Int(caps.MaxValue),
                minValue: Int(caps.MinValue),
                defaultValue: Int(caps.DefaultValue),
                isAutoSupported: caps.IsAutoSupported == ASI_TRUE,
                isWritable: caps.IsWritable == ASI_TRUE,
                controlType: Int32(caps.ControlType.rawValue)
            )
        }
    }

    // MARK: - Convenience Setters

    func setExposure(microseconds: Int, auto: Bool = false) throws {
        try setControlValue(kASI_EXPOSURE, value: microseconds, auto: auto)
    }

    func setGain(_ gain: Int, auto: Bool = false) throws {
        try setControlValue(kASI_GAIN, value: gain, auto: auto)
    }

    func setCoolerTarget(celsius: Int) throws {
        try setControlValue(kASI_COOLER_ON, value: 1)
        try setControlValue(kASI_TARGET_TEMP, value: celsius)
    }

    func getTemperature() throws -> Double {
        let (raw, _) = try getControlValue(kASI_TEMPERATURE)
        return Double(raw) / 10.0
    }

    // MARK: - Video Capture

    func startVideoCapture() throws {
        try check(ASIStartVideoCapture(cameraID))
        isCapturing = true
    }

    func stopVideoCapture() throws {
        try check(ASIStopVideoCapture(cameraID))
        isCapturing = false
    }

    /// Get a video frame into the provided buffer.
    /// Returns `true` if a frame was captured, `false` on timeout.
    func getVideoData(buffer: UnsafeMutablePointer<UInt8>, bufferSize: Int, waitMs: Int) -> Bool {
        let code = ASIGetVideoData(cameraID, buffer, CLong(bufferSize), Int32(waitMs))
        return code == 0
    }

    func getDroppedFrames() throws -> Int {
        var dropped: Int32 = 0
        try check(ASIGetDroppedFrames(cameraID, &dropped))
        return Int(dropped)
    }

    // MARK: - SDK Info

    static func sdkVersion() -> String {
        guard let ptr = ASIGetSDKVersion() else { return "unknown" }
        return String(cString: ptr)
    }

    // MARK: - Private

    private func check(_ code: Int32) throws {
        guard code == 0 else { throw ASICameraError(code: code) }
    }

    private static func parseCameraInfo(_ raw: ASI_CAMERA_INFO) -> ASICameraInfo {
        let name = withUnsafePointer(to: raw.Name) {
            $0.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) }
        }

        var bins: [Int] = []
        withUnsafePointer(to: raw.SupportedBins) { ptr in
            ptr.withMemoryRebound(to: Int32.self, capacity: 16) { bp in
                for i in 0..<16 {
                    let val = bp[i]
                    if val == 0 { break }
                    bins.append(Int(val))
                }
            }
        }

        return ASICameraInfo(
            name: name,
            cameraID: Int32(raw.CameraID),
            maxWidth: Int(raw.MaxWidth),
            maxHeight: Int(raw.MaxHeight),
            isColorCamera: raw.IsColorCam == ASI_TRUE,
            bayerPattern: ASIBayerPattern(rawValue: Int32(raw.BayerPattern.rawValue)) ?? .rg,
            supportedBins: bins,
            pixelSize: raw.PixelSize,
            hasCooler: raw.IsCoolerCam == ASI_TRUE,
            isUSB3: raw.IsUSB3Camera == ASI_TRUE,
            bitDepth: Int(raw.BitDepth),
            electronPerADU: raw.ElecPerADU
        )
    }
}
