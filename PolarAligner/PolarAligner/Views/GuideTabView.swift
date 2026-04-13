import SwiftUI

/// Guide camera tab with calibration, guiding controls, camera preview, and error graph.
///
/// Layout: HSplitView — left control panel (ScrollView + GroupBoxes), right content
/// (camera preview + guide graph).
struct GuideTabView: View {
    @ObservedObject var cameraViewModel: CameraViewModel
    @ObservedObject var calibrator: GuideCalibrator
    @ObservedObject var session: GuideSession
    @ObservedObject var mountService: MountService
    @ObservedObject var simulatedGuideEngine: SimulatedGuideEngine

    // Guide camera settings from @AppStorage
    @AppStorage("guideExposureMs") private var exposureMs: Double = 500
    @AppStorage("guideGain") private var guideGain: Double = 300
    @AppStorage("guideBinning") private var guideBinning: Int = 2
    @AppStorage("guideFocalLengthMM") private var guideFocalLengthMM: Double = 200.0
    @AppStorage("guidePixelSizeMicrons") private var guidePixelSizeMicrons: Double = 2.9

    // Guide parameters are stored on GuideSession (live binding).
    // Persist to @AppStorage for restore across launches.
    @AppStorage("guideRAAggressiveness") private var savedRAAggressiveness: Double = 70
    @AppStorage("guideDecAggressiveness") private var savedDecAggressiveness: Double = 70
    @AppStorage("guideMinMove") private var savedMinMove: Double = 0.2
    @AppStorage("guideRAHysteresis") private var savedRAHysteresis: Double = 10
    @AppStorage("guideDecMode") private var savedDecMode: String = "both"

    @State private var previewSize: CGSize = .zero
    @State private var mode: GuideMode = .real

    enum GuideMode: String, CaseIterable {
        case real = "Real"
        case simulate = "Simulate"
    }

    private var isSimulating: Bool { mode == .simulate }

