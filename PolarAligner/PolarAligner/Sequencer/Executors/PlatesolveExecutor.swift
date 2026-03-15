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

/// Executor for `center_target` — iterative slew + plate solve + sync until centered.
struct CenterTargetExecutor: InstructionExecutor {
    let instructionType = "center_target"

    /// Acceptable centering error in degrees.
    private let toleranceDeg: Double = 0.05  // ~3 arcmin

    func execute(instruction: SequenceInstruction, context: ExecutionContext) async throws {
        let maxAttempts = instruction.params["attempts"]?.intValue ?? 3
        guard let target = context.targetInfo else {
            throw ExecutorError.missingParameter("No target for center_target")
        }
        guard let mount = context.deviceResolver.mount() else {
            throw ExecutorError.deviceNotAvailable("mount")
        }
        guard let plateSolver = context.deviceResolver.plateSolver() else {
            throw ExecutorError.deviceNotAvailable("plate_solver")
        }
        guard let camera = context.deviceResolver.camera() else {
            throw ExecutorError.deviceNotAvailable("imaging_camera")
        }

        let targetRaH = target.ra  // RA in hours from TargetInfo
        let targetDecDeg = target.dec

        context.status("Centering on \(target.name) (max \(maxAttempts) attempts)")

        for attempt in 1...maxAttempts {
            try Task.checkCancellation()

            // Step 1: Slew to target
            context.status("Center attempt \(attempt)/\(maxAttempts): slewing...")
            try await mount.gotoRADec(raHours: targetRaH, decDeg: targetDecDeg)

            // Wait for mount to settle and camera to get fresh stars
            try await Task.sleep(for: .seconds(3))

            // Step 2: Plate solve current position
            let stars = camera.detectedStars
            guard !stars.isEmpty else {
                context.status("Attempt \(attempt): no stars detected, retrying...")
                continue
            }

            do {
                let result = try await plateSolver.solveRobust(centroids: stars)
                guard result.success else {
                    context.status("Attempt \(attempt): solve failed, retrying...")
                    continue
                }

                let solvedRaH = result.raDeg / 15.0
                let solvedDecDeg = result.decDeg

                // Step 3: Check if we're close enough
                let raErrorDeg = abs(solvedRaH - targetRaH) * 15.0
                let decErrorDeg = abs(solvedDecDeg - targetDecDeg)
                let totalErrorDeg = sqrt(raErrorDeg * raErrorDeg + decErrorDeg * decErrorDeg)

                context.status(String(format: "Attempt %d: error %.2f' (need < %.1f')",
                                      attempt, totalErrorDeg * 60, toleranceDeg * 60))

                if totalErrorDeg <= toleranceDeg {
                    context.status("Target centered successfully")
                    return
                }

                // Step 4: Sync mount to solved position, then re-slew
                try await mount.syncPosition(raHours: solvedRaH, decDeg: solvedDecDeg)

            } catch {
                context.status("Attempt \(attempt): solve error — \(error.localizedDescription)")
            }
        }

        context.status("Centering: max attempts reached, continuing with current position")
    }
}
