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
