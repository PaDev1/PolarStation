import Foundation

/// Executor for `autofocus` — V-curve autofocus using focuser + camera star detection.
///
/// Algorithm:
/// 1. Move focuser through a range of positions (V-curve sweep)
/// 2. At each position, capture a frame and measure average HFR from detected stars
/// 3. Fit a parabola to the HFR-vs-position data points
/// 4. Move focuser to the computed minimum (best focus)
///
/// Parameters:
///   - step_size: focuser steps between sample points (default 100)
///   - num_steps: total number of sample positions (default 9, must be odd)
///   - exposure_sec: exposure time per sample frame (default 3)
///   - backlash_steps: overshoot for backlash compensation (default 200)
///   - settle_sec: wait after focuser move before capture (default 2)
///   - min_stars: minimum stars required for a valid measurement (default 4)
struct AutoFocusExecutor: InstructionExecutor {
    let instructionType = "autofocus"

    func execute(instruction: SequenceInstruction, context: ExecutionContext) async throws {
        guard let focuser = context.deviceResolver.focuser() else {
            throw ExecutorError.deviceNotAvailable("focuser")
        }
        guard let camera = context.deviceResolver.camera() else {
            throw ExecutorError.deviceNotAvailable("imaging_camera")
        }
        guard focuser.isConnected else {
            throw ExecutorError.deviceNotAvailable("focuser (not connected)")
        }

        let stepSize = instruction.params["step_size"]?.intValue ?? 100
        let numSteps = max(3, instruction.params["num_steps"]?.intValue ?? 9)
        let exposureSec = instruction.params["exposure_sec"]?.doubleValue ?? 3.0
        let backlashSteps = instruction.params["backlash_steps"]?.intValue ?? 200
        let settleSec = instruction.params["settle_sec"]?.doubleValue ?? 2.0
        let minStars = instruction.params["min_stars"]?.intValue ?? 4

        let startPosition = focuser.position
        let halfRange = Int32(stepSize * (numSteps / 2))
        let firstPosition = startPosition - halfRange

        context.status("Autofocus: \(numSteps) points, step=\(stepSize), range \(firstPosition)...\(startPosition + halfRange)")

        // Ensure star detection is on
        let wasDetectionEnabled = camera.starDetectionEnabled
        camera.starDetectionEnabled = true

        // Ensure camera is capturing (live mode for star detection)
        let wasCameraCapturing = camera.isCapturing
        if !wasCameraCapturing {
            let settings = CameraSettings(
                exposureMs: exposureSec * 1000,
                gain: Int(UserDefaults.standard.double(forKey: "gain")),
                binning: UserDefaults.standard.integer(forKey: "binning")
            )
            camera.startLive(settings: settings)
            try await Task.sleep(for: .seconds(exposureSec + 1))
        }

        // Move to start with backlash compensation (overshoot then come back)
        let overshootPos = max(0, firstPosition - Int32(backlashSteps))
        context.status("Autofocus: backlash compensation...")
        try await moveFocuserAndWait(focuser: focuser, position: overshootPos, timeout: 60)
        try await Task.sleep(for: .seconds(1))
        try await moveFocuserAndWait(focuser: focuser, position: firstPosition, timeout: 60)
        try await Task.sleep(for: .seconds(settleSec))

        // Collect HFR measurements at each position
        var dataPoints: [(position: Int32, hfr: Double)] = []

        for step in 0..<numSteps {
            try Task.checkCancellation()

            let targetPos = firstPosition + Int32(step * stepSize)
            context.status("Autofocus: step \(step + 1)/\(numSteps), position \(targetPos)")

            if step > 0 {
                try await moveFocuserAndWait(focuser: focuser, position: targetPos, timeout: 60)
                try await Task.sleep(for: .seconds(settleSec))
            }

            // Wait for a fresh frame with star detection
            let framesBefore = camera.previewViewModel.frameCount
            let frameDeadline = Date().addingTimeInterval(exposureSec * 3 + 5)
            while Date() < frameDeadline {
                try Task.checkCancellation()
                try await Task.sleep(for: .seconds(0.5))
                if camera.previewViewModel.frameCount > framesBefore {
                    // Give star detection time to run
                    try await Task.sleep(for: .seconds(0.5))
                    break
                }
            }

            let stars = camera.detectedStars
            if stars.count < minStars {
                context.status("Autofocus: step \(step + 1) — only \(stars.count) stars (need \(minStars)), skipping")
                continue
            }

            // Calculate average HFR from detected stars
            let hfr = computeAverageHFR(stars: stars)
            dataPoints.append((position: targetPos, hfr: hfr))
            context.status("Autofocus: pos=\(targetPos) HFR=\(String(format: "%.2f", hfr)) (\(stars.count) stars)")
        }

        // Need at least 3 valid data points to fit a curve
        guard dataPoints.count >= 3 else {
            // Return to original position
            try await moveFocuserAndWait(focuser: focuser, position: startPosition, timeout: 60)
            camera.starDetectionEnabled = wasDetectionEnabled
            context.status("Autofocus failed: only \(dataPoints.count) valid measurements (need 3+)")
            return
        }

        // Fit parabola: HFR = a*(pos-h)^2 + k, find minimum h
        let bestPosition = fitParabolaMinimum(dataPoints: dataPoints)

        // Clamp to focuser range
        let clampedPosition = max(0, min(focuser.maxStep, bestPosition))

        context.status("Autofocus: best position = \(clampedPosition), moving...")

        // Move to best position with backlash compensation
        let finalOvershoot = max(0, clampedPosition - Int32(backlashSteps))
        try await moveFocuserAndWait(focuser: focuser, position: finalOvershoot, timeout: 60)
        try await Task.sleep(for: .seconds(1))
        try await moveFocuserAndWait(focuser: focuser, position: clampedPosition, timeout: 60)
        try await Task.sleep(for: .seconds(settleSec))

        // Take a verification frame
        let verifyFrames = camera.previewViewModel.frameCount
        let verifyDeadline = Date().addingTimeInterval(exposureSec * 3 + 5)
        while Date() < verifyDeadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(0.5))
            if camera.previewViewModel.frameCount > verifyFrames {
                try await Task.sleep(for: .seconds(0.5))
                break
            }
        }

        let finalStars = camera.detectedStars
        let finalHFR = finalStars.isEmpty ? 0 : computeAverageHFR(stars: finalStars)

        // Restore star detection state
        camera.starDetectionEnabled = wasDetectionEnabled

        let dataPointsSummary = dataPoints.map { "(\($0.position), \(String(format: "%.2f", $0.hfr)))" }.joined(separator: " ")
        context.status("Autofocus complete: position=\(clampedPosition) HFR=\(String(format: "%.2f", finalHFR)) [\(dataPointsSummary)]")
    }

    // MARK: - HFR Calculation

    /// Compute Half Flux Radius from star FWHM values.
    /// HFR ≈ FWHM / 2 for Gaussian profiles. We use the median of the top 80%
    /// brightest stars to reject outliers.
    private func computeAverageHFR(stars: [DetectedStar]) -> Double {
        guard !stars.isEmpty else { return 0 }

        // Use top 80% by brightness, sorted by FWHM
        let sorted = stars.sorted { $0.brightness > $1.brightness }
        let useCount = max(1, Int(Double(sorted.count) * 0.8))
        let subset = Array(sorted.prefix(useCount))

        // Use FWHM directly as the focus metric (larger = more out of focus)
        // If FWHM is not computed (0), fall back to brightness-weighted estimate
        let fwhmValues = subset.compactMap { star -> Double? in
            star.fwhm > 0 ? star.fwhm : nil
        }

        if fwhmValues.count >= 2 {
            // Use median FWHM (robust to outliers)
            let sortedFWHM = fwhmValues.sorted()
            let mid = sortedFWHM.count / 2
            return sortedFWHM.count % 2 == 0
                ? (sortedFWHM[mid - 1] + sortedFWHM[mid]) / 2.0
                : sortedFWHM[mid]
        }

        // Fallback: use mean brightness as inverse proxy (brighter = tighter focus)
        // Return negative brightness so that "minimum" means "best focus"
        let avgBrightness = subset.reduce(0.0) { $0 + $1.brightness } / Double(subset.count)
        return 1.0 / max(avgBrightness, 0.001)
    }

    // MARK: - Parabola Fitting

    /// Fit a parabola y = a*x^2 + b*x + c to the data points using least squares.
    /// Returns the x position of the minimum (vertex: x = -b / 2a).
    private func fitParabolaMinimum(dataPoints: [(position: Int32, hfr: Double)]) -> Int32 {
        let n = Double(dataPoints.count)

        // Least squares for y = a*x^2 + b*x + c
        // Normal equations:
        //   [Σx^4  Σx^3  Σx^2] [a]   [Σx^2*y]
        //   [Σx^3  Σx^2  Σx  ] [b] = [Σx*y  ]
        //   [Σx^2  Σx    n   ] [c]   [Σy    ]

        var sx = 0.0, sx2 = 0.0, sx3 = 0.0, sx4 = 0.0
        var sy = 0.0, sxy = 0.0, sx2y = 0.0

        for dp in dataPoints {
            let x = Double(dp.position)
            let y = dp.hfr
            let x2 = x * x
            sx += x
            sx2 += x2
            sx3 += x2 * x
            sx4 += x2 * x2
            sy += y
            sxy += x * y
            sx2y += x2 * y
        }

        // Solve 3x3 system using Cramer's rule
        let det = sx4 * (sx2 * n - sx * sx)
                - sx3 * (sx3 * n - sx * sx2)
                + sx2 * (sx3 * sx - sx2 * sx2)

        guard abs(det) > 1e-10 else {
            // Degenerate — just return position with minimum HFR
            return dataPoints.min(by: { $0.hfr < $1.hfr })?.position ?? 0
        }

        let detA = sx2y * (sx2 * n - sx * sx)
                 - sx3 * (sxy * n - sx * sy)
                 + sx2 * (sxy * sx - sx2 * sy)

        let detB = sx4 * (sxy * n - sx * sy)
                 - sx2y * (sx3 * n - sx * sx2)
                 + sx2 * (sx3 * sy - sxy * sx2)

        let a = detA / det
        let b = detB / det

        // For a parabola y = ax^2 + bx + c, the vertex is at x = -b/(2a)
        // Only valid if a > 0 (concave up — V-curve has minimum)
        guard a > 1e-15 else {
            // Curve is flat or concave down — just return position with minimum HFR
            return dataPoints.min(by: { $0.hfr < $1.hfr })?.position ?? 0
        }

        let vertex = -b / (2.0 * a)
        return Int32(vertex.rounded())
    }

    // MARK: - Focuser Movement

    private func moveFocuserAndWait(focuser: FocuserViewModel, position: Int32, timeout: TimeInterval) async throws {
        focuser.moveTo(position: position)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(1))
            focuser.refreshStatus()
            try await Task.sleep(for: .seconds(0.5))
            if !focuser.isMoving { return }
        }
    }
}
