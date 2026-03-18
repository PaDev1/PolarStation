import Foundation
import PolarCore

/// Shared service for plate-solve-and-center workflows.
///
/// Used by both the Framing tab UI panel and the sequencer's
/// `CenterTargetExecutor`. Implements the standard NINA/Ekos pattern:
/// slew → capture → solve → sync → re-slew → repeat until converged.
@MainActor
final class CenteringSolveService: ObservableObject {

    // MARK: - Published State

    @Published var state: CenteringState = .idle
    @Published var currentAttempt: Int = 0
    @Published var lastSolveResult: SolveResult?
    @Published var lastOffsetArcmin: Double?
    @Published var lastRAOffsetArcmin: Double?
    @Published var lastDecOffsetArcmin: Double?
    @Published var statusMessage: String = ""

    /// Configurable via UI — defaults match CenterTargetExecutor.
    @Published var toleranceArcmin: Double = 3.0
    @Published var maxAttempts: Int = 3

    enum CenteringState: Equatable {
        case idle
        case solving
        case centering(Int)   // attempt number
        case converged
        case failed(String)

        var isActive: Bool {
            switch self {
            case .solving, .centering: return true
            default: return false
            }
        }
    }

    // MARK: - Dependencies

    let plateSolveService: PlateSolveService
    let mountService: MountService

    private var centeringTask: Task<Void, Never>?

    init(plateSolveService: PlateSolveService, mountService: MountService) {
        self.plateSolveService = plateSolveService
        self.mountService = mountService
    }

    // MARK: - One-Shot Solve

    /// Solve current camera field without moving the mount.
    /// Updates sky map overlay via lastSolveResult.
    func solveOnce(stars: [DetectedStar]) async {
        guard !state.isActive else { return }
        state = .solving
        statusMessage = "Solving..."

        do {
            let centroids = stars
            guard !centroids.isEmpty else {
                state = .failed("No stars detected")
                statusMessage = "No stars detected — check camera exposure"
                return
            }

            let result = try await plateSolveService.solveRobust(centroids: centroids)
            guard result.success else {
                state = .failed("Solve failed")
                statusMessage = "Plate solve failed — try longer exposure"
                return
            }

            lastSolveResult = result
            statusMessage = String(format: "Solved: RA %.4f° Dec %+.4f° rot %.1f° (%d stars, %.0fms)",
                                   result.raDeg, result.decDeg, result.rollDeg,
                                   result.matchedStars, result.solveTimeMs)
            state = .idle
        } catch {
            state = .failed(error.localizedDescription)
            statusMessage = "Solve error: \(error.localizedDescription)"
        }
    }

    // MARK: - Iterative Centering

