import Foundation
import PolarCore
import CoreLocation

/// Orchestrates the polar alignment workflow: automatic 3-point calibration
/// followed by a continuous correction loop.
///
/// Flow mirrors SimulatedAlignmentEngine:
/// 1. Auto-alignment: wait for stars → solve → slew → repeat × 3 → compute error
/// 2. Correction loop: continuously plate-solve camera frames, predict sidereal
///    motion, compute remaining error as user adjusts mount screws
@MainActor
final class AlignmentCoordinator: ObservableObject {

    // MARK: - Published state

    @Published var step: AlignmentStep = .idle
    @Published var positions: [CelestialCoord?] = [nil, nil, nil]
    @Published var polarError: PolarError?
    @Published var statusMessage = "Press Start to begin alignment"
    @Published var isBusy = false

    /// Live correction error — updated in real-time during the correction loop.
    @Published var correctionError: PolarError?

    /// Whether the correction loop is actively running.
    @Published var isCorrecting = false

    /// Latest solved camera position (for sky map FOV tracking).
    @Published var solvedRA: Double?
    @Published var solvedDec: Double?

    // MARK: - Configuration

    /// Observer latitude in degrees (north positive).
    var observerLatDeg: Double = 60.17
    /// Observer longitude in degrees (east positive).
    var observerLonDeg: Double = 24.94
    /// RA slew between captures in degrees.
    var slewDeg: Double = 30.0

    // MARK: - Services

    let plateSolveService: PlateSolveService
    let mountService: MountService

    /// Error tracker for centroid-based interpolation between solves.
    var errorTracker: ErrorTracker?

    // MARK: - State machine

    enum AlignmentStep: Equatable {
        case idle
        case waitingForSolve(Int)   // 1, 2, or 3
        case slewing(Int)           // after solving step N, slewing to next
        case computing
        case complete               // 3-point done, showing result
        case correcting             // continuous error measurement loop
        case error(String)
    }

    // MARK: - Correction loop state

    /// Reference camera position from the last calibration/solve (for sidereal prediction).
    private var correctionReferenceRA: Double = 0
    private var correctionReferenceDec: Double = 0
    private var correctionReferenceTime: Date = Date()
    /// Mount axis from calibration (where the mount rotation axis points).
    private var correctionMountAxis: CelestialCoord?
    /// Task handle for the correction loop (for cancellation).
    private var correctionTask: Task<Void, Never>?
    /// Task handle for the auto-alignment run.
    private var alignmentTask: Task<Void, Never>?

    init(plateSolveService: PlateSolveService, mountService: MountService) {
        self.plateSolveService = plateSolveService
        self.mountService = mountService
    }

    /// Set observer location from CoreLocation.
    func setLocation(_ location: CLLocationCoordinate2D) {
        observerLatDeg = location.latitude
        observerLonDeg = location.longitude
    }

    // MARK: - Auto Alignment (mirrors SimulatedAlignmentEngine.run())

