import Foundation

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
