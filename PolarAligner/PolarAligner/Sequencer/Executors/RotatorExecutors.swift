import Foundation

/// Executor for `move_rotator` — moves rotator to an absolute angle and waits.
struct MoveRotatorExecutor: InstructionExecutor {
    let instructionType = "move_rotator"

    func execute(instruction: SequenceInstruction, context: ExecutionContext) async throws {
        guard let rotator = context.deviceResolver.rotator() else {
            throw ExecutorError.deviceNotAvailable("rotator")
        }
        let degrees = instruction.params["degrees"]?.doubleValue ?? 0
        let relative = instruction.params["relative"]?.boolValue ?? false

        if relative {
            context.status("Rotating \(String(format: "%.1f", degrees))° relative")
            rotator.moveRelative(degrees: degrees)
        } else {
            context.status("Rotating to \(String(format: "%.1f", degrees))°")
            rotator.moveAbsolute(degrees: degrees)
        }

        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(1))
            rotator.refreshStatus()
            try await Task.sleep(for: .seconds(0.5))
            if !rotator.isMoving {
                context.status("Rotator at \(String(format: "%.1f", rotator.position))°")
                return
            }
        }
        context.status("Rotator move timeout")
    }
}