    /// Run the full 3-point alignment automatically.
    ///
    /// For each step: waits for camera to detect enough stars, plate-solves,
    /// then slews the mount. After all 3 positions are solved, computes the
    /// polar error and enters the correction loop.
    func runAutoAlignment(cameraViewModel: CameraViewModel) {
        guard !isBusy else { return }

        alignmentTask?.cancel()
        stopCorrectionLoop()

        positions = [nil, nil, nil]
        polarError = nil
        correctionError = nil
        isBusy = true

        alignmentTask = Task {
            // Ensure camera is capturing
            if cameraViewModel.isConnected && !cameraViewModel.isCapturing {
                // Camera settings are set by the view before calling this
                statusMessage = "Waiting for camera to start..."
                // Give the camera time to start delivering frames
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }

            for stepNum in 1...3 {
                guard !Task.isCancelled else { return }

                step = .waitingForSolve(stepNum)
                statusMessage = "Step \(stepNum)/3: Waiting for stars..."

                // Wait for enough detected stars (like simulator waits for render)
                let stars = await waitForStars(cameraViewModel: cameraViewModel, minCount: 4)
                guard let stars, !Task.isCancelled else {
                    if !Task.isCancelled {
                        step = .error("Cancelled or no stars detected")
                        statusMessage = "Alignment cancelled"
                        isBusy = false
                    }
                    return
                }

                // Plate solve with robust retry (mirrors simulator's detectAndSolve)
                statusMessage = "Step \(stepNum)/3: Plate solving (\(stars.count) stars)..."
                do {
                    let result = try await solveWithFallback(
                        stars: stars,
                        cameraViewModel: cameraViewModel,
                        stepLabel: "Step \(stepNum)/3"
                    )

                    guard let result else {
                        step = .error("Solve failed at step \(stepNum)")
                        statusMessage = "Step \(stepNum): Plate solve failed with both detectors"
                        isBusy = false
                        return
                    }

                    let coord = CelestialCoord(raDeg: result.raDeg, decDeg: result.decDeg)
                    positions[stepNum - 1] = coord
                    solvedRA = result.raDeg
                    solvedDec = result.decDeg
                    statusMessage = String(format: "Step %d/3: RA %.2f° Dec %+.2f°",
                                           stepNum, result.raDeg, result.decDeg)
                    print("[Align] Step \(stepNum): Solved RA=\(String(format: "%.4f", result.raDeg)) Dec=\(String(format: "%.4f", result.decDeg))")
                } catch {
                    step = .error("Solve error")
                    statusMessage = "Step \(stepNum): \(error.localizedDescription)"
                    isBusy = false
                    return
                }

                // Slew to next position (same as simulator's axis rotation, but real mount)
                if stepNum < 3 {
                    guard !Task.isCancelled else { return }
                    step = .slewing(stepNum)
                    statusMessage = String(format: "Slewing %.0f° in RA...", slewDeg)

                    do {
                        try await mountService.slewRA(degrees: slewDeg)
                        // Wait for mount to settle and camera to get new stars
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                    } catch {
                        step = .error("Slew failed")
                        statusMessage = "Slew failed: \(error.localizedDescription)"
                        isBusy = false
                        return
                    }
                }
            }

            guard !Task.isCancelled else { return }

            // Compute polar error (same as simulator)
            await computeError()

            // Auto-start correction loop if alignment succeeded
            if step == .complete {
                startCorrectionLoop(cameraViewModel: cameraViewModel)
            }
        }
    }

    /// Legacy manual start (kept for compatibility).
    func startAlignment() {
        guard !isBusy else { return }
        stopCorrectionLoop()
        positions = [nil, nil, nil]
        polarError = nil
        correctionError = nil
        step = .waitingForSolve(1)
        statusMessage = "Capturing position 1 of 3..."
    }

    /// Submit detected stars for plate solving (manual mode).
    func submitStars(_ stars: [DetectedStar]) {
        guard case .waitingForSolve(let n) = step, !isBusy else { return }
        guard stars.count >= 4 else {
            statusMessage = "Need at least 4 stars (have \(stars.count))"
            return
        }

        isBusy = true
        statusMessage = "Plate solving position \(n)..."

        Task {
            do {
                let result = try await plateSolveService.solveRobust(centroids: stars)
                guard result.success else {
                    statusMessage = "Solve failed — try adjusting exposure"
                    isBusy = false
                    return
                }

                let coord = CelestialCoord(raDeg: result.raDeg, decDeg: result.decDeg)
                positions[n - 1] = coord
                statusMessage = String(format: "Position %d: RA %.2f° Dec %.2f°", n, result.raDeg, result.decDeg)

                if n < 3 {
                    await slewToNext(afterStep: n)
                } else {
                    await computeError()
                }
            } catch {
                statusMessage = "Solve error: \(error.localizedDescription)"
                isBusy = false
            }
        }
    }

    /// Reset to idle state.
    func reset() {
        alignmentTask?.cancel()
        alignmentTask = nil
        stopCorrectionLoop()
        step = .idle
        positions = [nil, nil, nil]
        polarError = nil
        correctionError = nil
        solvedRA = nil
        solvedDec = nil
        isBusy = false
        statusMessage = "Press Start to begin alignment"
    }

    // MARK: - Correction Loop

    /// Start the continuous correction loop after 3-point calibration.
    ///
    /// Mirrors the simulator's correction mode: continuously plate-solves camera
    /// frames, subtracts sidereal motion to isolate user adjustments, and computes
    /// updated polar error for the bullseye display.
    func startCorrectionLoop(cameraViewModel: CameraViewModel) {
        guard let error = polarError, let p3 = positions[2] else { return }

        // Save reference state (same concept as simulator's referencePole/Camera)
        correctionReferenceRA = p3.raDeg
        correctionReferenceDec = p3.decDeg
        correctionReferenceTime = Date()
        correctionMountAxis = error.mountAxis
        correctionError = error
        isCorrecting = true
        step = .correcting
        isBusy = false

        correctionTask?.cancel()
        correctionTask = Task {
            while !Task.isCancelled {
                await correctionIteration(cameraViewModel: cameraViewModel)
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s between solves
            }
        }
    }

    /// Stop the correction loop.
    func stopCorrectionLoop() {
        correctionTask?.cancel()
        correctionTask = nil
        isCorrecting = false
    }

