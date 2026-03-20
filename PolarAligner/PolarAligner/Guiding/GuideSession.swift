import Foundation

/// A single guide cycle measurement.
struct GuideSample {
    let timestamp: Date
    /// RA tracking error in arcseconds (positive = star drifted East).
    let raErrorArcsec: Double
    /// Dec tracking error in arcseconds (positive = star drifted North).
    let decErrorArcsec: Double
    /// RA correction pulse sent (milliseconds, signed: positive = East).
    let raCorrectionMs: Double
    /// Dec correction pulse sent (milliseconds, signed: positive = North).
    let decCorrectionMs: Double
}

/// Tracks guide samples, computes running RMS statistics, and runs the guide loop.
///
/// The guide loop measures the guide star's displacement from a reference position,
/// converts it to RA/Dec error using calibration data, computes proportional corrections,
/// sends correction pulses, and records each cycle as a GuideSample.
@MainActor
final class GuideSession: ObservableObject {

    /// All samples in the current session.
    @Published var samples: [GuideSample] = []

    /// Running RMS of RA error in arcseconds.
    @Published var raRMSArcsec: Double = 0

    /// Running RMS of Dec error in arcseconds.
    @Published var decRMSArcsec: Double = 0

    /// Running total RMS in arcseconds.
    @Published var totalRMSArcsec: Double = 0

    /// Peak RA error seen in the session.
    @Published var raPeakArcsec: Double = 0

    /// Peak Dec error seen in the session.
    @Published var decPeakArcsec: Double = 0

    /// Whether guiding is active.
    @Published var isGuiding = false

    /// Status message.
    @Published var statusMessage = "Idle"

    // MARK: - Guide Parameters (live — UI binds directly, read each cycle)

    /// RA aggressiveness 0–100%.
    @Published var raAggressiveness: Double = 70
    /// Dec aggressiveness 0–100%.
    @Published var decAggressiveness: Double = 70
    /// RA hysteresis 0–100%.
    @Published var raHysteresis: Double = 10
    /// Minimum correction threshold in arcseconds.
    @Published var minMoveArcsec: Double = 0.2
    /// Dec guiding mode: "both", "north", "south", "off".
    @Published var decMode: String = "both"
    /// Pixel scale in arcsec/pixel.
    @Published var pixelScaleArcsecPerPix: Double = 1.5

    /// Maximum number of samples to retain (older samples are trimmed).
    var maxSamples: Int = 600  // ~10 minutes at 1 Hz

    /// Guide loop interval in seconds.
    var guideIntervalSec: Double = 1.0

    // MARK: - Guide Loop State

    private var guideTask: Task<Void, Never>?

    /// Reference position of the guide star (lock position — where we want the star to be).
    private var referencePosition: CGPoint?

    /// Last known star position — used for finding the star each frame (tracks actual position).
    private var lastKnownStarPosition: CGPoint?

    /// Previous RA correction for hysteresis calculation.
    private var previousRaCorrectionMs: Double = 0

    /// Weak reference to camera view model for debug logging.
    private weak var debugLogger: CameraViewModel?

    // MARK: - Guide Loop

    /// Start the guide loop. Requires calibration and an active camera.
    func startGuiding(
        calibrator: GuideCalibrator,
        cameraViewModel: CameraViewModel
    ) {
        guard !isGuiding else { return }
        guard let calibration = calibrator.calibration else {
            statusMessage = "No calibration"
            return
        }

        debugLogger = cameraViewModel

        // Set reference position to current guide star position
        guard let starPos = calibrator.guideStarPosition else {
            // Try to find a star
            let stars = cameraViewModel.detectedStars
            guard let bright = stars.first(where: { $0.snr > 3.0 }) ?? stars.first else {
                statusMessage = "No guide star"
                return
            }
            calibrator.guideStarPosition = CGPoint(x: bright.x, y: bright.y)
            referencePosition = CGPoint(x: bright.x, y: bright.y)
            lastKnownStarPosition = referencePosition
            return startGuiding(calibrator: calibrator, cameraViewModel: cameraViewModel)
        }

        referencePosition = starPos
        lastKnownStarPosition = starPos
        previousRaCorrectionMs = 0
        isGuiding = true
        statusMessage = "Guiding..."

        log("[Guide] START ref=(\(String(format:"%.1f,%.1f", starPos.x, starPos.y))) aggr=\(Int(raAggressiveness))/\(Int(decAggressiveness)) hyst=\(Int(raHysteresis)) minMove=\(String(format:"%.2f", minMoveArcsec))\"")

        guideTask = Task { [weak self] in
            guard let self else { return }
            await self.guideLoop(
                calibrator: calibrator,
                cameraViewModel: cameraViewModel,
                calibration: calibration
            )
        }
    }

