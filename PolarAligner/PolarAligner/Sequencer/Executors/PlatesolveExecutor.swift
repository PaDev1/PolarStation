import Foundation

/// Executor for `plate_solve` — uses the imaging camera's current detected stars to plate solve.
struct PlatesolveExecutor: InstructionExecutor {
    let instructionType = "plate_solve"

    func execute(instruction: SequenceInstruction, context: ExecutionContext) async throws {
        guard let plateSolver = context.deviceResolver.plateSolver() else {
            throw ExecutorError.deviceNotAvailable("plate_solver")
        }
        guard let camera = context.deviceResolver.camera() else {
            throw ExecutorError.deviceNotAvailable("imaging_camera")
        }

        context.status("Plate solving...")

        // Use the camera's currently detected stars
        let stars = camera.detectedStars
        guard !stars.isEmpty else {
            context.status("No stars detected — cannot plate solve")
            return
        }

        do {
            let result = try await plateSolver.solveRobust(centroids: stars)
            if result.success {
                let raH = result.raDeg / 15.0
                context.status(String(format: "Solved: RA %.4fh Dec %.3f° (%.1f\" RMS, %d stars)",
                                      raH, result.decDeg, result.rmseArcsec, result.matchedStars))
            } else {
                context.status("Plate solve failed — no match")
            }
        } catch {
            context.status("Plate solve error: \(error.localizedDescription)")
        }
    }
}

/// Executor for `center_target` — delegates to shared CenteringSolveService.
struct CenterTargetExecutor: InstructionExecutor {
    let instructionType = "center_target"

    func execute(instruction: SequenceInstruction, context: ExecutionContext) async throws {
        let maxAttempts = instruction.params["attempts"]?.intValue ?? 3
        let toleranceArcmin = instruction.params["tolerance_arcmin"]?.doubleValue ?? 3.0
        guard let target = context.targetInfo else {
            throw ExecutorError.missingParameter("No target for center_target")
        }
        guard let camera = context.deviceResolver.camera() else {
            throw ExecutorError.deviceNotAvailable("imaging_camera")
        }

        // Use shared centering service if available, otherwise fall back to inline logic
        guard let service = context.deviceResolver.centeringSolve() else {
            throw ExecutorError.deviceNotAvailable("centering_solve_service")
        }

        context.status("Centering on \(target.name) (max \(maxAttempts) attempts, tolerance \(String(format: "%.1f", toleranceArcmin))′)")

        // Configure service for this run
        service.toleranceArcmin = toleranceArcmin
        service.maxAttempts = maxAttempts

        service.centerOnTarget(
            targetRAHours: target.ra,
            targetDecDeg: target.dec,
            starProvider: { camera.detectedStars }
        )

        // Wait for centering to complete
        while service.state.isActive {
            try Task.checkCancellation()
            context.status(service.statusMessage)
            try await Task.sleep(for: .milliseconds(500))
        }

        switch service.state {
        case .converged:
            context.status("Target centered successfully")
        case .failed(let msg):
            context.status("Centering failed: \(msg)")
        default:
            context.status("Centering completed")
        }
    }
}
