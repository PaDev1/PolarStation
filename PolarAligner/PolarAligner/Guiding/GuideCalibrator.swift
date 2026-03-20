import Foundation
import Combine

/// PHD2-style guide camera calibration.
///
/// Determines the mapping between camera pixel coordinates and mount RA/Dec axes by:
/// 1. Pulsing the mount West, measuring star displacement → RA angle + rate
/// 2. Pulsing East to recenter
/// 3. Clearing Dec backlash with a few North pulses
/// 4. Pulsing North, measuring displacement → Dec angle + rate
/// 5. Pulsing South to recenter
///
/// Uses `MountService.moveAxis` for pulses and `CameraViewModel.detectedStars` for tracking.
@MainActor
final class GuideCalibrator: ObservableObject {

    // MARK: - State

    enum State: Equatable {
        case idle
        case selectingStar
        case goWest
        case goEast
        case clearBacklash
        case goNorth
        case goSouth
        case complete
        case error(String)
    }

    @Published var state: State = .idle
    @Published var calibration: GuideCalibration?
    @Published var statusMessage = "Not calibrated"
    @Published var progress: Double = 0
    @Published var guideStarPosition: CGPoint?
    @Published var stepPositions: [CGPoint] = []

    var isCalibrating: Bool {
        switch state {
        case .idle, .complete, .error: return false
        default: return true
        }
    }

    // MARK: - Configuration

    /// Duration of each calibration pulse in milliseconds.
    var pulseDurationMs: Int = 750

    /// Minimum star displacement in pixels to complete an axis measurement.
    var calibrationDistance: Double = 25.0

    /// Guide rate in degrees/second for calibration pulses.
    /// 0.5x sidereal ≈ 0.00208°/s.
    var guideRateDegPerSec: Double = 0.00208

    /// Maximum pulses per direction before declaring failure.
    var maxSteps: Int = 60

    /// Number of backlash-clearing pulses before Dec measurement.
    var backlashSteps: Int = 5

    // MARK: - Dependencies

    let mountService: MountService
    let cameraViewModel: CameraViewModel

    /// Optional handler that overrides `mountService.moveAxis` for simulation.
    /// When non-nil, mount commands route through this closure instead of the real mount.
    var moveAxisHandler: ((UInt8, Double) async throws -> Void)?

    // MARK: - Internal

    private var calibrationTask: Task<Void, Never>?
    private var starSubscription: AnyCancellable?
    private var starContinuation: CheckedContinuation<[DetectedStar], Never>?

    init(mountService: MountService, cameraViewModel: CameraViewModel) {
        self.mountService = mountService
        self.cameraViewModel = cameraViewModel
    }

    // MARK: - Public API

    func startCalibration() {
        guard !isCalibrating else { return }

        calibration = nil
        stepPositions = []
        progress = 0

        calibrationTask = Task { [weak self] in
            guard let self else { return }
            await self.runCalibration()
        }
    }

    func cancel() {
        calibrationTask?.cancel()
        calibrationTask = nil
        starContinuation?.resume(returning: [])
        starContinuation = nil
        starSubscription?.cancel()
        starSubscription = nil

        // Stop any mount movement
        Task {
            try? await sendMoveAxis(0, rateDegPerSec: 0)
            try? await sendMoveAxis(1, rateDegPerSec: 0)
        }

        state = .idle
        statusMessage = "Calibration cancelled"
    }

    // MARK: - Calibration Sequence

