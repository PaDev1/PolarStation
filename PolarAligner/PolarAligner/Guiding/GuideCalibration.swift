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
        return String(format: "RA %.1f° (%.4f px/ms)  Dec %.1f° (%.4f px/ms)",
                       raDeg, raRate, decDeg, decRate)
    }

    /// Angle between RA and Dec axes in degrees. Should be close to 90°.
    var axisOrthogonality: Double {
        var diff = abs(raAngle - decAngle) * 180.0 / .pi
        if diff > 180 { diff = 360 - diff }
        return diff
    }

    /// Whether the calibration looks valid.
    var isValid: Bool {
        // Axes should be roughly perpendicular (70°-110°)
        let ortho = axisOrthogonality
        guard ortho > 70 && ortho < 110 else { return false }
        // Rates should be positive and reasonable
        guard raRate > 0.0001 && decRate > 0.0001 else { return false }
        return true
    }

    /// Age of this calibration.
    var age: TimeInterval { Date().timeIntervalSince(timestamp) }

    /// Human-readable age string.
    var ageString: String {
        let hours = age / 3600
        if hours < 1 { return String(format: "%.0f min ago", age / 60) }
        if hours < 24 { return String(format: "%.1f hours ago", hours) }
        return String(format: "%.0f days ago", hours / 24)
    }

    // MARK: - Persistence

    private static let storageKey = "guideCalibration"

    /// Save to UserDefaults.
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    /// Load from UserDefaults.
    static func load() -> GuideCalibration? {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let cal = try? JSONDecoder().decode(GuideCalibration.self, from: data) else {
            return nil
        }
        return cal
    }

    /// Remove saved calibration.
    static func clear() {
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
    }
}
