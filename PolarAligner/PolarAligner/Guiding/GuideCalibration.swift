import Foundation

/// Result of guide camera calibration — maps pixel displacements to mount axis corrections.
///
/// Determined by the PHD2-style calibration procedure: pulse the mount in RA and Dec,
/// measure star displacement in the camera frame, compute the angle and rate for each axis.
struct GuideCalibration: Codable {
    /// Direction of RA movement in the camera frame (radians).
    let raAngle: Double

    /// Direction of Dec movement in the camera frame (radians).
    let decAngle: Double

    /// RA movement rate: pixels per millisecond at the guide speed used during calibration.
    let raRate: Double

    /// Dec movement rate: pixels per millisecond at the guide speed used during calibration.
    let decRate: Double

    /// Camera binning at calibration time.
    let binning: Int

    /// When this calibration was performed.
    let timestamp: Date

    /// Transform a pixel displacement (dx, dy) in the camera frame into
    /// guide correction durations (milliseconds) for RA and Dec axes.
    ///
    /// Returns signed values: positive = positive axis direction.
    func pixelToGuideMs(dx: Double, dy: Double) -> (raMs: Double, decMs: Double) {
        // Project displacement onto each axis
        let raProjection = dx * cos(raAngle) + dy * sin(raAngle)
        let decProjection = dx * cos(decAngle) + dy * sin(decAngle)

        let raMs = raRate > 0 ? raProjection / raRate : 0
        let decMs = decRate > 0 ? decProjection / decRate : 0

        return (raMs, decMs)
    }

    /// Calibration summary for display.
    var summary: String {
        let raDeg = raAngle * 180.0 / .pi
        let decDeg = decAngle * 180.0 / .pi
        return String(format: "RA %.1f° (%.3f px/ms)  Dec %.1f° (%.3f px/ms)",
                       raDeg, raRate, decDeg, decRate)
    }
}