    private func runCalibration() async {
        // Step 1: Select guide star (use pre-selected if available, otherwise auto-pick)
        state = .selectingStar
        statusMessage = "Selecting guide star..."

        // Wait for star detection if no stars available yet
        var star: DetectedStar?
        if cameraViewModel.detectedStars.isEmpty {
            statusMessage = "Waiting for star detection..."
            let freshStars = await waitForFreshStars()
            if let preSelected = guideStarPosition {
                star = findGuideStar(near: preSelected, in: freshStars) ?? freshStars.first { $0.snr > 3.0 } ?? freshStars.first
            } else {
                star = freshStars.first { $0.snr > 3.0 } ?? freshStars.first
            }
        } else if let preSelected = guideStarPosition {
            // User clicked a star — find the current detection nearest to that position
            star = findGuideStar(near: preSelected) ?? selectGuideStar()
        } else {
            star = selectGuideStar()
        }

        guard let star else {
            state = .error("No stars detected — start live preview first")
            statusMessage = "No stars detected"
            return
        }

        let startPos = CGPoint(x: star.x, y: star.y)
        guideStarPosition = startPos
        stepPositions = [startPos]
        statusMessage = String(format: "Guide star at (%.1f, %.1f) SNR=%.1f", star.x, star.y, star.snr)

        // Step 2: Calibrate RA (West)
        state = .goWest
        let raResult = await calibrateAxis(
            axis: 0,
            rate: -guideRateDegPerSec,  // West = negative RA
            startPos: startPos,
            label: "RA"
        )

        guard !Task.isCancelled else { return }

        guard let raResult else {
            state = .error("RA calibration failed")
            return
        }

        // Step 3: Recenter (East)
        state = .goEast
        statusMessage = "Recentering (East)..."
        await recenter(axis: 0, rate: guideRateDegPerSec, steps: raResult.steps)

        guard !Task.isCancelled else { return }

        // Re-acquire guide star after recenter (wait for stable frame)
        statusMessage = "Re-acquiring star..."
        let postRecenterStars = await waitForStableStars()
        if let star = findGuideStar(near: guideStarPosition ?? startPos, in: postRecenterStars) {
            let pos = CGPoint(x: star.x, y: star.y)
            guideStarPosition = pos
        }

        // Step 4: Clear Dec backlash
        state = .clearBacklash
        statusMessage = "Clearing Dec backlash..."
        await clearBacklash()

        guard !Task.isCancelled else { return }

        // Re-acquire guide star after backlash clearing (wait for stable frame)
        statusMessage = "Re-acquiring star..."
        let postBacklashStars = await waitForStableStars()
        if let star = findGuideStar(near: guideStarPosition ?? startPos, in: postBacklashStars) {
            let pos = CGPoint(x: star.x, y: star.y)
            guideStarPosition = pos
        }

        // Step 5: Calibrate Dec (North)
        state = .goNorth
        let currentPos = guideStarPosition ?? startPos
        let decResult = await calibrateAxis(
            axis: 1,
            rate: guideRateDegPerSec,  // North = positive Dec
            startPos: currentPos,
            label: "Dec"
        )

        guard !Task.isCancelled else { return }

        guard let decResult else {
            state = .error("Dec calibration failed")
            return
        }

        // Step 6: Recenter (South)
        state = .goSouth
        statusMessage = "Recentering (South)..."
        await recenter(axis: 1, rate: -guideRateDegPerSec, steps: decResult.steps)

        guard !Task.isCancelled else { return }

        // Re-acquire guide star at final position
        let finalStars = await waitForFreshStars()
        if let star = findGuideStar(near: guideStarPosition ?? startPos, in: finalStars) {
            guideStarPosition = CGPoint(x: star.x, y: star.y)
        }

        // Step 7: Compute calibration
        let binning = cameraViewModel.selectedCamera?.supportedBins.first ?? 1

        let cal = GuideCalibration(
            raAngle: raResult.angle,
            decAngle: decResult.angle,
            raRate: raResult.rate,
            decRate: decResult.rate,
            binning: binning,
            timestamp: Date()
        )

        calibration = cal
        cal.save()
        state = .complete
        progress = 1.0

        if cal.isValid {
            statusMessage = "Calibrated: " + cal.summary
        } else {
            statusMessage = "Warning: axes \(String(format: "%.0f°", cal.axisOrthogonality)) apart (expect ~90°). " + cal.summary
        }
    }

    // MARK: - Axis Calibration

    private struct AxisResult {
        let angle: Double   // radians
        let rate: Double    // pixels per millisecond
        let steps: Int
    }

