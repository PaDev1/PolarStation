import Foundation

/// Tool for AI assistant to control the sky map view.
@MainActor
final class SkyMapTool: AssistantTool {
    private let skyMapViewModel: SkyMapViewModel

    init(skyMapViewModel: SkyMapViewModel) {
        self.skyMapViewModel = skyMapViewModel
    }

    var definition: ToolDefinition {
        ToolDefinition(
            name: "sky_map",
            description: "Control the sky map view. Actions: center (center map on RA/Dec coordinates and optionally set zoom), zoom (set field of view).",
            parameters: [
                "type": "object",
                "properties": [
                    "action": [
                        "type": "string",
                        "enum": ["center", "zoom"],
                        "description": "The action to perform"
                    ] as [String: Any],
                    "ra_hours": [
                        "type": "number",
                        "description": "Right ascension in hours (0-24) to center on"
                    ] as [String: Any],
                    "dec_degrees": [
                        "type": "number",
                        "description": "Declination in degrees (-90 to 90) to center on"
                    ] as [String: Any],
                    "fov_degrees": [
                        "type": "number",
                        "description": "Field of view in degrees (1-360). Optional for center, required for zoom."
                    ] as [String: Any],
                    "object_name": [
                        "type": "string",
                        "description": "Object name or ID to center on (e.g. 'M42', 'Horsehead'). Alternative to ra_hours/dec_degrees."
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
        case "center":
            if let name = arguments["object_name"] as? String {
                return "Center sky map on \(name)"
            }
            let ra = arguments["ra_hours"] as? Double ?? 0
            let dec = arguments["dec_degrees"] as? Double ?? 0
            return "Center sky map on RA \(String(format: "%.2f", ra))h, Dec \(String(format: "%.1f", dec))\u{00B0}"
        case "zoom":
            let fov = arguments["fov_degrees"] as? Double ?? 60
            return "Set sky map FOV to \(String(format: "%.0f", fov))\u{00B0}"
        default:
            return "Sky map: \(action)"
        }
    }

    func execute(arguments: [String: Any]) async throws -> String {
        let action = arguments["action"] as? String ?? ""

        switch action {
        case "center":
            var raDeg: Double
            var decDeg: Double

            if let name = arguments["object_name"] as? String {
                let query = name.lowercased()
                guard let obj = messierCatalog.first(where: { $0.id.lowercased() == query })
                    ?? messierCatalog.first(where: { $0.searchText.contains(query) }) else {
                    return "Object '\(name)' not found in catalog."
                }
                raDeg = obj.raDeg
                decDeg = obj.decDeg
            } else if let raH = arguments["ra_hours"] as? Double,
                      let dec = arguments["dec_degrees"] as? Double {
                raDeg = raH * 15.0
                decDeg = dec
            } else {
                return "Error: Provide either object_name or ra_hours + dec_degrees."
            }

            skyMapViewModel.centerMap(raDeg: raDeg, decDeg: decDeg)

            if let fov = arguments["fov_degrees"] as? Double {
                skyMapViewModel.mapFOV = max(1, min(360, fov))
            }

            return "Sky map centered on RA \(String(format: "%.3f", raDeg / 15.0))h, Dec \(String(format: "%.2f", decDeg))\u{00B0} (FOV \(String(format: "%.0f", skyMapViewModel.mapFOV))\u{00B0})."

        case "zoom":
            guard let fov = arguments["fov_degrees"] as? Double else {
                return "Error: fov_degrees is required for zoom."
            }
            skyMapViewModel.mapFOV = max(1, min(360, fov))
            return "Sky map FOV set to \(String(format: "%.0f", skyMapViewModel.mapFOV))\u{00B0}."

        default:
            return "Error: Unknown action '\(action)'."
        }
    }
}
