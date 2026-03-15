import Foundation

/// Executor for `move_focuser` — moves focuser to an absolute position and waits.
struct MoveFocuserExecutor: InstructionExecutor {
    let instructionType = "move_focuser"

    func execute(instruction: SequenceInstruction, context: ExecutionContext) async throws {
        guard let focuser = context.deviceResolver.focuser() else {
            throw ExecutorError.deviceNotAvailable("focuser")
        }
        let position = Int32(instruction.params["position"]?.intValue ?? 0)
        context.status("Moving focuser to \(position)")
        focuser.moveTo(position: position)

        // Poll until done
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(1))
            focuser.refreshStatus()
            try await Task.sleep(for: .seconds(0.5))
            if !focuser.isMoving {
                context.status("Focuser at position \(focuser.position)")
                return
            }
            context.status("Focuser moving: \(focuser.position) → \(position)")
        }
        context.status("Focuser move timeout")
    }
}

/// Executor for `halt_focuser` — emergency stop focuser.
struct HaltFocuserExecutor: InstructionExecutor {
    let instructionType = "halt_focuser"

    func execute(instruction: SequenceInstruction, context: ExecutionContext) async throws {
        guard let focuser = context.deviceResolver.focuser() else {
            throw ExecutorError.deviceNotAvailable("focuser")
        }
        context.status("Halting focuser")
        focuser.halt()
    }
}