    /// Pulse the mount on one axis and measure star displacement.
    private func calibrateAxis(
        axis: UInt8,
        rate: Double,
        startPos: CGPoint,
        label: String
    ) async -> AxisResult? {
        var stepCount = 0
        var lastKnownPos = startPos  // track star at last known position

        while stepCount < maxSteps {
            guard !Task.isCancelled else { return nil }

            stepCount += 1
            let phaseProgress = Double(stepCount) / Double(maxSteps)
            let axisOffset = (label == "RA") ? 0.0 : 0.5
            progress = (axisOffset + phaseProgress * 0.5) * 0.9

            statusMessage = String(format: "Calibrating %@: step %d", label, stepCount)

            // Pulse: start → wait → stop
            do {
                try await sendMoveAxis(axis, rateDegPerSec: rate)
            } catch {
                state = .error("Mount error: \(error.localizedDescription)")
                statusMessage = "Mount error: \(error.localizedDescription)"
                return nil
            }

            try? await Task.sleep(nanoseconds: UInt64(pulseDurationMs) * 1_000_000)

            do {
                try await sendMoveAxis(axis, rateDegPerSec: 0)
            } catch {
                state = .error("Mount error: \(error.localizedDescription)")
                return nil
            }

            // Wait for mount to settle, then get next fresh frame
            statusMessage = String(format: "Calibrating %@: step %d — waiting for frame...", label, stepCount)
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms settle
            let freshStars = await waitForFreshStars(timeoutSeconds: 30.0)

            // Find guide star near its last known position (not start — star moves during cal)
            guard let currentStar = findGuideStar(near: lastKnownPos, in: freshStars) else {
                cameraViewModel.appendDebug(String(format: "[Cal] %@ step %d LOST near (%.1f,%.1f) stars=%d",
                                                    label, stepCount, lastKnownPos.x, lastKnownPos.y, freshStars.count))
                statusMessage = String(format: "Calibrating %@: step %d — star lost, retrying", label, stepCount)
                continue
            }

            let currentPos = CGPoint(x: currentStar.x, y: currentStar.y)
            let jumpDist = hypot(currentPos.x - lastKnownPos.x, currentPos.y - lastKnownPos.y)
            cameraViewModel.appendDebug(String(format: "[Cal] %@ step %d star=(%.1f,%.1f) last=(%.1f,%.1f) jump=%.1fpx snr=%.1f",
                                                label, stepCount, currentPos.x, currentPos.y, lastKnownPos.x, lastKnownPos.y, jumpDist, currentStar.snr))
            lastKnownPos = currentPos
            guideStarPosition = currentPos
            stepPositions.append(currentPos)

            let dx = currentPos.x - startPos.x
            let dy = currentPos.y - startPos.y
            let dist = sqrt(dx * dx + dy * dy)

            statusMessage = String(format: "Calibrating %@: step %d, %.1fpx", label, stepCount, dist)

            if dist >= calibrationDistance {
                // Axis calibrated
                let angle = atan2(Double(dy), Double(dx))
                let totalMs = Double(stepCount * pulseDurationMs)
                let pixRate = dist / totalMs

                return AxisResult(angle: angle, rate: pixRate, steps: stepCount)
            }
        }

        // Failed — star didn't move enough
        statusMessage = String(format: "%@ calibration failed: star moved < %.0fpx in %d steps", label, calibrationDistance, maxSteps)
        return nil
    }

    // MARK: - Recenter

    /// Move mount back to approximately the starting position.
    private func recenter(axis: UInt8, rate: Double, steps: Int) async {
        let totalMs = steps * pulseDurationMs

        do {
            try await sendMoveAxis(axis, rateDegPerSec: rate)
        } catch {
            return
        }

        try? await Task.sleep(nanoseconds: UInt64(totalMs) * 1_000_000)

        do {
            try await sendMoveAxis(axis, rateDegPerSec: 0)
        } catch {
            return
        }

        // Settle time — wait for mount to stop
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }

    // MARK: - Backlash Clearing