    func stopGuiding() {
        guideTask?.cancel()
        guideTask = nil
        isGuiding = false
        statusMessage = "Stopped"
        log("[Guide] STOPPED")
    }

    /// Dither: shift the guide reference position by a random offset within `pixels` radius.
    /// The guide loop will then correct the mount to the new position, effectively dithering.
    func dither(pixels: Double) {
        guard isGuiding, let ref = referencePosition else { return }
        let angle = Double.random(in: 0..<(2 * .pi))
        let radius = Double.random(in: 0.5...pixels)
        let dx = radius * cos(angle)
        let dy = radius * sin(angle)
        referencePosition = CGPoint(x: ref.x + dx, y: ref.y + dy)
        log("[Guide] DITHER by (\(String(format: "%.1f", dx)), \(String(format: "%.1f", dy))) px")
        statusMessage = "Dithering..."
    }

    private func guideLoop(
        calibrator: GuideCalibrator,
        cameraViewModel: CameraViewModel,
        calibration: GuideCalibration
    ) async {
        var cycleCount = 0

        var lastStarSnapshot = cameraViewModel.detectedStars

        while !Task.isCancelled && isGuiding {
            guard let refPos = referencePosition,
                  let searchPos = lastKnownStarPosition else { break }

            // Wait for fresh star detection before computing corrections.
            // This prevents sending multiple corrections from the same stale frame.
            let freshStars = await waitForFreshStars(cameraViewModel: cameraViewModel, previous: lastStarSnapshot)
            lastStarSnapshot = freshStars

            guard !Task.isCancelled && isGuiding else { break }

            cycleCount += 1

            // Read live parameters from published properties (UI updates these via binding)
            let raAggr = raAggressiveness / 100.0
            let decAggr = decAggressiveness / 100.0
            let raHyst = raHysteresis / 100.0
            let minMove = minMoveArcsec
            let pixScale = pixelScaleArcsecPerPix
            let currentDecMode = decMode

            // Find current guide star near its LAST KNOWN position (not the reference)
            guard let currentStar = findNearestStar(stars: freshStars, near: searchPos, radius: 30.0) else {
                statusMessage = "Guide star lost!"
                log("[Guide] LOST star near (\(String(format:"%.1f,%.1f", searchPos.x, searchPos.y)))")
                continue
            }

            let currentPos = CGPoint(x: currentStar.x, y: currentStar.y)

            // Update tracking positions
            lastKnownStarPosition = currentPos
            calibrator.guideStarPosition = currentPos

            // Compute pixel displacement from REFERENCE (lock) position
            let dx = Double(currentPos.x - refPos.x)
            let dy = Double(currentPos.y - refPos.y)

            // Convert pixel displacement to RA/Dec correction using calibration
            let corrections = calibration.pixelToGuideMs(dx: dx, dy: dy)

            // Convert pixel error to arcseconds for display
            let raErrorArcsec = dx * pixScale * cos(calibration.raAngle) +
                                dy * pixScale * sin(calibration.raAngle)
            let decErrorArcsec = dx * pixScale * cos(calibration.decAngle) +
                                 dy * pixScale * sin(calibration.decAngle)

            // Apply aggressiveness
            var raCorrMs = corrections.raMs * raAggr
            var decCorrMs = corrections.decMs * decAggr

            // RA hysteresis: blend with previous correction
            if raHyst > 0 {
                raCorrMs = raCorrMs * (1.0 - raHyst) + previousRaCorrectionMs * raHyst
            }
            previousRaCorrectionMs = raCorrMs

            // Min move threshold
            let raErrorAbs = abs(raErrorArcsec)
            let decErrorAbs = abs(decErrorArcsec)
            if raErrorAbs < minMove { raCorrMs = 0 }
            if decErrorAbs < minMove { decCorrMs = 0 }

            // Dec mode filtering
            switch currentDecMode {
            case "off": decCorrMs = 0
            case "north": if decCorrMs < 0 { decCorrMs = 0 }
            case "south": if decCorrMs > 0 { decCorrMs = 0 }
            default: break // "both"
            }

            // Clamp corrections
            let maxPulseMs = 1000.0

            // Send corrections using PulseGuide (ASCOM standard for guiding)
            // Directions: 0=North, 1=South, 2=East, 3=West
            if raCorrMs != 0 {
                let clampedMs = UInt32(min(abs(raCorrMs), maxPulseMs))
                let direction: UInt8 = raCorrMs > 0 ? 3 : 2  // positive correction = West, negative = East
                do {
                    try await calibrator.mountService.pulseGuide(direction: direction, durationMs: clampedMs)
                } catch {
                    statusMessage = "Mount error: \(error.localizedDescription)"
                }
            }

            if decCorrMs != 0 {
                let clampedMs = UInt32(min(abs(decCorrMs), maxPulseMs))
                let direction: UInt8 = decCorrMs > 0 ? 1 : 0  // positive correction = South, negative = North
                do {
                    try await calibrator.mountService.pulseGuide(direction: direction, durationMs: clampedMs)
                } catch {
                    statusMessage = "Mount error: \(error.localizedDescription)"
                }
            }

            // Record sample
            let sample = GuideSample(
                timestamp: .now,
                raErrorArcsec: raErrorArcsec,
                decErrorArcsec: decErrorArcsec,
                raCorrectionMs: raCorrMs,
                decCorrectionMs: decCorrMs
            )
            addSample(sample)

            statusMessage = String(format: "Guiding: RA %.2f\" Dec %.2f\"", raErrorArcsec, decErrorArcsec)

            // Debug log every cycle to diagnose
            log(String(format: "[Guide] dx=%.1f dy=%.1f err RA=%.2f\" Dec=%.2f\" corr RA=%.0fms Dec=%.0fms star=(%.1f,%.1f) ref=(%.1f,%.1f)",
                       dx, dy, raErrorArcsec, decErrorArcsec, raCorrMs, decCorrMs,
                       currentPos.x, currentPos.y, refPos.x, refPos.y))
        }
    }

