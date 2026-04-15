import Foundation
import Metal

/// A detected star candidate with sub-pixel position and brightness.
struct DetectedStar: Sendable {
    /// Sub-pixel X coordinate in the full-resolution image.
    let x: Double
    /// Sub-pixel Y coordinate in the full-resolution image.
    let y: Double
    /// Integrated brightness (ADU sum in the centroid window).
    let brightness: Double
    /// Estimated FWHM in pixels (0 if not computed).
    let fwhm: Double
    /// Signal-to-noise ratio estimate.
    let snr: Double
}

/// Protocol for star detection backends.
///
/// Both the classical MPS pipeline and the Core ML UNet implement this protocol.
protocol StarDetectorProtocol {
    /// Detect stars in a debayered grayscale floating-point image.
    ///
    /// - Parameters:
    ///   - texture: Input texture (rgba16Float or r16Float, debayered).
    ///   - device: Metal device for GPU operations.
    ///   - commandQueue: Metal command queue.
    /// - Returns: Array of detected stars sorted by brightness (brightest first).
    func detectStars(
        in texture: MTLTexture,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> [DetectedStar]
}

/// Configuration for star detection.
struct StarDetectionConfig {
    /// Minimum SNR for a detection to be accepted.
    var minSNR: Double = 4.0

    /// Maximum number of stars to return.
    var maxStars: Int = 200

    /// Gaussian blur sigma for background estimation (pixels).
    /// Should be several times larger than the largest star FWHM so stars
    /// don't get partially absorbed into the background estimate.
    var backgroundSigma: Float = 16.0

    /// Detection threshold in sigma above background.
    var detectionSigma: Float = 3.0

    /// Half-width of the centroid window (pixels). Window is (2*hw+1)^2.
    var centroidHalfWidth: Int = 5

    /// Minimum separation between detections (pixels).
    var minSeparation: Float = 5.0

    /// Preset for sharp diffraction-limited stars (good optics).
    static var sharp: StarDetectionConfig {
        var c = StarDetectionConfig()
        c.minSNR = 6.0
        c.backgroundSigma = 8.0
        c.detectionSigma = 4.0
        c.centroidHalfWidth = 4
        c.minSeparation = 4.0
        return c
    }

    /// Preset for diffuse / bloated stars (less-sharp optics, defocus, fast f-ratio aberrations).
    static var diffused: StarDetectionConfig {
        var c = StarDetectionConfig()
        c.minSNR = 3.5
        c.backgroundSigma = 20.0
        c.detectionSigma = 2.5
        c.centroidHalfWidth = 7
        c.minSeparation = 8.0
        return c
    }
}

/// User-selectable star shape preset.
enum StarDetectorMode: String, CaseIterable, Identifiable {
    case sharp     = "Sharp"
    case diffused  = "Diffused"
    var id: String { rawValue }
    var config: StarDetectionConfig {
        switch self {
        case .sharp:    return .sharp
        case .diffused: return .diffused
        }
    }
}
