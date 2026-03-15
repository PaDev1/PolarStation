import Foundation

/// Evaluates loop conditions for a container.
///
/// Returns `true` when ANY enabled condition is met, signalling the
/// container should stop looping.
struct ConditionEvaluator {

    /// Observer location from Settings (read once per evaluation).
    private var observerLat: Double { UserDefaults.standard.double(forKey: "observerLat") }
    private var observerLon: Double { UserDefaults.standard.double(forKey: "observerLon") }

    /// Check whether any condition is satisfied and the loop should stop.
    func shouldStop(
        conditions: [SequenceCondition],
        iterationCount: Int,
        containerStartTime: Date,
        totalFramesCaptured: Int,
        targetRA: Double? = nil,
        targetDec: Double? = nil
    ) -> Bool {
        for condition in conditions where condition.enabled {
            if evaluate(condition, iterationCount: iterationCount,
                       containerStartTime: containerStartTime,
                       totalFramesCaptured: totalFramesCaptured,
                       targetRA: targetRA, targetDec: targetDec) {
                return true
            }
        }
        return false
    }

    private func evaluate(
        _ condition: SequenceCondition,
        iterationCount: Int,
        containerStartTime: Date,
        totalFramesCaptured: Int,
        targetRA: Double?,
        targetDec: Double?
    ) -> Bool {
        switch condition.type {

        // MARK: - Iteration / Count

        case SequenceCondition.loopCount:
            let count = condition.params["count"]?.intValue ?? 1
            return iterationCount >= count

        case SequenceCondition.frameCount:
            let count = condition.params["count"]?.intValue ?? 1
            return totalFramesCaptured >= count

        case SequenceCondition.timeElapsed:
            // Support both "minutes" (new) and "seconds" (legacy)
            let minutes = condition.params["minutes"]?.intValue
            let seconds = condition.params["seconds"]?.doubleValue
            let durationSec: Double
            if let m = minutes {
                durationSec = Double(m) * 60
            } else {
                durationSec = seconds ?? 0
            }
            return Date().timeIntervalSince(containerStartTime) >= durationSec

        // MARK: - Time

        case SequenceCondition.loopUntilTime:
            if let timeStr = condition.params["utc_time"]?.stringValue, !timeStr.isEmpty {
                let formatter = ISO8601DateFormatter()
                if let targetTime = formatter.date(from: timeStr) {
                    return Date() >= targetTime
                }
            }
            return false

        case SequenceCondition.loopUntilLocalTime:
            let hour = condition.params["hour"]?.intValue ?? 6
            let minute = condition.params["minute"]?.intValue ?? 0
            return isLocalTimePassed(hour: hour, minute: minute)

        // MARK: - Altitude / Celestial (via SwiftAA)

        case SequenceCondition.targetAltitudeBelow:
            let minAlt = condition.params["min_altitude_deg"]?.doubleValue
                ?? Double(condition.params["min_altitude_deg"]?.intValue ?? 30)
            guard let ra = targetRA, let dec = targetDec else { return false }
            let alt = SkyObjectsService.objectAltitude(
                raDeg: ra * 15.0, decDeg: dec,
                lat: observerLat, lon: observerLon
            )
            return alt < minAlt

        case SequenceCondition.targetAltitudeAbove:
            let minAlt = condition.params["min_altitude_deg"]?.doubleValue
                ?? Double(condition.params["min_altitude_deg"]?.intValue ?? 30)
            guard let ra = targetRA, let dec = targetDec else { return false }
            let alt = SkyObjectsService.objectAltitude(
                raDeg: ra * 15.0, decDeg: dec,
                lat: observerLat, lon: observerLon
            )
            return alt > minAlt

        case SequenceCondition.sunAltitudeAbove:
            let threshold = condition.params["altitude_deg"]?.doubleValue
                ?? Double(condition.params["altitude_deg"]?.intValue ?? -12)
            let sunAlt = SkyObjectsService.sunAltitude(lat: observerLat, lon: observerLon)
            return sunAlt > threshold

        default:
            return false
        }
    }

    // MARK: - Helpers

    /// Check if local time has passed the given hour:minute.
    private func isLocalTimePassed(hour: Int, minute: Int) -> Bool {
        let cal = Calendar.current
        let now = Date()
        let nowH = cal.component(.hour, from: now)
        let nowM = cal.component(.minute, from: now)
        let nowMinutes = nowH * 60 + nowM
        let targetMinutes = hour * 60 + minute
        return nowMinutes >= targetMinutes
    }
}
