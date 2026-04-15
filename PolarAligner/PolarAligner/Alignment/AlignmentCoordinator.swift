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
    /// Whether to use remote solver (Astrometry.net) as fallback.
    var useRemoteFallback: Bool = false
    /// Number of frames to stack for star detection consensus before solving.
    var detectionFrames: Int = 3

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

    /// Guided correction phase — walks the user through one axis at a time.
    enum CorrectionPhase: Equatable {
        case adjustAltitude   // User adjusts altitude screw (delta shown)
        case adjustAzimuth    // Live azimuth correction with arrow
        case done             // Both axes within threshold
    }
    @Published var correctionPhase: CorrectionPhase = .adjustAltitude

    // MARK: - Correction loop state

    /// Reference camera position from the last calibration/solve (for sidereal prediction).
    private var correctionReferenceRA: Double = 0
    private var correctionReferenceDec: Double = 0
    private var correctionReferenceTime: Date = Date()
    /// Mount axis from calibration (where the mount rotation axis points).
    private var correctionMountAxis: CelestialCoord?
    /// Mount axis in alt/az — stored in the geographic frame to avoid diurnal drift.
    /// Converting RA/Dec with an updated LST each iteration shifts the axis by the
    /// sidereal rate (~15°/hr), corrupting the correction direction. Storing alt/az
    /// directly keeps the axis fixed in the geographic frame, as it physically is.
    private var correctionAxisAlt: Double = 0
    private var correctionAxisAz:  Double = 0
    /// Camera azimuth (N=0°, E=+90°, W=-90°) from the latest correction plate solve.
    /// Used to express "turn left/right" relative to the direction the telescope is pointing.
    @Published var correctionCameraAzDeg: Double = 0
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

            // Use FOV from any previous plate solve if available
            var solvedFOV: Double? = plateSolveService.lastResult?.fovDeg
            if let fov = solvedFOV {
                plateSolveService.fovDeg = fov
                plateSolveService.fovToleranceDeg = 0.3
                print("[Align] Using previous solve FOV: \(String(format: "%.3f", fov))°")
            }

            for stepNum in 1...3 {
                guard !Task.isCancelled else { return }

                step = .waitingForSolve(stepNum)
                statusMessage = "Step \(stepNum)/3: Waiting for stars..."

                // Iterative solve: detect stars → solve → if fail, slew slightly and retry
                let maxSolveAttempts = 3
                let nudgeDeg = 3.0  // small slew in RA between retries
                var solved = false

                for attempt in 1...maxSolveAttempts {
                    guard !Task.isCancelled else { return }

                    if attempt > 1 {
                        // Nudge mount slightly in RA for a different star field
                        statusMessage = "Step \(stepNum)/3: Nudging \(String(format: "%.0f", nudgeDeg))° and retrying (attempt \(attempt)/\(maxSolveAttempts))..."
                        do {
                            try await mountService.slewRA(degrees: nudgeDeg)
                            await waitForSlewComplete()
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                        } catch {
                            continue
                        }
                    }

                    // Detect stars using multi-frame consensus
                    statusMessage = "Step \(stepNum)/3: Detecting stars..."
                    cameraViewModel.starDetectionEnabled = true
                    let stars = await collectConsensusStars(
                        cameraViewModel: cameraViewModel,
                        frameCount: detectionFrames
                    )
                    guard stars.count >= 4 else { continue }

                    // Use FOV from previous solve if available
                    if let knownFOV = solvedFOV {
                        plateSolveService.fovDeg = knownFOV
                        plateSolveService.fovToleranceDeg = 0.5
                    }

                    // Plate solve (local only, no CoreML toggle)
                    statusMessage = "Step \(stepNum)/3: Plate solving (\(stars.count) stars\(attempt > 1 ? ", attempt \(attempt)" : ""))..."
                    if let result = try? await plateSolveService.solveRobust(centroids: stars),
                       result.success {
                        let coord = CelestialCoord(raDeg: result.raDeg, decDeg: result.decDeg)
                        positions[stepNum - 1] = coord
                        solvedRA = result.raDeg
                        solvedDec = result.decDeg

                        if solvedFOV == nil {
                            solvedFOV = result.fovDeg
                            plateSolveService.log("[Align] Locked FOV to \(String(format: "%.3f", result.fovDeg))°")
                        }
                        solved = true
                        break
                    }
                }

                // If local solve failed, try remote as last resort
                if !solved && (useRemoteFallback || UserDefaults.standard.bool(forKey: "astrometryNetLocalMode")) {
                    statusMessage = "Step \(stepNum)/3: Trying remote solver..."
                    let localMode = UserDefaults.standard.bool(forKey: "astrometryNetLocalMode")
                    let apiKey = localMode ? "local" : (UserDefaults.standard.string(forKey: "astrometryNetApiKey") ?? "")
                    let baseURL = localMode
                        ? (UserDefaults.standard.string(forKey: "astrometryNetLocalURL") ?? "http://localhost:8080/api")
                        : AstrometryNetService.remoteBaseURL

                    if let jpeg = cameraViewModel.currentFrameJPEG() {
                        if let result = try? await plateSolveService.solveRemote(
                            jpegData: jpeg, apiKey: apiKey, baseURL: baseURL,
                            hintRA: mountService.status.map { $0.raHours * 15.0 },
                            hintDec: mountService.status?.decDeg,
                            hintRadiusDeg: 10.0,
                            onStatus: { [weak self] msg in
                                self?.statusMessage = "Step \(stepNum)/3: Remote — \(msg)"
                            }
                        ), result.success {
                            positions[stepNum - 1] = CelestialCoord(raDeg: result.raDeg, decDeg: result.decDeg)
                            solvedRA = result.raDeg
                            solvedDec = result.decDeg
                            if solvedFOV == nil { solvedFOV = result.fovDeg }
                            solved = true
                        }
                    }
                }

                guard solved else {
                    plateSolveService.fovToleranceDeg = 1.0
                    step = .error("Solve failed at step \(stepNum)")
                    statusMessage = "Step \(stepNum): All solvers failed"
                    isBusy = false
                    return
                }

                if let pos = positions[stepNum - 1] {
                    statusMessage = String(format: "Step %d/3: RA %.2f° Dec %+.2f°", stepNum, pos.raDeg, pos.decDeg)
                    plateSolveService.log("[Align] Step \(stepNum): RA=\(String(format: "%.4f", pos.raDeg)) Dec=\(String(format: "%.4f", pos.decDeg))")
                }

                // Slew to next position (same as simulator's axis rotation, but real mount)
                if stepNum < 3 {
                    guard !Task.isCancelled else { return }
                    step = .slewing(stepNum)
                    statusMessage = String(format: "Slewing %.0f° in RA...", slewDeg)

                    do {
                        try await mountService.slewRA(degrees: slewDeg)
                        // Poll until mount stops slewing
                        statusMessage = String(format: "Waiting for mount to settle...")
                        await waitForSlewComplete()
                        // Extra settle time for vibration damping
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    } catch {
                        step = .error("Slew failed")
                        statusMessage = "Slew failed: \(error.localizedDescription)"
                        isBusy = false
                        return
                    }
                }
            }

            // Restore default tolerance
            plateSolveService.fovToleranceDeg = 1.0

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
    /// Plate-solves every frame so the error display stays accurate even when
    /// the mount has a large misalignment (centroid drift pattern-matching
    /// breaks down when stars shift by more than the match radius).
    func startCorrectionLoop(cameraViewModel: CameraViewModel) {
        guard let error = polarError, let p3 = positions[2] else { return }

        // Save reference state
        correctionReferenceRA = p3.raDeg
        correctionReferenceDec = p3.decDeg
        correctionReferenceTime = Date()
        correctionMountAxis = error.mountAxis
        // Convert axis to alt/az ONCE using the current LST. The mount axis is physically
        // fixed in the geographic frame (alt/az). Recomputing from RA/Dec with a later LST
        // would place the axis at a different alt/az due to Earth's rotation (~15°/hr).
        let jd0  = currentJulianDate()
        let lst0 = localSiderealTime(jd: jd0, longitudeDeg: observerLonDeg)
        let initAA = altAzFromRADec(raDeg: error.mountAxis.raDeg, decDeg: error.mountAxis.decDeg, lstDeg: lst0)
        correctionAxisAlt = initAA.alt
        correctionAxisAz  = initAA.az
        let initCamAA = altAzFromRADec(raDeg: p3.raDeg, decDeg: p3.decDeg, lstDeg: lst0)
        correctionCameraAzDeg = initCamAA.az
        correctionError = error
        correctionPhase = .adjustAltitude

        isCorrecting = true
        step = .correcting
        isBusy = false

        correctionTask?.cancel()
        correctionTask = Task {
            while !Task.isCancelled {
                cameraViewModel.starDetectionEnabled = true
                let freshStars = await cameraViewModel.waitForFreshDetection()

                guard !Task.isCancelled else { break }

                guard freshStars.count >= 4 else {
                    statusMessage = "Tracking: waiting for stars (\(freshStars.count) detected)"
                    continue
                }

                await correctionIteration(stars: freshStars)
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
    /// Poll mount status until slewing stops (or timeout).
    private func waitForSlewComplete(timeout: TimeInterval = 120) async {
        let deadline = Date().addingTimeInterval(timeout)

        // Phase 1: Wait until mount reports slewing=true (confirms it started)
        let slewStart = Date().addingTimeInterval(5.0) // max 5s to start
        while !Task.isCancelled && Date() < slewStart {
            if let status = mountService.status, status.slewing {
                break
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        // Phase 2: Wait until mount reports slewing=false (slew complete)
        while !Task.isCancelled && Date() < deadline {
            if let status = mountService.status, !status.slewing {
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    /// Collect stars from multiple frames and return only stars that appear consistently.
    /// This filters noise, hot pixels, and false detections while catching faint stars.
    private func collectConsensusStars(
        cameraViewModel: CameraViewModel,
        frameCount: Int,
        matchRadius: Double = 5.0,
        minAppearances: Int = 2
    ) async -> [DetectedStar] {
        var allDetections: [[DetectedStar]] = []

        for i in 0..<frameCount {
            guard !Task.isCancelled else { return [] }
            statusMessage = statusMessage.replacingOccurrences(
                of: "Detecting.*", with: "Detecting stars (frame \(i+1)/\(frameCount))...",
                options: .regularExpression
            )
            let stars = await cameraViewModel.waitForFreshDetection()
            if !stars.isEmpty {
                allDetections.append(stars)
            }
        }

        guard allDetections.count >= 2 else {
            return allDetections.first ?? []
        }

        // Use first frame as reference, count how many subsequent frames each star appears in
        let reference = allDetections[0]
        var starScores: [(star: DetectedStar, count: Int, totalBrightness: Double)] = reference.map {
            ($0, 1, $0.brightness)
        }

        for frameStars in allDetections.dropFirst() {
            for (i, entry) in starScores.enumerated() {
                // Find nearest match in this frame
                for star in frameStars {
                    let dx = star.x - entry.star.x
                    let dy = star.y - entry.star.y
                    let dist = sqrt(dx * dx + dy * dy)
                    if dist < matchRadius {
                        starScores[i].count += 1
                        starScores[i].totalBrightness += star.brightness
                        break
                    }
                }
            }

            // Also check for stars in this frame not in reference (new detections)
            for star in frameStars {
                let alreadyTracked = starScores.contains { entry in
                    let dx = star.x - entry.star.x
                    let dy = star.y - entry.star.y
                    return sqrt(dx * dx + dy * dy) < matchRadius
                }
                if !alreadyTracked {
                    starScores.append((star, 1, star.brightness))
                }
            }
        }

        // Keep stars that appeared in at least minAppearances frames
        let consensus = starScores
            .filter { $0.count >= minAppearances }
            .sorted { $0.totalBrightness > $1.totalBrightness }
            .map { $0.star }

        plateSolveService.log("[Consensus] \(allDetections.count) frames, \(reference.count)→\(consensus.count) stars (min \(minAppearances) appearances)")

        return consensus
    }

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
        statusMessage = "\(stepLabel): Plate solving (\(stars.count) stars)..."

        if let result = try? await plateSolveService.solveRobust(centroids: stars),
           result.success {
            return result
        }

        print("[Align] Primary solve failed (\(stars.count) stars)")

        // Try remote solver if enabled
        let localMode = UserDefaults.standard.bool(forKey: "astrometryNetLocalMode")
        plateSolveService.log("[Align] Local solve failed. Remote fallback=\(useRemoteFallback) local=\(localMode)")
        if useRemoteFallback || localMode {
            statusMessage = "\(stepLabel): Trying remote solver..."
            let apiKey = localMode ? "local" : (UserDefaults.standard.string(forKey: "astrometryNetApiKey") ?? "")
            let baseURL = localMode
                ? (UserDefaults.standard.string(forKey: "astrometryNetLocalURL") ?? "http://localhost:8080/api")
                : AstrometryNetService.remoteBaseURL

            let jpeg = cameraViewModel.currentFrameJPEG()
            plateSolveService.log("[Align] JPEG frame: \(jpeg != nil ? "\(jpeg!.count) bytes" : "nil")")
            if let jpeg {
                if let result = try? await plateSolveService.solveRemote(
                    jpegData: jpeg, apiKey: apiKey, baseURL: baseURL,
                    hintRA: mountService.status.map { $0.raHours * 15.0 },
                    hintDec: mountService.status?.decDeg,
                    hintRadiusDeg: 10.0,
                    onStatus: { [weak self] msg in
                        self?.statusMessage = "\(stepLabel): Remote — \(msg)"
                    }
                ), result.success {
                    plateSolveService.log("[Align] Remote solve succeeded")
                    return result
                }
            }
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

        // Log all 3 positions for debugging
        print("[Align] === POLAR ERROR COMPUTATION ===")
        print("[Align] P1: RA=\(String(format: "%.4f", p1.raDeg))° Dec=\(String(format: "%+.4f", p1.decDeg))°")
        print("[Align] P2: RA=\(String(format: "%.4f", p2.raDeg))° Dec=\(String(format: "%+.4f", p2.decDeg))°")
        print("[Align] P3: RA=\(String(format: "%.4f", p3.raDeg))° Dec=\(String(format: "%+.4f", p3.decDeg))°")
        print("[Align] Observer: lat=\(String(format: "%.4f", observerLatDeg))° lon=\(String(format: "%.4f", observerLonDeg))° JD=\(String(format: "%.6f", jd))")
        // Check Dec consistency — large spread suggests a bad plate solve
        let decs = [p1.decDeg, p2.decDeg, p3.decDeg]
        let decSpread = decs.max()! - decs.min()!
        print("[Align] Dec spread: \(String(format: "%.2f", decSpread))° (should be < ~5° for a well-aligned mount)")
        if decSpread > 20 {
            print("[Align] WARNING: Dec spread > 20° — likely a bad plate solve. Axis estimate will be unreliable.")
        }

        do {
            let error = try computePolarError(
                pos1: p1, pos2: p2, pos3: p3,
                observerLatDeg: observerLatDeg,
                observerLonDeg: observerLonDeg,
                timestampJd: jd
            )
            print("[Align] Computed axis: RA=\(String(format: "%.4f", error.mountAxis.raDeg))° Dec=\(String(format: "%+.4f", error.mountAxis.decDeg))°")
            print("[Align] Error: Alt=\(String(format: "%+.1f", error.altErrorArcmin))' Az=\(String(format: "%+.1f", error.azErrorArcmin))' Total=\(String(format: "%.1f", error.totalErrorArcmin))'")
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
    /// Plate-solves the given stars, predicts where the camera should be
    /// (sidereal motion around the calibrated axis), and computes the
    /// remaining polar error from the residual.
    ///
    /// Using plate solving for every update instead of centroid drift ensures
    /// the tracking works even with large alignment errors (where star patterns
    /// shift too far for centroid matching to succeed).
    private func correctionIteration(stars: [DetectedStar]) async {
        statusMessage = "Correction: plate solving (\(stars.count) stars)..."

        guard let result = try? await plateSolveService.solveRobust(centroids: stars),
              result.success else {
            statusMessage = "Correction: solve failed, retrying..."
            return
        }

        let jd = currentJulianDate()
        let lstDeg = localSiderealTime(jd: jd, longitudeDeg: observerLonDeg)
        let latRad = observerLatDeg * .pi / 180

        // For a TRACKING mount the camera RA/Dec is approximately constant between
        // iterations (the drive compensates Earth's rotation). The predicted position
        // is simply the last reference RA/Dec evaluated at the current LST.
        // Any deviation between actual and predicted is entirely due to:
        //   • a screw adjustment the user just made, OR
        //   • very slow Dec drift from polar misalignment (~arcseconds per minute).
        let actualAA    = altAzFromRADec(raDeg: result.raDeg,          decDeg: result.decDeg,          lstDeg: lstDeg)
        let predictedAA = altAzFromRADec(raDeg: correctionReferenceRA, decDeg: correctionReferenceDec, lstDeg: lstDeg)
        correctionCameraAzDeg = actualAA.az
        let dAlt = actualAA.alt - predictedAA.alt
        var dAz  = actualAA.az  - predictedAA.az
        if dAz >  180 { dAz -= 360 }
        if dAz < -180 { dAz += 360 }

        // Apply the same shift to the mount axis (rigid body identity).
        // Use the stored alt/az directly — the mount axis is fixed in the geographic
        // frame, so its alt/az never drifts. Re-converting from RA/Dec with an updated
        // LST would introduce ~15°/hr of spurious azimuth drift.
        let newAxisAlt = correctionAxisAlt + dAlt
        let newAxisAz  = correctionAxisAz  + dAz
        correctionAxisAlt = newAxisAlt
        correctionAxisAz  = newAxisAz

        // True pole alt/az
        let poleAlt = abs(observerLatDeg)
        let poleAz: Double = observerLatDeg >= 0 ? 0 : 180

        // Polar error from updated axis
        let altError = (newAxisAlt - poleAlt) * 60.0  // arcminutes
        var azDiff = newAxisAz - poleAz
        if azDiff >  180 { azDiff -= 360 }
        if azDiff < -180 { azDiff += 360 }
        let azError    = azDiff * 60.0 * cos(newAxisAlt * .pi / 180)
        let totalError = sqrt(altError * altError + azError * azError)

        // Convert updated axis alt/az → RA/Dec for the next iteration's sidereal prediction
        let altR = newAxisAlt * .pi / 180
        let azR  = newAxisAz  * .pi / 180
        let sinDec = sin(latRad) * sin(altR) + cos(latRad) * cos(altR) * cos(azR)
        let newAxisDec = asin(max(-1.0, min(1.0, sinDec))) * 180 / .pi
        let sinHA = -sin(azR) * cos(altR)
        let cosHA =  sin(altR) * cos(latRad) - cos(altR) * sin(latRad) * cos(azR)
        var newAxisRA = lstDeg - atan2(sinHA, cosHA) * 180 / .pi
        newAxisRA = newAxisRA.truncatingRemainder(dividingBy: 360)
        if newAxisRA < 0 { newAxisRA += 360 }

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

        // Auto-advance guided correction phase
        if correctionPhase == .adjustAltitude && abs(altError) < 5.0 {
            correctionPhase = .adjustAzimuth
        }
        if correctionPhase == .adjustAzimuth && totalError < 2.0 {
            correctionPhase = .done
            // Sync mount to the plate-solved position so GoTo and tracking are accurate
            Task {
                do {
                    try await mountService.syncPosition(raHours: result.raDeg / 15.0, decDeg: result.decDeg)
                    print("[Align] Synced mount to plate-solved position: RA=\(String(format: "%.4f", result.raDeg))° Dec=\(String(format: "%+.2f", result.decDeg))°")
                } catch {
                    print("[Align] Mount sync failed: \(error)")
                }
            }
        }
        // Allow returning to azimuth phase if user overshoots after "done"
        if correctionPhase == .done && totalError >= 3.0 {
            correctionPhase = abs(altError) >= 5.0 ? .adjustAltitude : .adjustAzimuth
        }

        statusMessage = String(format: "Correction: %.1f' remaining (Alt %+.1f' Az %+.1f')",
                               totalError, altError, azError)
        print("[Align] Correction: total=\(String(format: "%.2f", totalError))' alt=\(String(format: "%+.2f", altError))' az=\(String(format: "%+.2f", azError))'")
    }

    // MARK: - Utilities

    /// Convert RA/Dec (degrees) to Alt/Az (degrees) for the observer's location at the given LST.
    ///
    /// The mount is a rigid body: when the user turns a screw, the camera and the mount axis
    /// shift by the SAME angle in alt/az. Working in alt/az is the geometrically correct frame
    /// for propagating the camera residual to the axis. Adding camera ΔRA directly to axis RA
    /// is wrong because cos(Dec) scaling differs ~200× between camera (~60-80°) and axis (~90°).
    private func altAzFromRADec(raDeg: Double, decDeg: Double, lstDeg: Double) -> (alt: Double, az: Double) {
        let latRad = observerLatDeg * .pi / 180
        let ha     = (lstDeg - raDeg) * .pi / 180
        let dec    = decDeg * .pi / 180
        let sinAlt = sin(dec) * sin(latRad) + cos(dec) * cos(latRad) * cos(ha)
        let clamped = max(-1.0, min(1.0, sinAlt))
        let alt    = asin(clamped)
        let cosAlt = sqrt(1.0 - clamped * clamped)
        if cosAlt < 1e-9 { return (alt * 180 / .pi, 0) }
        let sinAz = -cos(dec) * sin(ha) / cosAlt
        let cosAz = (sin(dec) - sin(latRad) * clamped) / (cos(latRad) * cosAlt)
        return (alt * 180 / .pi, atan2(sinAz, cosAz) * 180 / .pi)
    }

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
