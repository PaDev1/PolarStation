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
    var minSNR: Double = 8.0

    /// Maximum number of stars to return.
    var maxStars: Int = 200

    /// Gaussian blur sigma for background estimation (pixels).
    var backgroundSigma: Float = 10.0

    /// Detection threshold in sigma above background.
    var detectionSigma: Float = 3.0

    /// Half-width of the centroid window (pixels). Window is (2*hw+1)^2.
    var centroidHalfWidth: Int = 5

    /// Minimum separation between detections (pixels).
    var minSeparation: Float = 5.0
}
