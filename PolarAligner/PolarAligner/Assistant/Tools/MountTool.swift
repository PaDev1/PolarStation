import Foundation

/// Tool for AI assistant to control the telescope mount.
@MainActor
final class MountTool: AssistantTool {
    private let mountService: MountService

    init(mountService: MountService) {
        self.mountService = mountService
    }

    var definition: ToolDefinition {
        ToolDefinition(
            name: "mount_control",
            description: "Control the telescope mount. Actions: goto (slew to coordinates), sync (sync alignment), track_on, track_off, park, unpark, abort (emergency stop), status (get current position and state).",
            parameters: [
                "type": "object",
                "properties": [
                    "action": [
                        "type": "string",
                        "enum": ["goto", "sync", "track_on", "track_off", "park", "unpark", "abort", "status"],
                        "description": "The mount action to perform"
                    ] as [String: Any],
                    "ra_hours": [
                        "type": "number",
                        "description": "Right ascension in hours (0-24). Required for goto and sync."
                    ] as [String: Any],
                    "dec_degrees": [
                        "type": "number",
                        "description": "Declination in degrees (-90 to 90). Required for goto and sync."
                    ] as [String: Any]
                ] as [String: Any],
                "required": ["action"]
            ] as [String: Any]
        )
    }

    var requiresConfirmation: Bool { true }

    func describeAction(arguments: [String: Any]) -> String {
        let action = arguments["action"] as? String ?? "unknown"
        switch action {
        case "goto":
            let ra = arguments["ra_hours"] as? Double ?? 0
            let dec = arguments["dec_degrees"] as? Double ?? 0
            return "Slew mount to RA \(String(format: "%.3f", ra))h, Dec \(String(format: "%.2f", dec))\u{00B0}"
        case "sync":
            let ra = arguments["ra_hours"] as? Double ?? 0
            let dec = arguments["dec_degrees"] as? Double ?? 0
            return "Sync mount position to RA \(String(format: "%.3f", ra))h, Dec \(String(format: "%.2f", dec))\u{00B0}"
        case "track_on": return "Enable mount tracking"
        case "track_off": return "Disable mount tracking"
        case "park": return "Park the mount"
        case "unpark": return "Unpark the mount"
        case "abort": return "Emergency stop mount"
        case "status": return "Read mount status"
        default: return "Mount action: \(action)"
        }
    }

    func execute(arguments: [String: Any]) async throws -> String {
        let action = arguments["action"] as? String ?? ""

        guard mountService.isConnected else {
            return "Error: Mount is not connected."
        }

        switch action {
        case "goto":
            guard let ra = arguments["ra_hours"] as? Double,
                  let dec = arguments["dec_degrees"] as? Double else {
                return "Error: goto requires ra_hours and dec_degrees parameters."
            }
            try await mountService.gotoRADec(raHours: ra, decDeg: dec)
            return "Slewing to RA \(String(format: "%.3f", ra))h, Dec \(String(format: "%.2f", dec))\u{00B0}. Mount is now slewing."

        case "sync":
            guard let ra = arguments["ra_hours"] as? Double,
                  let dec = arguments["dec_degrees"] as? Double else {
                return "Error: sync requires ra_hours and dec_degrees parameters."
            }
            try await mountService.syncPosition(raHours: ra, decDeg: dec)
            return "Synced mount position to RA \(String(format: "%.3f", ra))h, Dec \(String(format: "%.2f", dec))\u{00B0}."

        case "track_on":
            try await mountService.setTracking(true)
            return "Tracking enabled."

        case "track_off":
            try await mountService.setTracking(false)
            return "Tracking disabled."

        case "park":
            try await mountService.park()
            return "Park command sent."

        case "unpark":
            try await mountService.unpark()
            return "Unpark command sent."

        case "abort":
            try await mountService.abort()
            return "Emergency stop executed."

        case "status":
            guard let s = mountService.status else {
                return "Mount Status: Connected=\(mountService.isConnected), no status data available."
            }
            return """
            Mount Status:
            - Connected: \(mountService.isConnected)
            - RA: \(String(format: "%.4f", s.raHours))h, Dec: \(String(format: "%.2f", s.decDeg))\u{00B0}
            - Alt: \(String(format: "%.1f", s.altDeg))\u{00B0}, Az: \(String(format: "%.1f", s.azDeg))\u{00B0}
            - Tracking: \(s.tracking), Slewing: \(s.slewing)
            - Parked: \(s.atPark)
            """

        default:
            return "Error: Unknown action '\(action)'."
        }
    }
}
