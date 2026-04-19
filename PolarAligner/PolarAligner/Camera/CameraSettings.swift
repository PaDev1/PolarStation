import Foundation

/// Identifies which camera role (main imaging vs guide).
enum CameraRole: String, CaseIterable {
    case main = "Main Camera"
    case guide = "Guide Camera"
}

/// ROI presets for ASI USB cameras. Values are sensor pixels (pre-bin).
/// Smaller ROI → fewer sensor rows read out → higher frame rate. Jupiter
/// fills ~300-500 px so 1024² and 512² are the planetary sweet spots.
enum ASIRoiPreset: String, CaseIterable, Identifiable {
    case full   = "Full"
    case hd1080 = "1920×1080"
    case sq1024 = "1024²"
    case sq512  = "512²"
    case sq256  = "256²"

    var id: String { rawValue }

    /// Returns (width, height) in sensor pixels, or nil for full sensor.
    var dimensions: (width: Int, height: Int)? {
        switch self {
        case .full:   return nil
        case .hd1080: return (1920, 1080)
        case .sq1024: return (1024, 1024)
        case .sq512:  return (512, 512)
        case .sq256:  return (256, 256)
        }
    }
}

/// Camera configuration for the alignment workflow.
struct CameraSettings {
    /// Exposure time in milliseconds.
    var exposureMs: Double = 500

    /// Sensor gain (0-500 typical for ASI585MC).
    var gain: Int = 300

    /// Binning factor (1 = full res, 2 = 2x2 binning).
    var binning: Int = 2

    /// Output image format.
    var imageFormat: ASIImageFormat = .raw16

    /// ROI width in sensor pixels (pre-binning). nil → full sensor width.
    /// Set by user via the ROI preset picker (ASI USB only).
    var roiWidth: Int? = nil

    /// ROI height in sensor pixels (pre-binning). nil → full sensor height.
    var roiHeight: Int? = nil

    /// Target cooler temperature in Celsius. nil = cooler off.
    var coolerTargetC: Int? = nil

    /// Exposure time in microseconds (SDK unit).
    var exposureMicroseconds: Int {
        Int(exposureMs * 1000)
    }

    /// Recommended wait timeout for getVideoData (ms).
    var captureTimeoutMs: Int {
        Int(exposureMs * 2) + 500
    }

    /// Bytes per pixel for the current format.
    var bytesPerPixel: Int {
        switch imageFormat {
        case .raw8, .y8: return 1
        case .raw16:     return 2
        case .rgb24:     return 3
        }
    }

    /// Buffer size needed for one frame at the given dimensions (post-binning).
    func bufferSize(width: Int, height: Int) -> Int {
        width * height * bytesPerPixel
    }
}
