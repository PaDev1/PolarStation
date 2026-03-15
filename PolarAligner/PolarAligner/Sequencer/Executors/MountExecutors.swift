import Foundation

/// Executor for `slew_to_target` — slews mount to the parent container's target.
struct SlewToTargetExecutor: InstructionExecutor {
    let instructionType = "slew_to_target"

    func execute(instruction: SequenceInstruction, context: ExecutionContext) async throws {
        guard let mount = context.deviceResolver.mount() else {
            throw ExecutorError.deviceNotAvailable("mount")
        }
        guard let target = context.targetInfo else {
            throw ExecutorError.missingParameter("No target coordinates in parent container")
        }

        context.status("Slewing to \(target.name) (RA \(String(format: "%.4f", target.ra))h, Dec \(String(format: "%.2f", target.dec))°)")
        try await mount.gotoRADec(raHours: target.ra, decDeg: target.dec)
        context.status("Slew complete")
    }
}

/// Executor for `park_mount`.
struct ParkMountExecutor: InstructionExecutor {
    let instructionType = "park_mount"

    func execute(instruction: SequenceInstruction, context: ExecutionContext) async throws {
        guard let mount = context.deviceResolver.mount() else {
            throw ExecutorError.deviceNotAvailable("mount")
        }
        context.status("Parking mount")
        try await mount.park()
    }
}

/// Executor for `unpark_mount`.
struct UnparkMountExecutor: InstructionExecutor {
    let instructionType = "unpark_mount"

    func execute(instruction: SequenceInstruction, context: ExecutionContext) async throws {
        guard let mount = context.deviceResolver.mount() else {
            throw ExecutorError.deviceNotAvailable("mount")
        }
        context.status("Unparking mount")
        try await mount.unpark()
    }
}

/// Executor for `go_home` — slews mount to home position.
struct GoHomeExecutor: InstructionExecutor {
    let instructionType = "go_home"

    func execute(instruction: SequenceInstruction, context: ExecutionContext) async throws {
        guard let mount = context.deviceResolver.mount() else {
            throw ExecutorError.deviceNotAvailable("mount")
        }
        context.status("Going home")
        try await mount.findHome()
    }
}

/// Executor for `start_tracking`.
/// Uses tracking rate from instruction params, parent target, or defaults to sidereal.
struct StartTrackingExecutor: InstructionExecutor {
    let instructionType = "start_tracking"

    func execute(instruction: SequenceInstruction, context: ExecutionContext) async throws {
        guard let mount = context.deviceResolver.mount() else {
            throw ExecutorError.deviceNotAvailable("mount")
        }
        // Priority: instruction param > parent target's trackingRate > sidereal
        let rate: TrackingRate
        if let rateParam = instruction.params["rate"]?.intValue {
            rate = TrackingRate(rawValue: rateParam) ?? .sidereal
        } else {
            rate = context.targetInfo?.effectiveTrackingRate ?? .sidereal
        }
        context.status("Starting \(rate.label.lowercased()) tracking")
        try await mount.setTrackingRate(UInt8(rate.rawValue))
        try await mount.setTracking(true)
    }
}

enum ExecutorError: LocalizedError {
    case deviceNotAvailable(String)
    case missingParameter(String)

    var errorDescription: String? {
        switch self {
        case .deviceNotAvailable(let role): return "Device not available: \(role)"
        case .missingParameter(let msg): return msg
        }
    }
}