    var body: some View {
        HSplitView {
            // Left panel: controls
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Header with mode picker
                    HStack {
                        Text("Guiding")
                            .font(.title)
                        Spacer()
                        Picker("Mode", selection: $mode) {
                            ForEach(GuideMode.allCases, id: \.self) { m in
                                Text(m.rawValue).tag(m)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }

                    statusGroupBox
                    Divider()
                    if isSimulating {
                        simulationGroupBox
                        Divider()
                    }
                    if !isSimulating {
                        cameraGroupBox
                        Divider()
                    }
                    calibrationGroupBox
                    Divider()
                    guideControlsGroupBox
                    Divider()
                    guideParametersGroupBox
                }
                .padding()
            }
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)

            // Right panel: preview + graph
            GuidePreviewPanel(
                cameraViewModel: cameraViewModel,
                calibrator: calibrator,
                session: session,
                simulatedGuideEngine: simulatedGuideEngine,
                previewSize: $previewSize,
                onStarTap: { selectStarAt(viewLocation: $0) }
            )
            .frame(minWidth: 400)
        }
        .onAppear {
            // Restore guide parameters from persistent storage
            session.raAggressiveness = savedRAAggressiveness
            session.decAggressiveness = savedDecAggressiveness
            session.raHysteresis = savedRAHysteresis
            session.minMoveArcsec = savedMinMove
            session.decMode = savedDecMode

            cameraViewModel.starDetectionEnabled = true
            // Start the guide camera live view if it isn't already running.
            // resumeLiveView() only fires when wasLiveBeforePause=true, so use
            // startLive directly to auto-start on every Guide tab visit.
            if cameraViewModel.isConnected && !cameraViewModel.isCapturing {
                let settings = CameraSettings(
                    exposureMs: exposureMs,
                    gain: Int(guideGain),
                    binning: guideBinning
                )
                cameraViewModel.startLive(settings: settings)
            }
        }
        .onDisappear {
            // Persist current guide parameters
            savedRAAggressiveness = session.raAggressiveness
            savedDecAggressiveness = session.decAggressiveness
            savedRAHysteresis = session.raHysteresis
            savedMinMove = session.minMoveArcsec
            savedDecMode = session.decMode

            // Only pause camera if guiding is not active — guiding must continue across tab switches
            if !session.isGuiding {
                cameraViewModel.starDetectionEnabled = false
                cameraViewModel.pauseLiveView()
            }
        }
        .onChange(of: mode) { _, newMode in
            if newMode == .real {
                simulatedGuideEngine.stop()
            }
        }
    }

    // MARK: - Simulation GroupBox

    private var simulationGroupBox: some View {
        GroupBox("Simulation") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if simulatedGuideEngine.isRunning {
                        Button {
                            simulatedGuideEngine.stop()
                        } label: {
                            Label("Stop Simulation", systemImage: "stop.fill")
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    } else {
                        Button {
                            simulatedGuideEngine.start(
                                cameraViewModel: cameraViewModel,
                                calibrator: calibrator,
                                viewSize: previewSize
                            )
                        } label: {
                            Label("Start Simulation", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                    }
                }

                if simulatedGuideEngine.isRunning {
                    simParameterSlider(label: "Seeing", value: $simulatedGuideEngine.seeingFWHM,
                                       range: 0.5...6.0, format: "%.1f\"")
                    simParameterSlider(label: "RA drift", value: $simulatedGuideEngine.raDriftArcsecPerSec,
                                       range: 0...3.0, format: "%.1f\"/s")
                    simParameterSlider(label: "Dec drift", value: $simulatedGuideEngine.decDriftArcsecPerSec,
                                       range: 0...1.0, format: "%.1f\"/s")
                    simParameterSlider(label: "PE amp", value: $simulatedGuideEngine.peAmplitudeArcsec,
                                       range: 0...20.0, format: "%.0f\"")
                    simParameterSlider(label: "Backlash", value: $simulatedGuideEngine.backlashArcsec,
                                       range: 0...10.0, format: "%.0f\"")
                    simParameterSlider(label: "Cam angle", value: $simulatedGuideEngine.cameraAngleDeg,
                                       range: 0...360, format: "%.0f°")
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func simParameterSlider(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: String
    ) -> some View {
        HStack {
            Text(label)
                .frame(width: 65, alignment: .trailing)
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: value, in: range)
                .frame(maxWidth: 120)
            Text(String(format: format, value.wrappedValue))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 45, alignment: .trailing)
        }
    }

    // MARK: - Status GroupBox

    private var statusGroupBox: some View {
        GroupBox("Status") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    stateBadge
                    if mountService.isConnected {
                        Text("Mount")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.2))
                            .foregroundStyle(.green)
                            .clipShape(Capsule())
                    } else {
                        Text("No Mount")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.red.opacity(0.2))
                            .foregroundStyle(.red)
                            .clipShape(Capsule())
                    }
                }

                if let pos = calibrator.guideStarPosition {
                    HStack {
                        Text("Star")
                            .frame(width: 35, alignment: .trailing)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Text(String(format: "(%.1f, %.1f)", pos.x, pos.y))
                            .font(.system(.caption, design: .monospaced))
                    }
                }

                if !session.samples.isEmpty {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("RA RMS").font(.caption2).foregroundStyle(.secondary)
                            Text(String(format: "%.2f\"", session.raRMSArcsec))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.blue)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Dec RMS").font(.caption2).foregroundStyle(.secondary)
                            Text(String(format: "%.2f\"", session.decRMSArcsec))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.red)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Total").font(.caption2).foregroundStyle(.secondary)
                            Text(String(format: "%.2f\"", session.totalRMSArcsec))
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Camera GroupBox

    private var cameraGroupBox: some View {
        GroupBox("Camera") {
            VStack(alignment: .leading, spacing: 8) {
                if !cameraViewModel.isConnected {
                    Text("Connect guide camera in Settings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    if cameraViewModel.isConnected {
                        if cameraViewModel.isCapturing {
                            Button("Stop") {
                                cameraViewModel.stopCapture()
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                        } else {
                            Button("Live") {
                                startLive()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }

                // Quick settings readout
                HStack(spacing: 8) {
                    Text(exposureMs >= 1000
                         ? String(format: "%.1fs", exposureMs / 1000)
                         : String(format: "%.0fms", exposureMs))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text(String(format: "G%.0f", guideGain))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text("\(guideBinning)x\(guideBinning)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }

                // Star detector selection
                HStack(spacing: 6) {
                    Picker("Detector", selection: $cameraViewModel.forceClassicalDetector) {
                        Text("Classical").tag(true)
                        Text("CoreML").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 180)

                    Image(systemName: cameraViewModel.forceClassicalDetector ? "cpu" : "brain")
                        .foregroundStyle(cameraViewModel.forceClassicalDetector ? .blue :
                                            (cameraViewModel.starDetectorModelLoaded ? .green : .orange))
                        .font(.caption)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Calibration GroupBox

    private var calibrationGroupBox: some View {
        GroupBox("Calibration") {
            VStack(alignment: .leading, spacing: 8) {
                if calibrator.isCalibrating {
                    HStack {
                        ProgressView(value: calibrator.progress)
                            .tint(.orange)
                        Button("Cancel") {
                            calibrator.cancel()
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .controlSize(.small)
                    }

                    Text(calibrator.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    HStack(spacing: 8) {
                        Button("Calibrate") {
                            cameraViewModel.starDetectionEnabled = true
                            calibrator.startCalibration()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canCalibrate)

                        if calibrator.calibration != nil {
                            Button("Clear") {
                                calibrator.calibration = nil
                                calibrator.guideStarPosition = nil
                                calibrator.stepPositions = []
                                calibrator.statusMessage = "Not calibrated"
                                GuideCalibration.clear()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    if !canCalibrate {
                        Text(isSimulating
                             ? "Start simulation first"
                             : "Requires live preview + mount connected")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                if let cal = calibrator.calibration {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("RA")
                                .frame(width: 25, alignment: .trailing)
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            Text(String(format: "%.1f°  %.4f px/ms",
                                        cal.raAngle * 180.0 / .pi, cal.raRate))
                                .font(.system(.caption, design: .monospaced))
                        }
                        HStack {
                            Text("Dec")
                                .frame(width: 25, alignment: .trailing)
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            Text(String(format: "%.1f°  %.4f px/ms",
                                        cal.decAngle * 180.0 / .pi, cal.decRate))
                                .font(.system(.caption, design: .monospaced))
                        }
                        HStack(spacing: 6) {
                            Text(cal.ageString)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            if !cal.isValid {
                                HStack(spacing: 2) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.yellow)
                                        .font(.system(size: 9))
                                    Text(String(format: "axes %.0f° apart", cal.axisOrthogonality))
                                        .foregroundStyle(.yellow)
                                }
                                .font(.caption2)
                            } else {
                                Text(String(format: "%.0f° ortho", cal.axisOrthogonality))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                } else if !calibrator.isCalibrating {
                    Text(calibrator.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Guide Controls GroupBox

    private var guideControlsGroupBox: some View {
        GroupBox("Guide Controls") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if session.isGuiding {
                        Button {
                            session.stopGuiding()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    } else {
                        Button {
                            cameraViewModel.starDetectionEnabled = true
                            // Pixel scale: from simulator or computed from guide optics settings
                            session.pixelScaleArcsecPerPix = simulatedGuideEngine.isRunning
                                ? simulatedGuideEngine.pixelScaleArcsecPerPix
                                : guidePixelSizeMicrons * 206.265 / guideFocalLengthMM * Double(guideBinning)
                            session.startGuiding(
                                calibrator: calibrator,
                                cameraViewModel: cameraViewModel
                            )
                        } label: {
                            Label("Guide", systemImage: "scope")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(calibrator.calibration == nil || !cameraViewModel.isCapturing)
                    }
                }

                if calibrator.calibration == nil && !calibrator.isCalibrating {
                    Text("Calibrate first before guiding")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Picker("Dec Mode", selection: $session.decMode) {
                    Text("Both").tag("both")
                    Text("North only").tag("north")
                    Text("South only").tag("south")
                    Text("Off").tag("off")
                }
                .pickerStyle(.segmented)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Guide Parameters GroupBox

    private var guideParametersGroupBox: some View {
        GroupBox("Parameters") {
            VStack(alignment: .leading, spacing: 8) {
                parameterSlider(label: "RA Aggr.", value: $session.raAggressiveness,
                                range: 0...100, format: "%.0f%%")
                parameterSlider(label: "Dec Aggr.", value: $session.decAggressiveness,
                                range: 0...100, format: "%.0f%%")
                parameterSlider(label: "RA Hyst.", value: $session.raHysteresis,
                                range: 0...100, format: "%.0f%%")

                HStack {
                    Text("Min Move")
                        .frame(width: 65, alignment: .trailing)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("", value: $session.minMoveArcsec, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                    Text("\"")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func parameterSlider(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: String
    ) -> some View {
        HStack {
            Text(label)
                .frame(width: 65, alignment: .trailing)
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: value, in: range)
                .frame(maxWidth: 120)
            Text(String(format: format, value.wrappedValue))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 40, alignment: .trailing)
        }
    }

    // MARK: - Simulated Star Field

    /// Renders detected stars as glowing dots on a black background.
    /// Uses TimelineView to force Canvas redraws at 10 Hz matching the simulation tick rate.
    private var simulatedStarFieldView: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            GeometryReader { geo in
                let scaleX = geo.size.width / CGFloat(max(cameraViewModel.captureWidth, 1))
                let scaleY = geo.size.height / CGFloat(max(cameraViewModel.captureHeight, 1))
                let stars = cameraViewModel.detectedStars

                Canvas { context, _ in
                    for star in stars {
                        let x = star.x * scaleX
                        let y = star.y * scaleY

                        // Star size based on brightness (brighter = larger)
                        let radius = max(2.0, min(8.0, star.brightness / 500.0))

                        // Glow halo
                        let haloRect = CGRect(
                            x: x - radius * 2, y: y - radius * 2,
                            width: radius * 4, height: radius * 4
                        )
                        context.fill(
                            Path(ellipseIn: haloRect),
                            with: .color(.white.opacity(0.15))
                        )

                        // Star core
                        let coreRect = CGRect(
                            x: x - radius, y: y - radius,
                            width: radius * 2, height: radius * 2
                        )
                        let opacity = min(1.0, star.brightness / 2000.0) * 0.7 + 0.3
                        context.fill(
                            Path(ellipseIn: coreRect),
                            with: .color(.white.opacity(opacity))
                        )

                        // Bright center
                        let centerSize = max(1.0, radius * 0.4)
                        let centerRect = CGRect(
                            x: x - centerSize, y: y - centerSize,
                            width: centerSize * 2, height: centerSize * 2
                        )
                        context.fill(
                            Path(ellipseIn: centerRect),
                            with: .color(.white)
                        )
                    }
                }
            }
        }
    }

    // MARK: - Overlays

    /// Convert image pixel coordinates to view points using the published imageRect.
    private func imageToView(pixelX: CGFloat, pixelY: CGFloat) -> CGPoint {
        let rect = cameraViewModel.previewViewModel.imageRect
        let capW = CGFloat(max(cameraViewModel.captureWidth, 1))
        let capH = CGFloat(max(cameraViewModel.captureHeight, 1))
        let x = rect.origin.x + pixelX * rect.width / capW
        let y = rect.origin.y + pixelY * rect.height / capH
        return CGPoint(x: x, y: y)
    }

    private var imageScaleX: CGFloat {
        let rect = cameraViewModel.previewViewModel.imageRect
        return rect.width / CGFloat(max(cameraViewModel.captureWidth, 1))
    }

    private func guideStarOverlay(at pos: CGPoint) -> some View {
        let pt = imageToView(pixelX: pos.x, pixelY: pos.y)
        return ZStack {
            // Crosshair
            Path { path in
                path.move(to: CGPoint(x: pt.x - 15, y: pt.y))
                path.addLine(to: CGPoint(x: pt.x - 5, y: pt.y))
                path.move(to: CGPoint(x: pt.x + 5, y: pt.y))
                path.addLine(to: CGPoint(x: pt.x + 15, y: pt.y))
                path.move(to: CGPoint(x: pt.x, y: pt.y - 15))
                path.addLine(to: CGPoint(x: pt.x, y: pt.y - 5))
                path.move(to: CGPoint(x: pt.x, y: pt.y + 5))
                path.addLine(to: CGPoint(x: pt.x, y: pt.y + 15))
            }
            .stroke(Color.green, lineWidth: 1.5)

            // Circle
            Circle()
                .stroke(Color.green, lineWidth: 1)
                .frame(width: 20, height: 20)
                .position(x: pt.x, y: pt.y)
        }
    }

    /// Overlay circles on each detected star for visual debugging.
    private var detectedStarsOverlay: some View {
        let scale = imageScaleX
        let stars = cameraViewModel.detectedStars.prefix(50)
        return Canvas { context, size in
            for star in stars {
                let pt = imageToView(pixelX: CGFloat(star.x), pixelY: CGFloat(star.y))
                let radius = max(CGFloat(star.fwhm) * scale * 2, 4)
                let rect = CGRect(x: pt.x - radius / 2, y: pt.y - radius / 2,
                                  width: radius, height: radius)
                context.stroke(Path(ellipseIn: rect),
                               with: .color(.cyan.opacity(0.7)), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }

    private var calibrationTrailOverlay: some View {
        Path { path in
            for (i, pos) in calibrator.stepPositions.enumerated() {
                let pt = imageToView(pixelX: pos.x, pixelY: pos.y)
                if i == 0 {
                    path.move(to: pt)
                } else {
                    path.addLine(to: pt)
                }
            }
        }
        .stroke(Color.yellow, lineWidth: 1)
    }

    // MARK: - Debug Log Strip

    private var debugLogStrip: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Debug Log")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(cameraViewModel.debugLog, forType: .string)
                }
                .font(.caption2)
                .buttonStyle(.borderless)
                Button("Clear") {
                    cameraViewModel.debugLog = ""
                }
                .font(.caption2)
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)

            ScrollView {
                Text(cameraViewModel.debugLog)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .textSelection(.enabled)
            }
            .frame(height: 80)
            .background(.black.opacity(0.8))
        }
    }

    // MARK: - Helpers

    /// Find the current position of the guide star by matching nearest detected star.
    /// This makes the crosshair follow the star as it drifts.
    /// Updates the anchor so subsequent matches search near the last known position,
    /// preventing jumps to a different star when detections are noisy.
    private var trackedGuideStarPosition: CGPoint? {
        guard let anchor = calibrator.guideStarPosition else { return nil }
        let stars = cameraViewModel.detectedStars
        guard !stars.isEmpty else { return anchor }

        var bestDist = Double.greatestFiniteMagnitude
        var bestStar: DetectedStar?
        for star in stars {
            let dx = star.x - Double(anchor.x)
            let dy = star.y - Double(anchor.y)
            let dist = sqrt(dx * dx + dy * dy)
            if dist < bestDist {
                bestDist = dist
                bestStar = star
            }
        }

        // Only follow the star if it's within a tight radius (20 pixels).
        // This prevents jumping to a distant star if our star is temporarily
        // not detected in one frame.
        if let star = bestStar, bestDist < 20.0 {
            let pos = CGPoint(x: star.x, y: star.y)
            // Don't overwrite during calibration — calibrator manages its own position
            if !calibrator.isCalibrating {
                calibrator.guideStarPosition = pos
            }
            return pos
        }
        // Star not found nearby — keep showing the last known position
        return anchor
    }

    /// Select the nearest star to a click location in the preview area.
    private func selectStarAt(viewLocation: CGPoint) {
        guard cameraViewModel.isConnected,
              cameraViewModel.captureWidth > 0,
              cameraViewModel.captureHeight > 0 else { return }
        guard !calibrator.isCalibrating else { return }

        let stars = cameraViewModel.detectedStars
        guard !stars.isEmpty else { return }

        // Convert view tap location to image pixel coordinates using imageRect
        var rect = cameraViewModel.previewViewModel.imageRect
        // Fallback to previewSize if imageRect not yet set (e.g. simulation)
        if rect.width <= 0 || rect.height <= 0 {
            rect = CGRect(origin: .zero, size: previewSize)
        }
        guard rect.width > 0, rect.height > 0 else { return }
        let capW = Double(cameraViewModel.captureWidth)
        let capH = Double(cameraViewModel.captureHeight)
        let imageX = (viewLocation.x - rect.origin.x) * capW / rect.width
        let imageY = (viewLocation.y - rect.origin.y) * capH / rect.height

        // Find nearest star to tap in image coordinates
        var bestStar: DetectedStar?
        var bestDist = Double.greatestFiniteMagnitude
        for star in stars {
            let dx = star.x - imageX
            let dy = star.y - imageY
            let dist = sqrt(dx * dx + dy * dy)
            if dist < bestDist {
                bestDist = dist
                bestStar = star
            }
        }

        // Snap to star if within reasonable radius (50 pixels in image space)
        if let star = bestStar, bestDist < 80.0 {
            let pos = CGPoint(x: star.x, y: star.y)
            calibrator.guideStarPosition = pos
            calibrator.stepPositions = [pos]
            calibrator.statusMessage = String(format: "Guide star at (%.1f, %.1f) SNR=%.1f", star.x, star.y, star.snr)
        }
    }

    private var canCalibrate: Bool {
        if isSimulating {
            return simulatedGuideEngine.isRunning && cameraViewModel.isCapturing
        }
        return cameraViewModel.isCapturing && mountService.isConnected
    }

    private func startLive() {
        let settings = CameraSettings(
            exposureMs: exposureMs,
            gain: Int(guideGain),
            binning: guideBinning
        )
        cameraViewModel.starDetectionEnabled = true
        cameraViewModel.startLive(settings: settings)
    }

    private var stateBadge: some View {
        let (text, color) = stateInfo
        return Text(text)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var stateInfo: (String, Color) {
        if session.isGuiding { return ("Guiding", .green) }
        if calibrator.isCalibrating { return ("Calibrating", .orange) }
        if simulatedGuideEngine.isRunning { return ("Simulated", .purple) }
        if cameraViewModel.isCapturing { return ("Live", .yellow) }
        if cameraViewModel.isConnected { return ("Connected", .blue) }
        return ("Idle", .gray)
    }

    private var statusColor: Color {
        stateInfo.1
    }

    private var statusText: String {
        if calibrator.isCalibrating { return calibrator.statusMessage }
        if session.isGuiding { return session.statusMessage }
        return cameraViewModel.statusMessage
    }
}

// MARK: - Guide Preview Panel (isolated from left panel to prevent layout storms)

/// Separate view that owns the high-frequency `@ObservedObject` references
/// (cameraViewModel, simulatedGuideEngine). This prevents the parent GuideTabView
/// from re-evaluating its body (and expensive segmented picker) at 10Hz.
private struct GuidePreviewPanel: View {
    @ObservedObject var cameraViewModel: CameraViewModel
    @ObservedObject var calibrator: GuideCalibrator
    @ObservedObject var session: GuideSession
    @ObservedObject var simulatedGuideEngine: SimulatedGuideEngine
    @Binding var previewSize: CGSize
    var onStarTap: (CGPoint) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Camera preview
            ZStack {
                Color.black

                if cameraViewModel.isConnected {
                    CameraPreviewView(viewModel: cameraViewModel.previewViewModel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "camera")
                            .font(.system(size: 48))
                            .foregroundStyle(.tertiary)
                        Text("Connect guide camera to start")
                            .foregroundStyle(.secondary)
                    }
                }

                // Guide star crosshair overlay
                // During calibration, use calibrator's position directly (it manages its own tracking)
                let displayStarPos = calibrator.isCalibrating ? calibrator.guideStarPosition : trackedGuideStarPosition
                if let pos = displayStarPos, cameraViewModel.isConnected {
                    guideStarOverlay(at: pos)
                }

                // Detected star circles overlay
                if cameraViewModel.isConnected && !cameraViewModel.detectedStars.isEmpty {
                    detectedStarsOverlay
                }

                // Calibration trail overlay
                if calibrator.isCalibrating && calibrator.stepPositions.count > 1 {
                    calibrationTrailOverlay
                }

                // Top overlay: star count + fps
                VStack {
                    HStack {
                        if simulatedGuideEngine.isRunning || (cameraViewModel.isCapturing && cameraViewModel.starDetectionEnabled) {
                            HStack(spacing: 6) {
                                Image(systemName: "star.fill")
                                    .foregroundStyle(.yellow)
                                    .font(.caption2)
                                Text("\(cameraViewModel.detectedStars.count) stars")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.yellow)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        }

                        Spacer()

                        if simulatedGuideEngine.isRunning {
                            Text("10.0 Hz sim")
                                .font(.system(.caption, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.black.opacity(0.6))
                                .foregroundStyle(.purple)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        } else if cameraViewModel.isCapturing {
                            FrameRateView(previewViewModel: cameraViewModel.previewViewModel)
                        }
                    }
                    Spacer()
                }
                .padding(8)
            }
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { previewSize = geo.size }
                        .onChange(of: geo.size) { _, newSize in previewSize = newSize }
                }
            )
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture()
                    .onEnded { value in
                        onStarTap(value.location)
                    }
            )

            Divider()

            // Guide graph
            GuideGraphView(session: session)
                .frame(height: 150)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

            Divider()

            // Debug log strip
            if !cameraViewModel.debugLog.isEmpty {
                debugLogStrip
            }

            Divider()

            // Bottom status bar
            HStack(spacing: 12) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                if cameraViewModel.captureWidth > 0 && cameraViewModel.isConnected {
                    Text("\(cameraViewModel.captureWidth)x\(cameraViewModel.captureHeight)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    // MARK: - Overlays

    private func imageToView(pixelX: CGFloat, pixelY: CGFloat) -> CGPoint {
        var rect = cameraViewModel.previewViewModel.imageRect
        if rect.width <= 0 || rect.height <= 0 {
            rect = CGRect(origin: .zero, size: previewSize)
        }
        let capW = CGFloat(max(cameraViewModel.captureWidth, 1))
        let capH = CGFloat(max(cameraViewModel.captureHeight, 1))
        let x = rect.origin.x + pixelX * rect.width / capW
        let y = rect.origin.y + pixelY * rect.height / capH
        return CGPoint(x: x, y: y)
    }

    private var imageScaleX: CGFloat {
        let rect = cameraViewModel.previewViewModel.imageRect
        return rect.width / CGFloat(max(cameraViewModel.captureWidth, 1))
    }

    private var trackedGuideStarPosition: CGPoint? {
        guard let anchor = calibrator.guideStarPosition else { return nil }
        let stars = cameraViewModel.detectedStars
        guard !stars.isEmpty else { return anchor }

        var bestDist = Double.greatestFiniteMagnitude
        var bestStar: DetectedStar?
        for star in stars {
            let dx = star.x - Double(anchor.x)
            let dy = star.y - Double(anchor.y)
            let dist = sqrt(dx * dx + dy * dy)
            if dist < bestDist {
                bestDist = dist
                bestStar = star
            }
        }

        if let star = bestStar, bestDist < 80.0 {
            let newPos = CGPoint(x: star.x, y: star.y)
            // Don't overwrite during calibration — calibrator manages its own position
            if !calibrator.isCalibrating {
                DispatchQueue.main.async {
                    self.calibrator.guideStarPosition = newPos
                }
            }
            return newPos
        }
        return anchor
    }

    private func guideStarOverlay(at pos: CGPoint) -> some View {
        let pt = imageToView(pixelX: pos.x, pixelY: pos.y)
        return ZStack {
            Path { path in
                path.move(to: CGPoint(x: pt.x - 15, y: pt.y))
                path.addLine(to: CGPoint(x: pt.x - 5, y: pt.y))
                path.move(to: CGPoint(x: pt.x + 5, y: pt.y))
                path.addLine(to: CGPoint(x: pt.x + 15, y: pt.y))
                path.move(to: CGPoint(x: pt.x, y: pt.y - 15))
                path.addLine(to: CGPoint(x: pt.x, y: pt.y - 5))
                path.move(to: CGPoint(x: pt.x, y: pt.y + 5))
                path.addLine(to: CGPoint(x: pt.x, y: pt.y + 15))
            }
            .stroke(Color.green, lineWidth: 1.5)

            Circle()
                .stroke(Color.green, lineWidth: 1)
                .frame(width: 20, height: 20)
                .position(x: pt.x, y: pt.y)
        }
    }

    private var detectedStarsOverlay: some View {
        let scale = imageScaleX
        let stars = cameraViewModel.detectedStars.prefix(50)
        return Canvas { context, size in
            for star in stars {
                let pt = imageToView(pixelX: CGFloat(star.x), pixelY: CGFloat(star.y))
                let radius = max(CGFloat(star.fwhm) * scale * 2, 4)
                let rect = CGRect(x: pt.x - radius / 2, y: pt.y - radius / 2,
                                  width: radius, height: radius)
                context.stroke(Path(ellipseIn: rect),
                               with: .color(.cyan.opacity(0.7)), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }

    private var calibrationTrailOverlay: some View {
        Path { path in
            for (i, pos) in calibrator.stepPositions.enumerated() {
                let pt = imageToView(pixelX: pos.x, pixelY: pos.y)
                if i == 0 {
                    path.move(to: pt)
                } else {
                    path.addLine(to: pt)
                }
            }
        }
        .stroke(Color.yellow, lineWidth: 1)
    }

    private var debugLogStrip: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Debug Log")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(cameraViewModel.debugLog, forType: .string)
                }
                .font(.caption2)
                .buttonStyle(.borderless)
                Button("Clear") {
                    cameraViewModel.debugLog = ""
                }
                .font(.caption2)
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)

            ScrollView(.vertical) {
                Text(cameraViewModel.debugLog)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .textSelection(.enabled)
            }
            .frame(height: 80)
            .background(.black.opacity(0.8))
        }
    }

    private var stateInfo: (String, Color) {
        if calibrator.isCalibrating { return ("Calibrating", .orange) }
        if session.isGuiding { return ("Guiding", .green) }
        if simulatedGuideEngine.isRunning { return ("Simulating", .purple) }
        if cameraViewModel.isCapturing { return ("Live", .yellow) }
        if cameraViewModel.isConnected { return ("Connected", .blue) }
        return ("Idle", .gray)
    }

    private var statusColor: Color { stateInfo.1 }

    private var statusText: String {
        if calibrator.isCalibrating { return calibrator.statusMessage }
        if session.isGuiding { return session.statusMessage }
        return cameraViewModel.statusMessage
    }
}
