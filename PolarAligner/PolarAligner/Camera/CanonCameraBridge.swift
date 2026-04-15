import Foundation
import AppKit
import CoreGraphics

/// Errors from the Canon EDSDK.
enum CanonCameraError: Error, LocalizedError {
    case sdkNotInitialized
    case noCameraFound
    case sessionFailed(EdsError)
    case liveViewFailed(EdsError)
    case downloadFailed(EdsError)
    case objectNotReady
    case propertyError(EdsError)
    case invalidImageData
    case unknown(EdsError)

    var errorDescription: String? {
        switch self {
        case .sdkNotInitialized: return "Canon EDSDK not initialized"
        case .noCameraFound:     return "No Canon camera connected"
        case .sessionFailed(let e): return "Open session failed (\(String(format: "0x%X", e)))"
        case .liveViewFailed(let e): return "Live view failed (\(String(format: "0x%X", e)))"
        case .downloadFailed(let e): return "Download failed (\(String(format: "0x%X", e)))"
        case .objectNotReady: return "Camera not ready"
        case .propertyError(let e): return "Property error (\(String(format: "0x%X", e)))"
        case .invalidImageData: return "Invalid image data"
        case .unknown(let e): return "Canon error (\(String(format: "0x%X", e)))"
        }
    }
}

/// Basic info about a discovered Canon camera.
struct CanonCameraInfo {
    let productName: String
    let bodyIDEx: String
    let index: Int
}

/// Bridge to the Canon EDSDK. Wraps session management, live view, and still capture.
///
/// Thread model: EDSDK is not thread-safe on macOS — all calls go through `sdkQueue`.
/// Event pumping (`EdsGetEvent`) must run on a regular basis on macOS; see `CanonCameraEvents`.
final class CanonCameraBridge {

    /// Shared serial queue for all EDSDK calls.
    static let sdkQueue = DispatchQueue(label: "com.polaraligner.canon-sdk")

    private var cameraRef: EdsCameraRef?
    private var isOpen = false
    private var evfActive = false
    private(set) var info: CanonCameraInfo?

    /// Called on the SDK queue when a new still image is ready to download.
    /// The directory item must be released with `EdsRelease` after download.
    var onStillCaptured: ((EdsDirectoryItemRef) -> Void)?

    // MARK: - SDK lifecycle

    /// Initialize the SDK. Must be called once before any other operation.
    /// On macOS this MUST run on the main thread.
    static var isSDKInitialized = false
    static func initializeSDK() throws {
        if isSDKInitialized { return }
        var err: EdsError = 0
        if Thread.isMainThread {
            err = EdsInitializeSDK()
        } else {
            DispatchQueue.main.sync {
                err = EdsInitializeSDK()
            }
        }
        if err != EdsError(EDS_ERR_OK) {
            throw CanonCameraError.sdkNotInitialized
        }
        isSDKInitialized = true
    }

    static func terminateSDK() {
        guard isSDKInitialized else { return }
        EdsTerminateSDK()
        isSDKInitialized = false
    }

    // MARK: - Discovery

    /// List connected Canon cameras. Call `initializeSDK()` first.
    static func listCameras() throws -> [CanonCameraInfo] {
        try initializeSDK()

        var cameraList: EdsCameraListRef?
        var err = EdsGetCameraList(&cameraList)
        guard err == EdsError(EDS_ERR_OK), let list = cameraList else {
            throw CanonCameraError.unknown(err)
        }
        defer { EdsRelease(list) }

        var count: EdsUInt32 = 0
        err = EdsGetChildCount(list, &count)
        guard err == EdsError(EDS_ERR_OK) else {
            throw CanonCameraError.unknown(err)
        }

        var infos: [CanonCameraInfo] = []
        for i in 0..<Int(count) {
            var cam: EdsCameraRef?
            err = EdsGetChildAtIndex(list, EdsInt32(i), &cam)
            guard err == EdsError(EDS_ERR_OK), let c = cam else { continue }
            defer { EdsRelease(c) }

            var deviceInfo = EdsDeviceInfo()
            err = EdsGetDeviceInfo(c, &deviceInfo)
            if err == EdsError(EDS_ERR_OK) {
                let name = withUnsafePointer(to: &deviceInfo.szDeviceDescription) {
                    String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
                }
                infos.append(CanonCameraInfo(productName: name, bodyIDEx: "", index: i))
            }
        }
        return infos
    }

    // MARK: - Open / Close

