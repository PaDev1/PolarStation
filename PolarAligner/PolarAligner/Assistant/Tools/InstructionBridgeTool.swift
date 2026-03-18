import Foundation

/// Bridges ALL sequencer instructions to the AI assistant as a single tool.
/// When a new instruction executor is registered in the sequencer, it automatically
/// becomes available to the assistant — no separate tool code needed.
@MainActor
final class InstructionBridgeTool: AssistantTool {
    private let registry: InstructionRegistry
    private let deviceResolver: DeviceResolver
    private let progress: SequenceProgress

    init(registry: InstructionRegistry, deviceResolver: DeviceResolver, progress: SequenceProgress) {
        self.registry = registry
        self.deviceResolver = deviceResolver
        self.progress = progress
    }

    var definition: ToolDefinition {
        let types = registry.registeredTypes
        let descriptions = types.map { "\($0): \(Self.describe($0))" }.joined(separator: "\n")

        return ToolDefinition(
            name: "device_command",
            description: """
            Execute a device command. Available commands:
            \(descriptions)

            Parameters vary by command — see param_descriptions for each command type.
            Common parameters: brightness (int), position (int), azimuth (float), \
            ra_hours (float), dec_degrees (float), filter_position (int), \
            switch_id (int), switch_state (bool), duration_seconds (float).
            """,
            parameters: [
                "type": "object",
                "properties": [
                    "command": [
                        "type": "string",
                        "enum": types,
                        "description": "The device command to execute"
                    ] as [String: Any],
                    "params": [
                        "type": "object",
                        "description": "Command-specific parameters (e.g. {\"brightness\": 100}, {\"position\": 5000}, {\"azimuth\": 180.0})",
                        "additionalProperties": true
                    ] as [String: Any]
                ] as [String: Any],
                "required": ["command"]
            ] as [String: Any]
        )
    }

    var requiresConfirmation: Bool { true }

    func describeAction(arguments: [String: Any]) -> String {
        let command = arguments["command"] as? String ?? "unknown"
        let params = arguments["params"] as? [String: Any] ?? [:]
        let label = Self.humanLabel(command)

        if params.isEmpty {
            return label
        }
        let paramStr = params.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        return "\(label) (\(paramStr))"
    }

    func execute(arguments: [String: Any]) async throws -> String {
        let command = arguments["command"] as? String ?? ""
        let rawParams = arguments["params"] as? [String: Any] ?? [:]

        guard let executor = registry.executor(for: command) else {
            return "Error: Unknown command '\(command)'. Available: \(registry.registeredTypes.joined(separator: ", "))"
        }

        // Check device availability
        if let role = Self.deviceRole(for: command) {
            guard deviceResolver.isAvailable(role: role) else {
                return "Error: Device '\(role)' is not connected."
            }
        }

        // Convert JSON params to AnyCodableValue
        var instructionParams: [String: AnyCodableValue] = [:]
        for (key, value) in rawParams {
            if let i = value as? Int { instructionParams[key] = .int(i) }
            else if let d = value as? Double { instructionParams[key] = .double(d) }
            else if let b = value as? Bool { instructionParams[key] = .bool(b) }
            else if let s = value as? String { instructionParams[key] = .string(s) }
        }

        let instruction = SequenceInstruction(type: command, params: instructionParams)

        var statusMessages: [String] = []
        let context = ExecutionContext(
            deviceResolver: deviceResolver,
            targetInfo: nil,
            progress: progress,
            onStatus: { msg in statusMessages.append(msg) }
        )

        do {
            try await executor.execute(instruction: instruction, context: context)
            let result = statusMessages.isEmpty ? "Command '\(command)' completed." : statusMessages.last!
            return result
        } catch {
            return "Error executing '\(command)': \(error.localizedDescription)"
        }
    }

    // MARK: - Metadata