    /// Send a timed pulse on one axis.
    private func sendPulse(calibrator: GuideCalibrator, axis: UInt8, rate: Double, durationMs: Double) async throws {
        if let handler = calibrator.moveAxisHandler {
            try await handler(axis, rate)
            try? await Task.sleep(nanoseconds: UInt64(durationMs) * 1_000_000)
            try await handler(axis, 0)
        } else {
            try await calibrator.mountService.moveAxis(axis, rateDegPerSec: rate)
            try? await Task.sleep(nanoseconds: UInt64(durationMs) * 1_000_000)
            try await calibrator.mountService.moveAxis(axis, rateDegPerSec: 0)
        }
    }

    /// Wait for star detection to produce a new frame (different from previous snapshot).
    private func waitForFreshStars(cameraViewModel: CameraViewModel, previous: [DetectedStar]) async -> [DetectedStar] {
        let startTime = ContinuousClock.now
        let timeout = Duration.seconds(30)

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 200_000_000) // poll every 200ms
            let current = cameraViewModel.detectedStars

            // Detect change: different count or different positions
            if current.count != previous.count {
                return current
            }
            if !current.isEmpty, !previous.isEmpty,
               current[0].x != previous[0].x || current[0].y != previous[0].y {
                return current
            }

            if ContinuousClock.now - startTime > timeout {
                return current
            }
        }
        return []
    }

    /// Find the nearest detected star to a position.
    private func findNearestStar(stars: [DetectedStar], near pos: CGPoint, radius: Double) -> DetectedStar? {
        var best: DetectedStar?
        var bestDist = Double.greatestFiniteMagnitude
        for star in stars {
            let dx = star.x - Double(pos.x)
            let dy = star.y - Double(pos.y)
            let dist = sqrt(dx * dx + dy * dy)
            if dist < radius && dist < bestDist {
                bestDist = dist
                best = star
            }
        }
        return best
    }

    private func log(_ msg: String) {
        debugLogger?.appendDebug(msg)
    }

    // MARK: - Sample Management

    /// Add a guide sample and update statistics.
    func addSample(_ sample: GuideSample) {
        samples.append(sample)

        // Trim old samples
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }

        updateStatistics()
    }

    /// Clear all samples and reset statistics.
    func reset() {
        samples = []
        raRMSArcsec = 0
        decRMSArcsec = 0
        totalRMSArcsec = 0
        raPeakArcsec = 0
        decPeakArcsec = 0
    }

    // MARK: - Statistics

    private func updateStatistics() {
        guard !samples.isEmpty else { return }

        var raSumSq: Double = 0
        var decSumSq: Double = 0
        var raPeak: Double = 0
        var decPeak: Double = 0

        for sample in samples {
            raSumSq += sample.raErrorArcsec * sample.raErrorArcsec
            decSumSq += sample.decErrorArcsec * sample.decErrorArcsec
            raPeak = max(raPeak, abs(sample.raErrorArcsec))
            decPeak = max(decPeak, abs(sample.decErrorArcsec))
        }

        let n = Double(samples.count)
        raRMSArcsec = sqrt(raSumSq / n)
        decRMSArcsec = sqrt(decSumSq / n)
        totalRMSArcsec = sqrt((raSumSq + decSumSq) / n)
        raPeakArcsec = raPeak
        decPeakArcsec = decPeak
    }
}
