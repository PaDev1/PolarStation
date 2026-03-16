import Foundation

/// Tool for AI assistant to query camera status.
@MainActor
final class CameraTool: AssistantTool {
    private let cameraViewModel: CameraViewModel

    init(cameraViewModel: CameraViewModel) {
        self.cameraViewModel = cameraViewModel
    }

    var definition: ToolDefinition {
        ToolDefinition(
            name: "camera_control",
            description: "Control the imaging camera. Actions: stop (stop capture), status (get camera state, settings, and detected star count).",
            parameters: [
                "type": "object",
                "properties": [
                    "action": [
                        "type": "string",
                        "enum": ["stop", "status"],
                        "description": "The camera action to perform"
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
        case "stop": return "Stop camera capture"
        case "status": return "Read camera status"
        default: return "Camera action: \(action)"
        }
    }

    func execute(arguments: [String: Any]) async throws -> String {
        let action = arguments["action"] as? String ?? ""

        switch action {
        case "stop":
            cameraViewModel.stopCapture()
            return "Capture stopped."

        case "status":
            let tempStr: String
            if let temp = cameraViewModel.sensorTempC {
                tempStr = String(format: "%.1f\u{00B0}C", temp)
            } else {
                tempStr = "N/A"
            }
            let coolerStr: String
            if cameraViewModel.coolerEnabled, let pct = cameraViewModel.coolerPowerPercent {
                coolerStr = "On (\(pct)%)"
            } else {
                coolerStr = "Off"
            }
            return """
            Camera Status:
            - Connected: \(cameraViewModel.isConnected)
            - Capturing: \(cameraViewModel.isCapturing)
            - Resolution: \(cameraViewModel.captureWidth)x\(cameraViewModel.captureHeight)
            - Sensor Temp: \(tempStr)
            - Cooler: \(coolerStr)
            - Detected Stars: \(cameraViewModel.detectedStars.count)
            """

        default:
            return "Error: Unknown action '\(action)'."
        }
    }
}