    /// Run the center-on-target loop: slew → wait → solve → check → sync → re-slew.
    ///
    /// - Parameters:
    ///   - targetRAHours: Target RA in hours (J2000)
    ///   - targetDecDeg: Target Dec in degrees (J2000)
    ///   - starProvider: Closure that returns current detected stars (decouples from camera)
    ///   - settleSeconds: Seconds to wait after slew for mount settle + fresh stars
    func centerOnTarget(
        targetRAHours: Double,
        targetDecDeg: Double,
        starProvider: @escaping () async -> [DetectedStar],
        settleSeconds: Double = 3.0
    ) {
        guard !state.isActive else { return }

        let tolerance = toleranceArcmin
        let attempts = maxAttempts

        centeringTask?.cancel()
        centeringTask = Task { [weak self] in
            guard let self else { return }

            for attempt in 1...attempts {
                guard !Task.isCancelled else {
                    self.state = .idle
                    self.statusMessage = "Cancelled"
                    return
                }

                self.currentAttempt = attempt
                self.state = .centering(attempt)
                self.statusMessage = "Attempt \(attempt)/\(attempts): slewing to target..."

                // Step 1: Slew to target
                do {
                    try await self.mountService.gotoRADec(raHours: targetRAHours, decDeg: targetDecDeg)
                } catch {
                    self.state = .failed("Slew failed: \(error.localizedDescription)")
                    self.statusMessage = "Slew failed: \(error.localizedDescription)"
                    return
                }

                // Step 2: Wait for mount settle + fresh stars
                self.statusMessage = "Attempt \(attempt)/\(attempts): waiting for settle..."
                try? await Task.sleep(for: .seconds(settleSeconds))
                guard !Task.isCancelled else {
                    self.state = .idle
                    self.statusMessage = "Cancelled"
                    return
                }

                // Step 3: Get stars and plate solve
                self.statusMessage = "Attempt \(attempt)/\(attempts): solving..."
                let stars = await starProvider()
                guard !stars.isEmpty else {
                    self.statusMessage = "Attempt \(attempt)/\(attempts): no stars detected, retrying..."
                    continue
                }

                let result: SolveResult
                do {
                    result = try await self.plateSolveService.solveRobust(centroids: stars)
                } catch {
                    self.statusMessage = "Attempt \(attempt)/\(attempts): solve failed, retrying..."
                    continue
                }
                guard result.success else {
                    self.statusMessage = "Attempt \(attempt)/\(attempts): solve unsuccessful, retrying..."
                    continue
                }

                self.lastSolveResult = result

                // Step 4: Compute offset with cos(dec) correction
                let solvedRAHours = result.raDeg / 15.0
                let solvedDecDeg = result.decDeg
                let cosDec = cos(targetDecDeg * .pi / 180.0)
                let raOffsetDeg = (solvedRAHours - targetRAHours) * 15.0 * cosDec
                let decOffsetDeg = solvedDecDeg - targetDecDeg
                let totalOffsetDeg = sqrt(raOffsetDeg * raOffsetDeg + decOffsetDeg * decOffsetDeg)

                self.lastRAOffsetArcmin = raOffsetDeg * 60.0
                self.lastDecOffsetArcmin = decOffsetDeg * 60.0
                self.lastOffsetArcmin = totalOffsetDeg * 60.0

                let offsetStr = String(format: "%.1f′ (RA %+.1f′ Dec %+.1f′)",
                                       totalOffsetDeg * 60.0, raOffsetDeg * 60.0, decOffsetDeg * 60.0)

                // Step 5: Check convergence
                if totalOffsetDeg * 60.0 <= tolerance {
                    self.state = .converged
                    self.statusMessage = "Centered! Offset: \(offsetStr), rotation: \(String(format: "%.1f°", result.rollDeg))"
                    return
                }

                self.statusMessage = "Attempt \(attempt)/\(attempts): offset \(offsetStr), syncing..."

                // Step 6: Sync mount to solved position (corrects pointing model)
                do {
                    try await self.mountService.syncPosition(raHours: solvedRAHours, decDeg: solvedDecDeg)
                } catch {
                    self.statusMessage = "Sync failed: \(error.localizedDescription)"
                    // Continue anyway — re-slew may still improve
                }

                // Step 7: Re-slew with corrected model (loop continues)
            }

            // Exhausted all attempts
            let offsetStr = self.lastOffsetArcmin.map { String(format: "%.1f′", $0) } ?? "unknown"
            self.state = .failed("Did not converge after \(attempts) attempts (offset: \(offsetStr))")
            self.statusMessage = "Failed to center after \(attempts) attempts (offset: \(offsetStr))"
        }
    }

    // MARK: - Simulated solve

