import Foundation

/// Executor for `open_cover`.
struct OpenCoverExecutor: InstructionExecutor {
    let instructionType = "open_cover"

    func execute(instruction: SequenceInstruction, context: ExecutionContext) async throws {
        guard let cc = context.deviceResolver.coverCalibrator() else {
            throw ExecutorError.deviceNotAvailable("cover_calibrator")
        }
        context.status("Opening cover")
        cc.openCover()

        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(2))
            cc.refreshStatus()
            try await Task.sleep(for: .seconds(0.5))
            if cc.coverState == 3 {  // 3 = Open
                context.status("Cover open")
                return
            }
        }
        context.status("Cover open timeout — state: \(cc.coverLabel)")
    }
}

/// Executor for `close_cover`.
struct CloseCoverExecutor: InstructionExecutor {
    let instructionType = "close_cover"

    func execute(instruction: SequenceInstruction, context: ExecutionContext) async throws {
        guard let cc = context.deviceResolver.coverCalibrator() else {
            throw ExecutorError.deviceNotAvailable("cover_calibrator")
        }
        context.status("Closing cover")
        cc.closeCover()

        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(2))
            cc.refreshStatus()
            try await Task.sleep(for: .seconds(0.5))
            if cc.coverState == 1 {  // 1 = Closed
                context.status("Cover closed")
                return
            }
        }
        context.status("Cover close timeout — state: \(cc.coverLabel)")
    }
}

/// Executor for `calibrator_on` — turns on the flat panel at a given brightness.
struct CalibratorOnExecutor: InstructionExecutor {
    let instructionType = "calibrator_on"

    func execute(instruction: SequenceInstruction, context: ExecutionContext) async throws {
        guard let cc = context.deviceResolver.coverCalibrator() else {
            throw ExecutorError.deviceNotAvailable("cover_calibrator")
        }
        let brightness = Int32(instruction.params["brightness"]?.intValue ?? Int(cc.maxBrightness))
        context.status("Calibrator on at brightness \(brightness)")
        cc.calibratorOn(brightness: brightness)
    }
}

/// Executor for `calibrator_off`.
struct CalibratorOffExecutor: InstructionExecutor {
    let instructionType = "calibrator_off"

    func execute(instruction: SequenceInstruction, context: ExecutionContext) async throws {
        guard let cc = context.deviceResolver.coverCalibrator() else {
            throw ExecutorError.deviceNotAvailable("cover_calibrator")
        }
        context.status("Calibrator off")
        cc.calibratorOff()
    }
}