    /// Human-readable label for each command.
    private static func humanLabel(_ command: String) -> String {
        switch command {
        // Mount
        case "slew_to_target": return "Slew mount to target"
        case "center_target": return "Center target (plate-solve loop)"
        case "park_mount": return "Park mount"
        case "unpark_mount": return "Unpark mount"
        case "go_home": return "Slew mount to home"
        case "start_tracking": return "Start sidereal tracking"
        // Camera
        case "capture_frames": return "Capture frames"
        case "set_cooler": return "Set camera cooler"
        case "warmup": return "Warm up camera sensor"
        // Guide
        case "start_guiding": return "Start autoguiding"
        case "stop_guiding": return "Stop autoguiding"
        case "dither": return "Dither guide position"
        // Filter
        case "switch_filter": return "Switch filter"
        // Focuser
        case "move_focuser": return "Move focuser"
        case "halt_focuser": return "Halt focuser"
        case "autofocus": return "Run autofocus"
        // Dome
        case "slew_dome": return "Slew dome"
        case "open_shutter": return "Open dome shutter"
        case "close_shutter": return "Close dome shutter"
        case "park_dome": return "Park dome"
        case "home_dome": return "Home dome"
        // Rotator
        case "move_rotator": return "Move rotator"
        // Switch
        case "set_switch": return "Set switch"
        // Cover Calibrator
        case "open_cover": return "Open flat panel cover"
        case "close_cover": return "Close flat panel cover"
        case "calibrator_on": return "Turn on flat panel"
        case "calibrator_off": return "Turn off flat panel"
        // Safety / Conditions
        case "wait_for_safe": return "Wait for safe conditions"
        case "log_weather": return "Log weather conditions"
        // Timing
        case "wait_time": return "Wait (duration)"
        case "wait_until_time": return "Wait until UTC time"
        case "wait_until_local_time": return "Wait until local time"
        case "wait_for_altitude": return "Wait for object altitude"
        // Plate solve
        case "plate_solve": return "Plate solve current image"
        default: return command.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Brief description of what each command does and its parameters.
    private static func describe(_ command: String) -> String {
        switch command {
        case "slew_to_target": return "Slew to RA/Dec. Params: ra_hours, dec_degrees"
        case "center_target": return "Plate-solve centering. Params: ra_hours, dec_degrees, tolerance_arcmin"
        case "park_mount": return "Park the mount"
        case "unpark_mount": return "Unpark the mount"
        case "go_home": return "Slew to home position"
        case "start_tracking": return "Enable sidereal tracking"
        case "capture_frames": return "Capture N frames. Params: count, exposure_ms, gain, binning, filter, type(light/dark/flat/bias)"
        case "set_cooler": return "Set cooler target. Params: target_celsius"
        case "warmup": return "Gradually warm sensor to +20C"
        case "start_guiding": return "Start autoguiding"
        case "stop_guiding": return "Stop autoguiding"
        case "dither": return "Dither guide position. Params: pixels"
        case "switch_filter": return "Move filter wheel. Params: position (0-based)"
        case "move_focuser": return "Move focuser. Params: position (steps)"
        case "halt_focuser": return "Stop focuser motion"
        case "autofocus": return "Run V-curve autofocus. Params: step_size, num_steps"
        case "slew_dome": return "Rotate dome. Params: azimuth (degrees)"
        case "open_shutter": return "Open dome shutter"
        case "close_shutter": return "Close dome shutter"
        case "park_dome": return "Park dome"
        case "home_dome": return "Home dome"
        case "move_rotator": return "Rotate to angle. Params: angle (degrees)"
        case "set_switch": return "Set switch state. Params: switch_id, state (bool) or value (number)"
        case "open_cover": return "Open flat panel cover"
        case "close_cover": return "Close flat panel cover"
        case "calibrator_on": return "Turn on flat panel. Params: brightness (0-max)"
        case "calibrator_off": return "Turn off flat panel"
        case "wait_for_safe": return "Wait until safety monitor reports safe"
        case "log_weather": return "Log current weather conditions"
        case "wait_time": return "Wait duration. Params: seconds"
        case "wait_until_time": return "Wait until UTC ISO8601 time. Params: time"
        case "wait_until_local_time": return "Wait until local time. Params: time (HH:MM)"
        case "wait_for_altitude": return "Wait until object reaches altitude. Params: ra_hours, dec_degrees, min_altitude"
        case "plate_solve": return "Plate solve the current camera image"
        case "annotation": return "Log a note. Params: text"
        default: return command
        }
    }

    /// Map command to required device role for availability check.
    private static func deviceRole(for command: String) -> String? {
        switch command {
        case "slew_to_target", "center_target", "park_mount", "unpark_mount", "go_home", "start_tracking":
            return "mount"
        case "capture_frames", "set_cooler", "warmup":
            return "camera"
        case "start_guiding", "stop_guiding", "dither":
            return "guide_camera"
        case "switch_filter":
            return "filter_wheel"
        case "move_focuser", "halt_focuser", "autofocus":
            return "focuser"
        case "slew_dome", "open_shutter", "close_shutter", "park_dome", "home_dome":
            return "dome"
        case "move_rotator":
            return "rotator"
        case "set_switch":
            return "switch"
        case "open_cover", "close_cover", "calibrator_on", "calibrator_off":
            return "cover_calibrator"
        case "wait_for_safe":
            return "safety_monitor"
        case "log_weather":
            return "observing_conditions"
        default:
            return nil // timing/utility commands don't need a device
        }
    }
}