    /// Generate a synthetic star field at the mount's current position and plate-solve it locally.
    ///
    /// Uses the tetra3 star catalog to project stars onto a virtual sensor, then runs the
    /// local solver on the generated centroids. Useful for verifying solver config, FOV settings,
    /// and mount pointing accuracy without a live camera image.
    func simulateSolve(
        mountRADeg: Double,
        mountDecDeg: Double,
        fovDeg: Double,
        imageWidth: Int,
        imageHeight: Int
    ) async {
        guard !state.isActive else { return }
        state = .solving
        statusMessage = "Loading star catalog for simulation..."

        let catalog = await plateSolveService.getStarCatalog()
        guard !catalog.isEmpty else {
            state = .failed("Star catalog not loaded")
            statusMessage = "Star catalog not loaded — load it in Settings first"
            return
        }

        statusMessage = "Projecting stars at RA \(String(format: "%.2f", mountRADeg/15))h Dec \(String(format: "%+.1f", mountDecDeg))°..."

        // Project catalog stars onto the virtual sensor using gnomonic projection
        var centroids: [DetectedStar] = []
        for star in catalog {
            guard star.magnitude <= 11.0 else { continue }
            guard let pixel = GnomonicProjection.projectToPixel(
                starRA: star.raDeg, starDec: star.decDeg,
                centerRA: mountRADeg, centerDec: mountDecDeg,
                rollDeg: 0.0,
                fovDeg: fovDeg,
                imageWidth: imageWidth, imageHeight: imageHeight
            ) else { continue }

            guard pixel.x >= 0 && pixel.x < Double(imageWidth) &&
                  pixel.y >= 0 && pixel.y < Double(imageHeight) else { continue }

            let brightness = GnomonicProjection.magnitudeToBrightness(star.magnitude)
            guard brightness > 0.005 else { continue }

            centroids.append(DetectedStar(
                x: pixel.x, y: pixel.y,
                brightness: Double(brightness) * 50000,
                fwhm: 2.5, snr: Double(brightness) * 100
            ))
        }

        guard centroids.count >= 4 else {
            state = .failed("Too few stars in FOV (\(centroids.count))")
            statusMessage = "Too few stars in FOV (\(centroids.count)) — check FOV setting"
            return
        }

        statusMessage = "Simulating solve with \(centroids.count) stars..."

        // Run through local solver exactly as the real pipeline does
        plateSolveService.imageWidth = UInt32(imageWidth)
        plateSolveService.imageHeight = UInt32(imageHeight)
        plateSolveService.fovDeg = fovDeg

        do {
            let result = try await plateSolveService.solveRobust(centroids: centroids)
            guard result.success else {
                state = .failed("Simulation: solve failed")
                statusMessage = "Simulation failed — local solver could not match. Check FOV."
                return
            }

            lastSolveResult = result

            let raErr = (result.raDeg - mountRADeg) * 60.0
            let decErr = (result.decDeg - mountDecDeg) * 60.0
            let totalErr = sqrt(raErr * raErr + decErr * decErr)

            statusMessage = String(format: "Simulation: solved RA %.4f° Dec %+.3f° | error %.1f′ (%d stars)",
                                   result.raDeg, result.decDeg, totalErr, result.matchedStars)
            state = .idle
        } catch {
            state = .failed(error.localizedDescription)
            statusMessage = "Simulation error: \(error.localizedDescription)"
        }
    }

    // MARK: - Remote one-shot solve

    /// Solve using the Astrometry.net REST API (nova.astrometry.net or local Watney).
    /// Updates lastSolveResult for sky map overlay — same result path as solveOnce.
    func solveOnceRemote(jpegData: Data, apiKey: String, baseURL: String) async {
        guard !state.isActive else { return }
        state = .solving
        statusMessage = "Submitting to remote solver..."

        do {
            let result = try await plateSolveService.solveRemote(
                jpegData: jpegData,
                apiKey: apiKey,
                baseURL: baseURL,
                hintRA: mountService.status.map { $0.raHours * 15.0 },
                hintDec: mountService.status?.decDeg,
                hintRadiusDeg: 5.0,
                onStatus: { [weak self] msg in self?.statusMessage = msg }
            )
            guard result.success else {
                state = .failed("Remote solve failed")
                statusMessage = "Remote solve failed — no solution found"
                return
            }
            lastSolveResult = result
            statusMessage = String(format: "Solved: RA %.4f° Dec %+.4f° rot %.1f°",
                                   result.raDeg, result.decDeg, result.rollDeg)
            state = .idle
        } catch {
            state = .failed(error.localizedDescription)
            statusMessage = "Remote solve error: \(error.localizedDescription)"
        }
    }

    // MARK: - Remote iterative centering

