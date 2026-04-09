import Foundation

/// Executor for `capture_frames` — captures a series of exposures and saves them,
/// with optional dithering between frames via the guide session.
struct CaptureFramesExecutor: InstructionExecutor {
    let instructionType = "capture_frames"

    func execute(instruction: SequenceInstruction, context: ExecutionContext) async throws {
        guard let camera = context.deviceResolver.camera() else {
            throw ExecutorError.deviceNotAvailable("imaging_camera")
        }

        let exposureSec = instruction.params["exposure_sec"]?.doubleValue ?? 60.0
        let count = instruction.params["count"]?.intValue ?? 1
        let gain = instruction.params["gain"]?.intValue
        let binning = instruction.params["binning"]?.intValue
        let frameType = instruction.params["frame_type"]?.stringValue ?? "light"
        let saveFolder = instruction.params["save_folder"]?.stringValue ?? ""

        // Dither: on/off toggle + move size in pixels
        let ditherEnabled = instruction.params["dither_enabled"]?.boolValue ?? false
        let ditherPixels = instruction.params["dither_pixels"]?.doubleValue ?? 5.0
        let ditherEveryN = instruction.params["dither_every_n"]?.intValue ?? 1
        let ditherSettleSec = instruction.params["dither_settle_sec"]?.doubleValue ?? 10.0

        let guide = context.deviceResolver.guide()

        // Resolve save folder: instruction override → Settings default → Pictures
        let folderURL: URL
        if !saveFolder.isEmpty {
            folderURL = URL(fileURLWithPath: saveFolder)
        } else {
            let settingsFolder = UserDefaults.standard.string(forKey: "captureFolder") ?? ""
            if !settingsFolder.isEmpty {
                folderURL = URL(fileURLWithPath: settingsFolder)
            } else {
                folderURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!
                    .appendingPathComponent("PolarStation")
            }
        }

        // Build camera settings: instruction params override Settings tab values.
        // Unspecified params fall back to the current Settings tab values (UserDefaults).
        let baseGain = Int(UserDefaults.standard.double(forKey: "gain").rounded())
        let baseGainResolved = baseGain > 0 ? baseGain : 300
        let baseBinning = UserDefaults.standard.integer(forKey: "binning")
        let baseBinningResolved = baseBinning > 0 ? baseBinning : 1

        let finalGain = gain ?? baseGainResolved
        let finalBinning = binning ?? baseBinningResolved
        let finalExposureMs = exposureSec * 1000

        var settings = CameraSettings()
        settings.exposureMs = finalExposureMs
        settings.gain = finalGain
        settings.binning = finalBinning

        // Push resolved settings back so Camera tab reflects what the sequencer is using
        await MainActor.run {
            UserDefaults.standard.set(finalExposureMs, forKey: "exposureMs")
            UserDefaults.standard.set(Double(finalGain), forKey: "gain")
            UserDefaults.standard.set(finalBinning, forKey: "binning")
        }

        // Resolve capture format from Settings
        let formatRaw = UserDefaults.standard.string(forKey: "captureFormat") ?? "fits"
        let format: CaptureFormat = formatRaw == "tiff" ? .tiff : .fits

        let colorModeRaw = UserDefaults.standard.string(forKey: "captureColorMode") ?? "rgb"
        let colorMode: CaptureColorMode = colorModeRaw == "luminance" ? .luminance : .rgb

        let ditherLabel = ditherEnabled ? " +dither" : ""
        context.status("Capturing \(count)x \(Int(exposureSec))s \(frameType)\(ditherLabel) → \(folderURL.lastPathComponent)/")

        // Start the capture sequence on the camera
        camera.startCaptureSequence(
            count: count,
            settings: settings,
            format: format,
            colorMode: colorMode,
            folder: folderURL,
            prefix: frameType
        )

        // Poll until all frames are captured or capture stops
        var lastReportedCount = 0
        let timeoutPerFrame = exposureSec + 30  // generous timeout per frame
        let deadline = Date().addingTimeInterval(timeoutPerFrame * Double(count))

        while Date() < deadline {
            try Task.checkCancellation()

            let captured = camera.capturedCount

            // Update status when frame count changes
            if captured != lastReportedCount {
                context.status("Captured \(captured)/\(count) (\(Int(exposureSec))s \(frameType))")
                lastReportedCount = captured

                // Dither after every N frames (if enabled and still capturing)
                if ditherEnabled, captured > 0, captured % ditherEveryN == 0, captured < count {
                    if let guide, guide.isGuiding {
                        context.status("Dithering after frame \(captured)...")
                        guide.dither(pixels: ditherPixels)
                        // Wait for guide to settle at new position
                        try await Task.sleep(for: .seconds(ditherSettleSec))
                        context.status("Dither settled, continuing capture")
                    }
                }
            }

            // Done when all frames captured
            if captured >= count {
                break
            }

            // Also check if camera stopped unexpectedly
            if !camera.isSaving && captured < count && captured > 0 {
                context.status("Camera stopped after \(captured)/\(count) frames")
                break
            }

            try await Task.sleep(for: .seconds(1))
        }

        let finalCount = camera.capturedCount
        if finalCount >= count {
            context.status("Capture complete: \(finalCount) \(frameType) frames saved")
        } else {
            context.status("Capture ended: \(finalCount)/\(count) frames saved")
        }
    }
}