    // MARK: - Private: Auto-alignment helpers

    /// Wait for the camera to detect enough stars, polling at short intervals.
    /// Returns nil if cancelled or times out.
    private func waitForStars(
        cameraViewModel: CameraViewModel,
        minCount: Int,
        timeout: TimeInterval = 30
    ) async -> [DetectedStar]? {
        let deadline = Date().addingTimeInterval(timeout)
        while !Task.isCancelled && Date() < deadline {
            let stars = cameraViewModel.detectedStars
            if stars.count >= minCount {
                return stars
            }
            try? await Task.sleep(nanoseconds: 500_000_000) // poll every 0.5s
        }
        return nil
    }

    /// Plate solve with detector fallback (mirrors simulator's detectAndSolve).
    ///
    /// Tries with current detector stars. If solve fails, toggles the detector
    /// on the camera VM, waits for new detection, and retries.
    private func solveWithFallback(
        stars: [DetectedStar],
        cameraViewModel: CameraViewModel,
        stepLabel: String
    ) async throws -> SolveResult? {
        // Try primary solve
        let primaryDetector = cameraViewModel.forceClassicalDetector ? "classical" : "CoreML"
        statusMessage = "\(stepLabel): Plate solving (\(stars.count) stars, \(primaryDetector))..."

        if let result = try? await plateSolveService.solveRobust(centroids: stars),
           result.success {
            return result
        }

        print("[Align] Primary solve failed with \(primaryDetector) (\(stars.count) stars)")

        // Fallback: toggle detector and retry
        let originalDetector = cameraViewModel.forceClassicalDetector
        cameraViewModel.forceClassicalDetector = !originalDetector
        let fallbackDetector = cameraViewModel.forceClassicalDetector ? "classical" : "CoreML"
        statusMessage = "\(stepLabel): Retrying with \(fallbackDetector) detector..."
        print("[Align] Falling back to \(fallbackDetector) detector")

        // Wait for new detection with the alternate detector
        try? await Task.sleep(nanoseconds: 1_500_000_000) // wait for ~3 detection frames
        let fallbackStars = cameraViewModel.detectedStars

        // Restore original detector preference
        cameraViewModel.forceClassicalDetector = originalDetector

        guard fallbackStars.count >= 4 else { return nil }

        if let result = try? await plateSolveService.solveRobust(centroids: fallbackStars),
           result.success {
            return result
        }

        return nil
    }

    // MARK: - Private: Slew & Compute

    private func slewToNext(afterStep n: Int) async {
        step = .slewing(n)
        statusMessage = String(format: "Slewing %.0f° in RA...", slewDeg)

        do {
            try await mountService.slewRA(degrees: slewDeg)
            step = .waitingForSolve(n + 1)
            statusMessage = "Capturing position \(n + 1) of 3..."
            isBusy = false
        } catch {
            step = .error("Slew failed: \(error.localizedDescription)")
            statusMessage = "Slew failed: \(error.localizedDescription)"
            isBusy = false
        }
    }

    private func computeError() async {
        step = .computing
        statusMessage = "Computing polar alignment error..."

        guard let p1 = positions[0], let p2 = positions[1], let p3 = positions[2] else {
            step = .error("Missing positions")
            statusMessage = "Missing one or more solved positions"
            isBusy = false
            return
        }

        let jd = currentJulianDate()

        do {
            let error = try computePolarError(
                pos1: p1, pos2: p2, pos3: p3,
                observerLatDeg: observerLatDeg,
                observerLonDeg: observerLonDeg,
                timestampJd: jd
            )
            polarError = error
            correctionError = error
            step = .complete
            statusMessage = String(
                format: "Alignment error: %.1f' (Alt %.1f' Az %.1f')",
                error.totalErrorArcmin,
                error.altErrorArcmin,
                error.azErrorArcmin
            )

            errorTracker?.startTracking(initialError: error)
        } catch {
            step = .error("Computation failed: \(error.localizedDescription)")
            statusMessage = "Computation failed: \(error.localizedDescription)"
        }
        isBusy = false
    }

    // MARK: - Correction Loop Iteration