    /// Iterative center-on-target using Astrometry.net remote solver.
    /// Each iteration: slew → wait → grab JPEG → remote solve → sync → re-slew.
    func centerOnTargetRemote(
        targetRAHours: Double,
        targetDecDeg: Double,
        frameProvider: @escaping () async -> Data?,
        apiKey: String,
        baseURL: String,
        settleSeconds: Double = 5.0
    ) {
        guard !state.isActive else { return }

        let tolerance = toleranceArcmin
        let attempts = maxAttempts

        centeringTask?.cancel()
        centeringTask = Task { [weak self] in
            guard let self else { return }

            for attempt in 1...attempts {
                guard !Task.isCancelled else {
                    self.state = .idle
                    self.statusMessage = "Cancelled"
                    return
                }

                self.currentAttempt = attempt
                self.state = .centering(attempt)
                self.statusMessage = "Attempt \(attempt)/\(attempts): slewing to target..."

                do {
                    try await self.mountService.gotoRADec(raHours: targetRAHours, decDeg: targetDecDeg)
                } catch {
                    self.state = .failed("Slew failed: \(error.localizedDescription)")
                    self.statusMessage = "Slew failed: \(error.localizedDescription)"
                    return
                }

                self.statusMessage = "Attempt \(attempt)/\(attempts): waiting for settle..."
                try? await Task.sleep(for: .seconds(settleSeconds))
                guard !Task.isCancelled else {
                    self.state = .idle; self.statusMessage = "Cancelled"; return
                }

                self.statusMessage = "Attempt \(attempt)/\(attempts): submitting to remote solver..."
                guard let jpegData = await frameProvider() else {
                    self.statusMessage = "Attempt \(attempt)/\(attempts): no frame available, retrying..."
                    continue
                }

                let result: SolveResult
                do {
                    result = try await self.plateSolveService.solveRemote(
                        jpegData: jpegData,
                        apiKey: apiKey,
                        baseURL: baseURL,
                        hintRA: self.mountService.status.map { $0.raHours * 15.0 },
                        hintDec: self.mountService.status?.decDeg,
                        hintRadiusDeg: 5.0,
                        onStatus: { [weak self] msg in self?.statusMessage = msg }
                    )
                } catch {
                    self.statusMessage = "Attempt \(attempt)/\(attempts): remote solve failed, retrying..."
                    continue
                }
                guard result.success else {
                    self.statusMessage = "Attempt \(attempt)/\(attempts): no solution, retrying..."
                    continue
                }

                self.lastSolveResult = result

                let solvedRAHours = result.raDeg / 15.0
                let solvedDecDeg = result.decDeg
                let cosDec = cos(targetDecDeg * .pi / 180.0)
                let raOffsetDeg = (solvedRAHours - targetRAHours) * 15.0 * cosDec
                let decOffsetDeg = solvedDecDeg - targetDecDeg
                let totalOffsetDeg = sqrt(raOffsetDeg * raOffsetDeg + decOffsetDeg * decOffsetDeg)

                self.lastRAOffsetArcmin = raOffsetDeg * 60.0
                self.lastDecOffsetArcmin = decOffsetDeg * 60.0
                self.lastOffsetArcmin = totalOffsetDeg * 60.0

                let offsetStr = String(format: "%.1f′ (RA %+.1f′ Dec %+.1f′)",
                                       totalOffsetDeg * 60.0, raOffsetDeg * 60.0, decOffsetDeg * 60.0)

                if totalOffsetDeg * 60.0 <= tolerance {
                    self.state = .converged
                    self.statusMessage = "Centered! Offset: \(offsetStr)"
                    return
                }

                self.statusMessage = "Attempt \(attempt)/\(attempts): offset \(offsetStr), syncing..."
                do {
                    try await self.mountService.syncPosition(raHours: solvedRAHours, decDeg: solvedDecDeg)
                } catch {
                    self.statusMessage = "Sync failed: \(error.localizedDescription)"
                }
            }

            let offsetStr = self.lastOffsetArcmin.map { String(format: "%.1f′", $0) } ?? "unknown"
            self.state = .failed("Did not converge after \(attempts) attempts (offset: \(offsetStr))")
            self.statusMessage = "Failed to center after \(attempts) attempts (offset: \(offsetStr))"
        }
    }

    // MARK: - Cancel

    func cancel() {
        centeringTask?.cancel()
        centeringTask = nil
        if state.isActive {
            state = .idle
            statusMessage = "Cancelled"
        }
    }
}
