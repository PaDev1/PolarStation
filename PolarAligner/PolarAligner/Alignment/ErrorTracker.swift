import Foundation
import PolarCore

/// Tracks polar alignment error over time during the adjustment phase.
///
/// After the initial three-point alignment determines the error, the ErrorTracker
/// maintains a running estimate by:
/// 1. Re-plate-solving periodically for absolute position updates
/// 2. Interpolating between solves using centroid displacement + plate scale
///
/// This enables <200ms visual feedback as the user turns adjustment screws.
@MainActor
final class ErrorTracker: ObservableObject {

    // MARK: - Published state

    /// Current estimated polar error (updated every frame or solve).
    @Published var currentError: PolarError?

    /// History of error measurements for plotting.
    @Published var errorHistory: [ErrorSample] = []

    /// Whether the tracker is actively monitoring.
    @Published var isTracking = false

    /// Status message for the UI.
    @Published var statusMessage = "Ready"

    // MARK: - Configuration

    /// Plate scale in arcseconds per pixel (set from FOV + image dimensions).
    var plateScaleArcsecPerPixel: Double = 0

    /// How many frames between full plate solves.
    var solveInterval: Int = 10

    /// Observer location for coordinate transforms.
    var observerLatDeg: Double = 60.17
    var observerLonDeg: Double = 24.94

    // MARK: - Internal

    private var referenceStars: [DetectedStar] = []
    private var referenceError: PolarError?
    private var framesSinceSolve: Int = 0
    private let matcher = StarMatcher()

    struct ErrorSample {
        let timestamp: Date
        let altArcmin: Double
        let azArcmin: Double
        let totalArcmin: Double
        let source: Source

        enum Source {
            case plateSolve   // absolute from full solve
            case interpolated // estimated from centroid tracking
        }
    }

    // MARK: - Setup

    /// Configure plate scale from FOV and image dimensions.
    func setPlateScale(fovDeg: Double, imageWidthPx: Int) {
        plateScaleArcsecPerPixel = (fovDeg * 3600.0) / Double(imageWidthPx)
    }

    /// Start tracking from an initial known error (from three-point alignment).
    func startTracking(initialError: PolarError) {
        currentError = initialError
        referenceError = initialError
        referenceStars = []
        framesSinceSolve = 0
        errorHistory = [ErrorSample(
            timestamp: Date(),
            altArcmin: initialError.altErrorArcmin,
            azArcmin: initialError.azErrorArcmin,
            totalArcmin: initialError.totalErrorArcmin,
            source: .plateSolve
        )]
        isTracking = true
        statusMessage = String(format: "Tracking — %.1f' error", initialError.totalErrorArcmin)
    }

    /// Stop tracking.
    func stopTracking() {
        isTracking = false
        referenceStars = []
        statusMessage = "Stopped"
    }

    /// Process detected stars from a new frame.
    ///
    /// If we have reference stars, computes displacement to interpolate error.
    /// Every `solveInterval` frames, requests a full plate solve via the callback.
    ///
    /// - Parameters:
    ///   - stars: Detected star centroids from the current frame.
    ///   - requestSolve: Callback to trigger a full plate solve. Called every N frames.
    func processStars(_ stars: [DetectedStar], requestSolve: (() -> Void)? = nil) {
        guard isTracking else { return }
        framesSinceSolve += 1

        if referenceStars.isEmpty {
            // First frame after start or solve — set as reference
            referenceStars = stars
            return
        }

        // Match current stars to reference
        let matches = matcher.match(reference: referenceStars, current: stars)
        if matches.count >= 3 {
            let (dx, dy) = StarMatcher.medianDisplacement(matches)
            interpolateError(dx: dx, dy: dy)
        }

        // Request periodic full solve
        if framesSinceSolve >= solveInterval {
            framesSinceSolve = 0
            requestSolve?()
        }
    }

    /// Update with an absolute plate-solve result.
    ///
    /// Called when PlateSolveService returns a new solution. This resets
    /// the reference frame for future interpolation.
    func updateFromSolve(error: PolarError, stars: [DetectedStar]) {
        referenceError = error
        referenceStars = stars
        currentError = error
        framesSinceSolve = 0

        let sample = ErrorSample(
            timestamp: Date(),
            altArcmin: error.altErrorArcmin,
            azArcmin: error.azErrorArcmin,
            totalArcmin: error.totalErrorArcmin,
            source: .plateSolve
        )
        errorHistory.append(sample)
        trimHistory()

        statusMessage = String(format: "%.1f' (solve)", error.totalErrorArcmin)
    }

    // MARK: - Private

    /// Estimate error change from centroid displacement using plate scale.
    ///
    /// The displacement in pixels maps to angular shift on the sky.
    /// For polar alignment, vertical displacement ≈ altitude error change,
    /// horizontal displacement ≈ azimuth error change (at the pole).
    private func interpolateError(dx: Double, dy: Double) {
        guard let refErr = referenceError, plateScaleArcsecPerPixel > 0 else { return }

        // Convert pixel displacement to arcminutes
        let dAltArcmin = -dy * plateScaleArcsecPerPixel / 60.0  // -Y is up = altitude increase
        let dAzArcmin = dx * plateScaleArcsecPerPixel / 60.0

        let newAlt = refErr.altErrorArcmin + dAltArcmin
        let newAz = refErr.azErrorArcmin + dAzArcmin
        let newTotal = sqrt(newAlt * newAlt + newAz * newAz)

        let interpolated = PolarError(
            altErrorArcmin: newAlt,
            azErrorArcmin: newAz,
            totalErrorArcmin: newTotal,
            mountAxis: refErr.mountAxis
        )
        currentError = interpolated

        let sample = ErrorSample(
            timestamp: Date(),
            altArcmin: newAlt,
            azArcmin: newAz,
            totalArcmin: newTotal,
            source: .interpolated
        )
        errorHistory.append(sample)
        trimHistory()

        statusMessage = String(format: "%.1f' (tracking)", newTotal)
    }

    /// Keep only the last 5 minutes of history.
    private func trimHistory() {
        let cutoff = Date().addingTimeInterval(-300)
        errorHistory.removeAll { $0.timestamp < cutoff }
    }
}