    /// Open a camera session by discovery index.
    func open(at index: Int) throws {
        try Self.initializeSDK()

        var cameraList: EdsCameraListRef?
        var err = EdsGetCameraList(&cameraList)
        guard err == EdsError(EDS_ERR_OK), let list = cameraList else {
            throw CanonCameraError.unknown(err)
        }
        defer { EdsRelease(list) }

        var cam: EdsCameraRef?
        err = EdsGetChildAtIndex(list, EdsInt32(index), &cam)
        guard err == EdsError(EDS_ERR_OK), let c = cam else {
            throw CanonCameraError.noCameraFound
        }

        err = EdsOpenSession(c)
        if err != EdsError(EDS_ERR_OK) {
            EdsRelease(c)
            throw CanonCameraError.sessionFailed(err)
        }

        // Save images to the host (computer), not the SD card
        var saveTo: EdsUInt32 = EdsUInt32(kEdsSaveTo_Host.rawValue)
        _ = EdsSetPropertyData(c, EdsPropertyID(kEdsPropID_SaveTo), 0,
                               EdsUInt32(MemoryLayout<EdsUInt32>.size), &saveTo)

        // Set capacity so camera allows shots (required when SaveTo=Host)
        var capacity = EdsCapacity(numberOfFreeClusters: 0x7FFFFFFF,
                                   bytesPerSector: 0x1000,
                                   reset: 1)
        _ = EdsSetCapacity(c, capacity)

        // Register for DirItemRequestTransfer event (image arrived from camera)
        registerObjectEventHandler(c)

        cameraRef = c
        isOpen = true

        // Query product name for info
        var deviceInfo = EdsDeviceInfo()
        if EdsGetDeviceInfo(c, &deviceInfo) == EdsError(EDS_ERR_OK) {
            let name = withUnsafePointer(to: &deviceInfo.szDeviceDescription) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            info = CanonCameraInfo(productName: name, bodyIDEx: "", index: index)
        }
    }

    func close() {
        guard let c = cameraRef else { return }
        if evfActive { try? stopLiveView() }
        EdsCloseSession(c)
        EdsRelease(c)
        cameraRef = nil
        isOpen = false
        info = nil
    }

    // MARK: - Live View (EVF)

    /// Start live view streaming to the host.
    func startLiveView() throws {
        guard let c = cameraRef else { throw CanonCameraError.noCameraFound }

        // Enable EVF mode
        var mode: EdsUInt32 = 1
        var err = EdsSetPropertyData(c, EdsPropertyID(kEdsPropID_Evf_Mode), 0,
                                     EdsUInt32(MemoryLayout<EdsUInt32>.size), &mode)

        // Route EVF output to PC
        var device: EdsUInt32 = 0
        err = EdsGetPropertyData(c, EdsPropertyID(kEdsPropID_Evf_OutputDevice), 0,
                                 EdsUInt32(MemoryLayout<EdsUInt32>.size), &device)
        device |= EdsUInt32(kEdsEvfOutputDevice_PC.rawValue)
        err = EdsSetPropertyData(c, EdsPropertyID(kEdsPropID_Evf_OutputDevice), 0,
                                 EdsUInt32(MemoryLayout<EdsUInt32>.size), &device)
        if err != EdsError(EDS_ERR_OK) {
            throw CanonCameraError.liveViewFailed(err)
        }
        evfActive = true
    }

    /// Stop live view.
    func stopLiveView() throws {
        guard let c = cameraRef else { return }
        var device: EdsUInt32 = 0
        _ = EdsGetPropertyData(c, EdsPropertyID(kEdsPropID_Evf_OutputDevice), 0,
                               EdsUInt32(MemoryLayout<EdsUInt32>.size), &device)
        device &= ~EdsUInt32(kEdsEvfOutputDevice_PC.rawValue)
        _ = EdsSetPropertyData(c, EdsPropertyID(kEdsPropID_Evf_OutputDevice), 0,
                               EdsUInt32(MemoryLayout<EdsUInt32>.size), &device)
        evfActive = false
    }

    /// Download the current EVF frame. Returns raw JPEG bytes, or nil if not ready.
    func downloadEvfJPEG() -> Data? {
        guard let c = cameraRef, evfActive else { return nil }

        var streamRef: EdsStreamRef?
        let bufferSize: EdsUInt64 = 2 * 1024 * 1024
        var err = EdsCreateMemoryStream(bufferSize, &streamRef)
        guard err == EdsError(EDS_ERR_OK), let stream = streamRef else { return nil }
        defer { EdsRelease(stream) }

        var imageRef: EdsEvfImageRef?
        err = EdsCreateEvfImageRef(stream, &imageRef)
        guard err == EdsError(EDS_ERR_OK), let img = imageRef else { return nil }
        defer { EdsRelease(img) }

        err = EdsDownloadEvfImage(c, img)
        if err != EdsError(EDS_ERR_OK) {
            // Not-ready is a normal case when polling too fast
            return nil
        }

        var imageSize: EdsUInt64 = 0
        var pImage: UnsafeMutableRawPointer?
        EdsGetPointer(stream, &pImage)
        EdsGetLength(stream, &imageSize)
        guard let p = pImage, imageSize > 0 else { return nil }

        return Data(bytes: p, count: Int(imageSize))
    }

    // MARK: - Properties