    /// Single iteration of the correction loop.
    ///
    /// Grabs current stars from camera, plate-solves, predicts where the camera
    /// should be (sidereal motion around the calibrated axis), and computes
    /// the remaining error from the difference.
    ///
    /// This mirrors the simulator's updateCorrectionPreview() but measures
    /// the error from actual plate solves instead of geometric computation.
    private func correctionIteration(cameraViewModel: CameraViewModel) async {
        let stars = cameraViewModel.detectedStars
        guard stars.count >= 4 else {
            statusMessage = "Correction: waiting for stars (\(stars.count) detected)"
            return
        }

        statusMessage = "Correction: plate solving (\(stars.count) stars)..."

        guard let result = try? await plateSolveService.solveRobust(centroids: stars),
              result.success else {
            statusMessage = "Correction: solve failed, retrying..."
            return
        }

        guard let axis = correctionMountAxis else { return }

        // Predict where camera should be pointing based on sidereal tracking
        // around the ORIGINAL mount axis (same as simulator's rotateAroundAxis)
        let elapsed = Date().timeIntervalSince(correctionReferenceTime)
        let siderealDegPerSec = 15.04107 / 3600.0  // ~0.00418°/s
        let rotationDeg = elapsed * siderealDegPerSec

        let predicted = GnomonicProjection.rotateAroundAxis(
            pointingRA: correctionReferenceRA,
            pointingDec: correctionReferenceDec,
            axisRA: axis.raDeg,
            axisDec: axis.decDeg,
            angleDeg: rotationDeg
        )

        // Camera shift = actual - predicted. This isolates the user's screw adjustment
        // from natural sidereal motion. The mount axis shifts by approximately the
        // same amount as the camera (they're rigidly connected).
        let dRA = result.raDeg - predicted.raDeg
        let dDec = result.decDeg - predicted.decDeg

        // Compute updated mount axis
        let newAxisRA = axis.raDeg + dRA
        let newAxisDec = axis.decDeg + dDec

        // Convert mount axis shift to alt/az error relative to true celestial pole
        let jd = currentJulianDate()
        let lst = localSiderealTime(jd: jd, longitudeDeg: observerLonDeg)

        // Mount axis in alt/az
        let ha = (lst - newAxisRA) * .pi / 180
        let decRad = newAxisDec * .pi / 180
        let latRad = observerLatDeg * .pi / 180
        let sinAlt = sin(decRad) * sin(latRad) + cos(decRad) * cos(latRad) * cos(ha)
        let mountAlt = asin(sinAlt) * 180 / .pi

        let cosAlt = cos(asin(sinAlt))
        let sinAz = -cos(decRad) * sin(ha) / cosAlt
        let cosAz = (sin(decRad) - sin(latRad) * sinAlt) / (cos(latRad) * cosAlt)
        let mountAz = atan2(sinAz, cosAz) * 180 / .pi

        // True pole in alt/az
        let poleAlt = abs(observerLatDeg)
        let poleAz: Double = observerLatDeg >= 0 ? 0 : 180

        // Error = mount axis - true pole (same as polar_error.rs)
        let altError = (mountAlt - poleAlt) * 60.0  // arcminutes
        let azError = (mountAz - poleAz) * 60.0 * cos(mountAlt * .pi / 180)
        let totalError = sqrt(altError * altError + azError * azError)

        let updatedError = PolarError(
            altErrorArcmin: altError,
            azErrorArcmin: azError,
            totalErrorArcmin: totalError,
            mountAxis: CelestialCoord(raDeg: newAxisRA, decDeg: newAxisDec)
        )
        correctionError = updatedError
        correctionMountAxis = updatedError.mountAxis
        solvedRA = result.raDeg
        solvedDec = result.decDeg

        // Update reference for next iteration (avoids drift accumulation)
        correctionReferenceRA = result.raDeg
        correctionReferenceDec = result.decDeg
        correctionReferenceTime = Date()

        // Feed to ErrorTracker for history plotting
        errorTracker?.updateFromSolve(error: updatedError, stars: stars)

        statusMessage = String(format: "Correction: %.1f' remaining (Alt %+.1f' Az %+.1f')",
                               totalError, altError, azError)
        print("[Align] Correction: total=\(String(format: "%.2f", totalError))' alt=\(String(format: "%+.2f", altError))' az=\(String(format: "%+.2f", azError))'")
    }

    // MARK: - Utilities

    /// Compute current Julian Date from system clock (UTC).
    /// Same computation as SimulatedAlignmentEngine.
    private func currentJulianDate() -> Double {
        let now = Date()
        let calendar = Calendar(identifier: .gregorian)
        let utc = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents(in: utc, from: now)
        let year = Int32(components.year ?? 2024)
        let month = UInt32(components.month ?? 1)
        let day = UInt32(components.day ?? 1)
        let hour = UInt32(components.hour ?? 0)
        let min = UInt32(components.minute ?? 0)
        let sec = Double(components.second ?? 0)
        return julianDate(year: year, month: month, day: day, hour: hour, min: min, sec: sec)
    }
}