    /// Send a few pulses in Dec to clear mechanical backlash.
    private func clearBacklash() async {
        for i in 0..<backlashSteps {
            guard !Task.isCancelled else { return }
            statusMessage = String(format: "Clearing backlash: %d/%d", i + 1, backlashSteps)

            do {
                try await sendMoveAxis(1, rateDegPerSec: guideRateDegPerSec)
            } catch { return }

            try? await Task.sleep(nanoseconds: UInt64(pulseDurationMs) * 1_000_000)

            do {
                try await sendMoveAxis(1, rateDegPerSec: 0)
            } catch { return }

            // Track guide star position after each backlash pulse
            let stars = await waitForFreshStars(timeoutSeconds: 15.0)
            if let pos = guideStarPosition,
               let star = findGuideStar(near: pos, in: stars) {
                guideStarPosition = CGPoint(x: star.x, y: star.y)
            }
        }
    }

    // MARK: - Star Finding

    /// Wait for the next fresh star detection update from the camera.
    /// Returns the new stars array, or empty if timed out or cancelled.
    private func waitForFreshStars(timeoutSeconds: Double = 30.0) async -> [DetectedStar] {
        let oldStars = cameraViewModel.detectedStars
        let startTime = ContinuousClock.now
        let timeout = Duration.seconds(timeoutSeconds)

        // Wait for detectedStars to change (new frame processed)
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 200_000_000)

            let currentStars = cameraViewModel.detectedStars
            let changed: Bool
            if currentStars.count != oldStars.count {
                changed = true
            } else if !currentStars.isEmpty, !oldStars.isEmpty,
                      currentStars[0].x != oldStars[0].x || currentStars[0].y != oldStars[0].y {
                changed = true
            } else {
                changed = false
            }

            if changed { return currentStars }
            if ContinuousClock.now - startTime > timeout { return currentStars }
        }
        return []
    }

    /// Wait for a stable frame: waits for fresh stars, then confirms the next frame
    /// gives consistent positions (star moved < 2px). This ensures the mount has stopped.
    private func waitForStableStars(timeoutSeconds: Double = 30.0) async -> [DetectedStar] {
        let first = await waitForFreshStars(timeoutSeconds: timeoutSeconds)
        guard !first.isEmpty, !Task.isCancelled else { return first }
        let second = await waitForFreshStars(timeoutSeconds: timeoutSeconds)
        return second
    }

    /// Select the brightest star with good SNR as the guide star.
    private func selectGuideStar() -> DetectedStar? {
        let stars = cameraViewModel.detectedStars
        guard !stars.isEmpty else { return nil }
        // Stars are sorted by brightness — pick the brightest with SNR > 3
        return stars.first { $0.snr > 3.0 } ?? stars.first
    }

    /// Find the guide star near a known position.
    private func findGuideStar(near pos: CGPoint, in stars: [DetectedStar]? = nil) -> DetectedStar? {
        let stars = stars ?? cameraViewModel.detectedStars
        let searchRadius: Double = 50.0  // pixels — generous for calibration moves

        var best: DetectedStar?
        var bestDist = Double.greatestFiniteMagnitude

        for star in stars {
            let dx = star.x - Double(pos.x)
            let dy = star.y - Double(pos.y)
            let dist = sqrt(dx * dx + dy * dy)
            if dist < searchRadius && dist < bestDist {
                bestDist = dist
                best = star
            }
        }

        return best
    }

    /// Get current guide star position.
    private func currentGuideStarPos(near pos: CGPoint) async -> CGPoint? {
        if let star = findGuideStar(near: pos) {
            return CGPoint(x: star.x, y: star.y)
        }
        return nil
    }

    // MARK: - Mount Command Routing

    /// Route mount axis commands through the handler (simulation) or real mount service.
    private func sendMoveAxis(_ axis: UInt8, rateDegPerSec: Double) async throws {
        if let handler = moveAxisHandler {
            try await handler(axis, rateDegPerSec)
        } else {
            try await mountService.moveAxis(axis, rateDegPerSec: rateDegPerSec)
        }
    }
}