    /// Canon white balance presets. Subset of EDSDK values, covering the most useful ones.
    enum WhiteBalance: Int32, CaseIterable {
        case auto       = 0
        case daylight   = 1
        case cloudy     = 2
        case tungsten   = 3
        case fluorescent = 4
        case flash      = 5
        case shade      = 8
        case colorTemp  = 9
        case autoWhite  = 23

        var label: String {
            switch self {
            case .auto:        return "Auto"
            case .daylight:    return "Daylight"
            case .cloudy:      return "Cloudy"
            case .tungsten:    return "Tungsten"
            case .fluorescent: return "Fluorescent"
            case .flash:       return "Flash"
            case .shade:       return "Shade"
            case .colorTemp:   return "Color Temp"
            case .autoWhite:   return "Auto (White Priority)"
            }
        }
    }

    func setWhiteBalance(_ wb: WhiteBalance) throws {
        guard let c = cameraRef else { throw CanonCameraError.noCameraFound }
        var val: EdsInt32 = wb.rawValue
        let err = EdsSetPropertyData(c, EdsPropertyID(kEdsPropID_WhiteBalance), 0,
                                     EdsUInt32(MemoryLayout<EdsInt32>.size), &val)
        if err != EdsError(EDS_ERR_OK) {
            throw CanonCameraError.propertyError(err)
        }
    }

    func getWhiteBalance() throws -> WhiteBalance {
        guard let c = cameraRef else { throw CanonCameraError.noCameraFound }
        var val: EdsInt32 = 0
        let err = EdsGetPropertyData(c, EdsPropertyID(kEdsPropID_WhiteBalance), 0,
                                     EdsUInt32(MemoryLayout<EdsInt32>.size), &val)
        if err != EdsError(EDS_ERR_OK) {
            throw CanonCameraError.propertyError(err)
        }
        return WhiteBalance(rawValue: val) ?? .auto
    }

    // MARK: - Still Capture

    /// Press shutter fully (take a picture). The image arrives asynchronously via
    /// the ObjectEvent handler (DirItemRequestTransfer) — caller wires `onStillCaptured`.
    func takePicture() throws {
        guard let c = cameraRef else { throw CanonCameraError.noCameraFound }
        let err = EdsSendCommand(c, EdsCameraCommand(kEdsCameraCommand_PressShutterButton),
                                 EdsInt32(kEdsCameraCommand_ShutterButton_Completely.rawValue))
        _ = EdsSendCommand(c, EdsCameraCommand(kEdsCameraCommand_PressShutterButton),
                           EdsInt32(kEdsCameraCommand_ShutterButton_OFF.rawValue))
        if err != EdsError(EDS_ERR_OK) {
            throw CanonCameraError.unknown(err)
        }
    }

    /// Download a pending image (from DirItemRequestTransfer event) to a file.
    func downloadImage(dirItem: EdsDirectoryItemRef, toFolder folder: URL, filenamePrefix: String) throws -> URL {
        var info = EdsDirectoryItemInfo()
        var err = EdsGetDirectoryItemInfo(dirItem, &info)
        guard err == EdsError(EDS_ERR_OK) else {
            throw CanonCameraError.downloadFailed(err)
        }

        let rawName = withUnsafePointer(to: &info.szFileName) {
            String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let outURL = folder.appendingPathComponent("\(filenamePrefix)_\(rawName)")

        var stream: EdsStreamRef?
        err = EdsCreateFileStream(outURL.path,
                                  kEdsFileCreateDisposition_CreateAlways,
                                  kEdsAccess_ReadWrite,
                                  &stream)
        guard err == EdsError(EDS_ERR_OK), let s = stream else {
            throw CanonCameraError.downloadFailed(err)
        }
        defer { EdsRelease(s) }

        err = EdsDownload(dirItem, info.size, s)
        if err != EdsError(EDS_ERR_OK) { throw CanonCameraError.downloadFailed(err) }
        err = EdsDownloadComplete(dirItem)
        if err != EdsError(EDS_ERR_OK) { throw CanonCameraError.downloadFailed(err) }

        return outURL
    }

    // MARK: - Event plumbing

    /// Process pending SDK events — must be called periodically on macOS.
    static func pumpEvents() {
        EdsGetEvent()
    }

    private func registerObjectEventHandler(_ cam: EdsCameraRef) {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        _ = EdsSetObjectEventHandler(cam, EdsObjectEvent(kEdsObjectEvent_All),
                                     { (event, object, context) -> EdsError in
            guard let context = context else { return EdsUInt32(EDS_ERR_OK) }
            let bridge = Unmanaged<CanonCameraBridge>.fromOpaque(context).takeUnretainedValue()
            if event == EdsObjectEvent(kEdsObjectEvent_DirItemRequestTransfer),
               let obj = object {
                bridge.onStillCaptured?(obj)
            } else if let obj = object {
                EdsRelease(obj)
            }
            return EdsUInt32(EDS_ERR_OK)
        }, ctx)
    }
}
