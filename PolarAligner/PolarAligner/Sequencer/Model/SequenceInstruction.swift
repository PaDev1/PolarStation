import Foundation

/// A single executable instruction in a sequence.
///
/// Uses a string `type` discriminator for extensibility: new instruction types
/// can be added without changing the data model. Parameters are stored in a
/// flexible dictionary, parsed by the corresponding `InstructionExecutor` at runtime.
struct SequenceInstruction: Codable, Identifiable, Hashable {
    let id: UUID
    var type: String
    var enabled: Bool
    var deviceRole: String?
    var params: [String: AnyCodableValue]

    init(type: String, deviceRole: String? = nil, params: [String: AnyCodableValue] = [:]) {
        self.id = UUID()
        self.type = type
        self.enabled = true
        self.deviceRole = deviceRole
        self.params = params
    }
}

// MARK: - Built-in Instruction Type Constants

extension SequenceInstruction {
    // Mount
    static let slewToTarget = "slew_to_target"
    static let centerTarget = "center_target"
    static let parkMount = "park_mount"
    static let unparkMount = "unpark_mount"
    static let goHome = "go_home"
    static let startTracking = "start_tracking"

    // Camera
    static let captureFrames = "capture_frames"
    static let setCooler = "set_cooler"
    static let warmup = "warmup"

    // Filter
    static let switchFilter = "switch_filter"

    // Guiding
    static let startGuiding = "start_guiding"
    static let stopGuiding = "stop_guiding"
    static let dither = "dither"

    // Plate solving
    static let plateSolve = "plate_solve"

    // Timing
    static let waitTime = "wait_time"
    static let waitUntilTime = "wait_until_time"
    static let waitUntilLocalTime = "wait_until_local_time"
    static let waitForAltitude = "wait_for_altitude"

    // Focuser
    static let moveFocuser = "move_focuser"
    static let haltFocuser = "halt_focuser"
    static let autofocus = "autofocus"

    // Dome
    static let slewDome = "slew_dome"
    static let openShutter = "open_shutter"
    static let closeShutter = "close_shutter"
    static let parkDome = "park_dome"
    static let homeDome = "home_dome"

    // Rotator
    static let moveRotator = "move_rotator"

    // Switch
    static let setSwitch = "set_switch"

    // Cover Calibrator
    static let openCover = "open_cover"
    static let closeCover = "close_cover"
    static let calibratorOn = "calibrator_on"
    static let calibratorOff = "calibrator_off"

    // Safety / Conditions
    static let waitForSafe = "wait_for_safe"
    static let logWeather = "log_weather"

    // Utility
    static let annotation = "annotation"
    static let runScript = "run_script"
}
