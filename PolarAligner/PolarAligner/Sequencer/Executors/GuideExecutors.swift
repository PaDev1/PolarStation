import Foundation

/// Executor for `start_guiding`.
struct StartGuidingExecutor: InstructionExecutor {
    let instructionType = "start_guiding"

    func execute(instruction: SequenceInstruction, context: ExecutionContext) async throws {
        context.status("Starting autoguiding")
        // Guiding requires calibration + active camera which are set up via the Guiding UI.
        // The sequencer can only start/stop if the guide session is already configured.
        guard let guide = context.deviceResolver.guide() else {
            context.status("Guide session not available — skipping")
            return
        }
        if guide.isGuiding {
            context.status("Already guiding")
            return
        }
        // Guide start requires calibrator + camera — sequencer assumes these are pre-configured
        context.status("Guiding (start from sequencer requires pre-calibration)")
        try await Task.sleep(for: .seconds(1))
    }
}

/// Executor for `stop_guiding`.
struct StopGuidingExecutor: InstructionExecutor {
    let instructionType = "stop_guiding"

    func execute(instruction: SequenceInstruction, context: ExecutionContext) async throws {
        guard let guide = context.deviceResolver.guide() else {
            context.status("Guide session not available")
            return
        }
        context.status("Stopping autoguiding")
        guide.stopGuiding()
        context.status("Guiding stopped")
    }
}

/// Executor for `dither` — shifts guide reference point.
struct DitherExecutor: InstructionExecutor {
    let instructionType = "dither"

    func execute(instruction: SequenceInstruction, context: ExecutionContext) async throws {
        let pixels = instruction.params["pixels"]?.doubleValue ?? 5.0
        let settleTime = instruction.params["settle_time_sec"]?.doubleValue ?? 10.0

        guard let guide = context.deviceResolver.guide() else {
            context.status("Guide session not available — skipping dither")
            return
        }

        guard guide.isGuiding else {
            context.status("Not guiding — skipping dither")
            return
        }

        context.status("Dithering \(Int(pixels))px")
        guide.dither(pixels: pixels)

        // Wait for settle — guide loop will correct to the new reference position
        context.status("Waiting \(Int(settleTime))s for settle...")
        try await Task.sleep(for: .seconds(settleTime))
        context.status("Dither settled")
    }
}
