import Foundation

/// A loop/exit condition on a container.
///
/// Conditions are evaluated after each container iteration.
/// The loop stops when ANY condition is met (OR logic for termination).
struct SequenceCondition: Codable, Identifiable, Hashable {
    let id: UUID
    var type: String
    var enabled: Bool
    var params: [String: AnyCodableValue]

    init(type: String, params: [String: AnyCodableValue] = [:]) {
        self.id = UUID()
        self.type = type
        self.enabled = true
        self.params = params
    }
}

extension SequenceCondition {
    // Iteration / count limits
    static let loopCount = "loop_count"
    static let frameCount = "frame_count"
    static let timeElapsed = "time_elapsed"

    // Time-based
    static let loopUntilTime = "loop_until_time"
    static let loopUntilLocalTime = "loop_until_local_time"

    // Altitude / celestial
    static let targetAltitudeBelow = "target_altitude_below"
    static let targetAltitudeAbove = "target_altitude_above"
    static let sunAltitudeAbove = "sun_altitude_above"

    // All available condition types for the UI picker
    static let allTypes: [(type: String, label: String, defaultParams: [String: AnyCodableValue])] = [
        (loopCount, "Loop Count", ["count": .int(1)]),
        (frameCount, "Frame Count", ["count": .int(30)]),
        (timeElapsed, "Time Elapsed", ["minutes": .int(60)]),
        (loopUntilLocalTime, "Until Local Time", ["hour": .int(6), "minute": .int(0)]),
        (loopUntilTime, "Until UTC Time", ["utc_time": .string("")]),
        (targetAltitudeBelow, "Target Below Altitude", ["min_altitude_deg": .int(30)]),
        (targetAltitudeAbove, "Target Above Altitude", ["min_altitude_deg": .int(30)]),
        (sunAltitudeAbove, "Sun Above Altitude", ["altitude_deg": .int(-12)]),
    ]
}
