import SwiftUI
import PolarCore

/// Unified polar alignment view combining real alignment, simulation, and adjustment.
///
/// Phases:
/// 1. Setup — prerequisites check, mode selection (Real/Simulate)
/// 2. Measure — 3-point capture workflow
/// 3. Correct — bullseye adjustment with real-time error tracking
/// 4. Verify — re-measure to confirm correction
struct PolarAlignmentView: View {
    @ObservedObject var coordinator: AlignmentCoordinator
    @ObservedObject var cameraViewModel: CameraViewModel
    @ObservedObject var engine: SimulatedAlignmentEngine
    @ObservedObject var plateSolveService: PlateSolveService
    @ObservedObject var errorTracker: ErrorTracker

    @State private var mode: AlignmentMode = .real
    @StateObject private var skyMapVM = SkyMapViewModel()
    @AppStorage("exposureMs") private var exposureMs: Double = 500
    @AppStorage("gain") private var gain: Double = 300
    @AppStorage("binning") private var binning: Int = 2

    enum AlignmentMode: String, CaseIterable {
        case real = "Real"
        case simulate = "Simulate"
    }

    /// Whether we're in the correction phase (alignment complete, adjusting mount).
    private var isCorrectingPhase: Bool {
        if mode == .real {
            return coordinator.step == .complete || coordinator.step == .correcting
        }
        if mode == .simulate { return engine.currentStep == 4 }
        return false
    }

    /// The display error for the bullseye.
    /// Real mode: correction loop error (live). Simulate mode: correction loop or computed error.
    private var displayError: PolarError? {
        if mode == .real {
            return coordinator.correctionError ?? coordinator.polarError
        }
        if mode == .simulate { return engine.correctionError ?? engine.computedError }
        return nil
    }

    var body: some View {
        HSplitView {
            // Left panel: controls
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Header with mode picker
                    HStack {
                        Text("Polar Alignment")
                            .font(.title)
                        Spacer()
                        Picker("Mode", selection: $mode) {
                            ForEach(AlignmentMode.allCases, id: \.self) { m in
                                Text(m.rawValue).tag(m)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }

                    if mode == .real {
                        realModeContent
                    } else {
                        simulateModeContent
                    }

                    // Correction phase — shown after either mode completes
                    if isCorrectingPhase {
                        Divider()
                        correctionSection
                    }

                    Spacer()
                }
                .padding()
            }
            .frame(minWidth: 320, idealWidth: 400, maxWidth: 440)

            // Right panel: sky map + camera/star field preview
            rightPanel
        }
        .onChange(of: mode) { _, _ in
            coordinator.reset()
            engine.reset()
        }
    }

    // MARK: - Real Mode Content

    private var realModeContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            prerequisitesView

            if realPrerequisitesMet || realIsRunning {
                Divider()
                StepIndicatorRow(currentStep: realStepNumber, totalSteps: 4)

                Text(coordinator.statusMessage)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                positionList(
                    positions: coordinator.positions.map { $0 },
                    currentStep: realStepNumber,
                    isRunning: realIsRunning
                )

                if let error = coordinator.polarError {
                    PolarErrorCard(error: error)
                }

                Divider()
                realControlsView
            }
        }
    }

    // MARK: - Simulate Mode Content

    private var simulateModeContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Prerequisites") {
                PrerequisiteRow(
                    name: "Solver DB",
                    met: plateSolveService.isLoaded,
                    detail: plateSolveService.isLoaded
                        ? (plateSolveService.databaseInfo ?? "Loaded")
                        : "Load database in Settings"
                )
                .padding(.vertical, 4)
            }

            GroupBox("Simulation Setup") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Injected Error")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    simSlider(label: "Alt", value: $engine.injectedAltError,
                              range: -30...30, format: "%+.1f'")
                    simSlider(label: "Az", value: $engine.injectedAzError,
                              range: -30...30, format: "%+.1f'")

                    Divider()

                    HStack(spacing: 6) {
                        Picker("Detector", selection: $engine.useClassicalDetector) {
                            Text("Classical").tag(true)
                            Text("CoreML").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 180)
                    }

                    simSlider(label: "Seeing", value: $engine.seeingFWHM,
                              range: 0.5...6.0, format: "%.1f\"")
                }
                .padding(.vertical, 4)
            }

            if engine.currentStep > 0 {
                Divider()
                StepIndicatorRow(
                    currentStep: min(engine.currentStep, 4),
                    totalSteps: 4
                )

                positionList(
                    positions: engine.solvedPositions.map { r in
                        r.map { CelestialCoord(raDeg: $0.raDeg, decDeg: $0.decDeg) }
                    },
                    currentStep: min(engine.currentStep, 3),
                    isRunning: engine.isRunning
                )

                if let error = engine.computedError {
                    PolarErrorCard(error: error)
                }
            }

            Divider()
            simControlsView
        }
    }

    // MARK: - Position List (shared)

    private func positionList(positions: [CelestialCoord?], currentStep: Int, isRunning: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<3, id: \.self) { i in
                HStack {
                    Text("Position \(i + 1)")
                        .fontWeight(currentStep == i + 1 ? .semibold : .regular)
                        .foregroundStyle(currentStep == i + 1 ? .primary : .secondary)
                    Spacer()
                    if let c = positions[i] {
                        Text(String(format: "RA %.2f° Dec %+.2f°", c.raDeg, c.decDeg))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.green)
                    } else if currentStep == i + 1 && isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding()
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Correction Section

    private var correctionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Adjustment")
                .font(.title2)

            if let error = displayError {
                HStack(spacing: 24) {
                    BullseyeView(error: error)
                        .frame(width: 200, height: 200)

                    VStack(alignment: .leading, spacing: 12) {
                        Text(String(format: "%.1f'", error.totalErrorArcmin))
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundStyle(errorColor(error.totalErrorArcmin))

                        AdjustmentRow(
                            label: "Altitude",
                            value: error.altErrorArcmin,
                            direction: error.altErrorArcmin > 0 ? "Lower mount" : "Raise mount",
                            icon: error.altErrorArcmin > 0 ? "arrow.down" : "arrow.up"
                        )
                        AdjustmentRow(
                            label: "Azimuth",
                            value: error.azErrorArcmin,
                            direction: error.azErrorArcmin > 0 ? "Turn left" : "Turn right",
                            icon: error.azErrorArcmin > 0 ? "arrow.left" : "arrow.right"
                        )
                    }
                }
            }

            // Real mode: correction loop status
            if mode == .real && coordinator.isCorrecting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Measuring continuously...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Simulated mount screws (simulate mode only)
            if mode == .simulate {
                GroupBox("Simulated Mount Screws") {
                    VStack(alignment: .leading, spacing: 10) {
                        simSlider(label: "Alt adj.", value: $engine.adjustmentAlt,
                                  range: -30...30, format: "%+.1f'")
                        simSlider(label: "Az adj.", value: $engine.adjustmentAz,
                                  range: -30...30, format: "%+.1f'")

                        if let err = engine.correctionError {
                            HStack(spacing: 4) {
                                Text("Remaining error:")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(String(format: "%.1f'", err.totalErrorArcmin))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(errorColor(err.totalErrorArcmin))
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            // Error history
            if errorTracker.errorHistory.count > 1 {
                ErrorHistoryGraph(samples: errorTracker.errorHistory)
                    .frame(height: 100)
            }

            // Re-measure / Reset
            HStack(spacing: 12) {
                Button {
                    remeasure()
                } label: {
                    Label("Re-measure", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(mode == .real ? coordinator.isBusy : engine.isRunning)

                Button("Reset") {
                    if mode == .real { coordinator.reset() }
                    else { engine.reset() }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Right Panel

    @ViewBuilder
    private var rightPanel: some View {
        if mode == .real {
            realPreviewPanel
        } else {
            simulatePreviewPanel
        }
    }

    private var realPreviewPanel: some View {
        VSplitView {
            // Sky map (top)
            ZStack(alignment: .bottomLeading) {
                SkyMapView(viewModel: skyMapVM) { raHours, decDeg in
                    // GoTo target on sky map click
                    if coordinator.mountService.isConnected {
                        Task {
                            try? await coordinator.mountService.gotoRADec(raHours: raHours, decDeg: decDeg)
                        }
                    }
                }

                if let solvedRA = skyMapVM.solvedRA {
                    HStack(spacing: 6) {
                        Image(systemName: "viewfinder")
                            .foregroundStyle(.cyan)
                            .font(.caption2)
                        Text(String(format: "RA %.1f° Dec %+.1f°", solvedRA, skyMapVM.solvedDec ?? 0))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.cyan)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(8)
                }
            }
            .frame(minHeight: 200, idealHeight: 280)

            // Camera preview (bottom)
            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    if cameraViewModel.isCapturing {
                        CameraPreviewView(viewModel: cameraViewModel.previewViewModel)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        starCountOverlay(count: cameraViewModel.detectedStars.count)
                    } else if cameraViewModel.isConnected {
                        placeholder(icon: "camera", message: "Press Start to begin live preview")
                    } else {
                        placeholder(icon: "camera.fill", message: "Connect a camera in Camera tab")
                    }
                }

                // Status bar
                HStack(spacing: 12) {
                    Circle()
                        .fill(realIsRunning ? Color.orange : (isCorrectingPhase ? Color.green : Color.gray))
                        .frame(width: 8, height: 8)
                    Text(coordinator.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if cameraViewModel.isCapturing {
                        Text("\(cameraViewModel.detectedStars.count) stars")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.bar)
            }
            .frame(minHeight: 200)
        }
        .frame(minWidth: 400)
        .onAppear {
            setupRealSkyMap()
        }
        .onChange(of: plateSolveService.isLoaded) { _, loaded in
            if loaded { loadSkyMapCatalog() }
        }
        .onChange(of: coordinator.mountService.status) { _, newStatus in
            skyMapVM.syncToMount(status: newStatus)
        }
        .onChange(of: coordinator.solvedRA) { _, ra in
            if let ra {
                skyMapVM.solvedRA = ra
                skyMapVM.centerRA = ra
            }
        }
        .onChange(of: coordinator.solvedDec) { _, dec in
            if let dec {
                skyMapVM.solvedDec = dec
                skyMapVM.centerDec = dec
            }
        }
    }

    private var simulatePreviewPanel: some View {
        VSplitView {
            // Sky map (top)
            ZStack(alignment: .bottomLeading) {
                SkyMapView(viewModel: skyMapVM) { _, _ in }

                if engine.previewStarCount > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                            .font(.caption2)
                        Text("\(engine.previewStarCount) catalog stars")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.yellow)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(8)
                }
            }
            .frame(minHeight: 200, idealHeight: 280)

            // Star field preview (bottom)
            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    if let image = engine.previewImage {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    }
                    starCountOverlay(
                        count: engine.isRunning ? engine.lastDetectedCount : engine.previewStarCount,
                        label: engine.isRunning ? "detected" : "catalog stars"
                    )
                }

                // Status bar
                HStack(spacing: 12) {
                    Circle()
                        .fill(engine.isRunning ? Color.purple : (engine.currentStep == 4 ? Color.green : Color.gray))
                        .frame(width: 8, height: 8)
                    Text(engine.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Text("\(engine.imageWidth)x\(engine.imageHeight)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.bar)
            }
            .frame(minHeight: 200)
        }
        .frame(minWidth: 400)
        .onAppear {
            setupSkyMap()
            Task {
                await engine.renderPreview(plateSolveService: plateSolveService)
            }
        }
        .onChange(of: plateSolveService.isLoaded) { _, loaded in
            if loaded { loadSkyMapCatalog() }
        }
        .onChange(of: skyMapVM.centerRA) { _, newRA in
            guard !engine.isRunning, engine.currentStep != 4 else { return }
            engine.initialRA = newRA
            engine.initialDec = skyMapVM.centerDec
            updateSkyMapFOV()
            debouncePreview()
        }
        .onChange(of: skyMapVM.centerDec) { _, _ in
            guard !engine.isRunning, engine.currentStep != 4 else { return }
            engine.initialDec = skyMapVM.centerDec
            updateSkyMapFOV()
            debouncePreview()
        }
        .onChange(of: engine.adjustmentAlt) { _, _ in
            debounceCorrectionUpdate()
        }
        .onChange(of: engine.adjustmentAz) { _, _ in
            debounceCorrectionUpdate()
        }
        .onChange(of: engine.currentCameraRA) { _, ra in
            if let ra {
                skyMapVM.solvedRA = ra
                // Center the sky map on the camera when mount is moving
                if engine.isRunning || engine.currentStep == 4 {
                    skyMapVM.centerRA = ra
                }
            }
        }
        .onChange(of: engine.currentCameraDec) { _, dec in
            if let dec {
                skyMapVM.solvedDec = dec
                if engine.isRunning || engine.currentStep == 4 {
                    skyMapVM.centerDec = dec
                }
            }
        }
    }

    // MARK: - Sky Map Setup (Real Mode)

    private func setupRealSkyMap() {
        let lat = UserDefaults.standard.double(forKey: "observerLat")
        let lon = UserDefaults.standard.double(forKey: "observerLon")
        skyMapVM.observerLatDeg = lat != 0 ? lat : 60.17
        skyMapVM.observerLonDeg = lon != 0 ? lon : 24.94
        skyMapVM.mapFOV = 30.0
        skyMapVM.followMount = true
        skyMapVM.startLSTTimer()
        loadSkyMapCatalog()

        // Set camera FOV from telescope settings
        let focalLength = UserDefaults.standard.double(forKey: "focalLengthMM")
        if focalLength > 0 {
            let sensorWidthMM = 11.14 // ASI585MC default
            let fov = 2.0 * atan(sensorWidthMM / (2.0 * focalLength)) * 180.0 / .pi
            skyMapVM.cameraFOVDeg = fov
        }

        // Sync to current mount position if available
        skyMapVM.syncToMount(status: coordinator.mountService.status)
    }

    // MARK: - Sky Map Setup (Simulate Mode)

    private func setupSkyMap() {
        skyMapVM.observerLatDeg = engine.observerLatDeg
        skyMapVM.observerLonDeg = engine.observerLonDeg
        skyMapVM.mapFOV = 30.0
        skyMapVM.followMount = false
        skyMapVM.startLSTTimer()
        loadSkyMapCatalog()
        updateSkyMapFOV()

        let ra = engine.initialRA ?? (skyMapVM.lstRadians * 180.0 / .pi + 15.0)
        skyMapVM.centerRA = ra.truncatingRemainder(dividingBy: 360.0)
        skyMapVM.centerDec = engine.initialDec
    }

    private func loadSkyMapCatalog() {
        guard plateSolveService.isLoaded, skyMapVM.catalogStars.isEmpty else { return }
        Task {
            let stars = await plateSolveService.getStarCatalog()
            skyMapVM.catalogStars = stars
            skyMapVM.catalogLoaded = true
        }
    }

    private func updateSkyMapFOV() {
        skyMapVM.cameraFOVDeg = engine.fovDeg
        skyMapVM.cameraRollDeg = engine.cameraRollDeg
        skyMapVM.solvedRA = engine.initialRA ?? skyMapVM.centerRA
        skyMapVM.solvedDec = engine.initialDec
        skyMapVM.solvedRollDeg = engine.cameraRollDeg
        skyMapVM.solvedFOVDeg = engine.fovDeg
    }

    @State private var previewTask: Task<Void, Never>?
    @State private var correctionTask: Task<Void, Never>?

    private func debouncePreview() {
        previewTask?.cancel()
        previewTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            await engine.renderPreview(plateSolveService: plateSolveService)
        }
    }

    private func debounceCorrectionUpdate() {
        guard engine.currentStep == 4, !engine.isRunning else { return }
        correctionTask?.cancel()
        correctionTask = Task {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms debounce for responsive feel
            guard !Task.isCancelled else { return }
            engine.updateCorrectionPreview(plateSolveService: plateSolveService)
        }
    }

    // MARK: - Shared UI Components

    private func starCountOverlay(count: Int, label: String = "stars") -> some View {
        VStack {
            HStack {
                if count > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                            .font(.caption2)
                        Text("\(count) \(label)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.yellow)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                Spacer()
            }
            Spacer()
        }
        .padding(8)
    }

    private func placeholder(icon: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text(message)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.05))
    }

    // MARK: - Prerequisites (Real Mode)

    private var realPrerequisitesMet: Bool {
        cameraViewModel.isConnected &&
        coordinator.mountService.isConnected &&
        coordinator.plateSolveService.isLoaded
    }

    private var prerequisitesView: some View {
        GroupBox("Prerequisites") {
            VStack(alignment: .leading, spacing: 8) {
                PrerequisiteRow(
                    name: "Camera",
                    met: cameraViewModel.isConnected,
                    detail: cameraViewModel.isConnected
                        ? (cameraViewModel.isCapturing ? "Connected, live" : "Connected")
                        : "Connect in Camera tab"
                )
                PrerequisiteRow(
                    name: "Mount",
                    met: coordinator.mountService.isConnected,
                    detail: coordinator.mountService.isConnected
                        ? (coordinator.mountService.backendName ?? "Connected")
                        : "Connect in Settings"
                )
                PrerequisiteRow(
                    name: "Solver DB",
                    met: coordinator.plateSolveService.isLoaded,
                    detail: coordinator.plateSolveService.isLoaded
                        ? (coordinator.plateSolveService.databaseInfo ?? "Loaded")
                        : "Load database in Settings"
                )
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Real Mode Controls

    private var realControlsView: some View {
        VStack(spacing: 12) {
            // Star count indicator while running
            if realIsRunning {
                let starCount = cameraViewModel.detectedStars.count
                HStack(spacing: 8) {
                    Image(systemName: "star.fill")
                        .foregroundStyle(starCount >= 8 ? .yellow : .gray)
                    Text("\(starCount) stars detected")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(starCount >= 8 ? .primary : .secondary)
                    if starCount < 4 {
                        Text("(need 4+)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 16) {
                if !realIsRunning && !isCorrectingPhase {
                    Button("Start Alignment") {
                        startRealAlignment()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!realPrerequisitesMet || coordinator.isBusy)
                }

                if realIsRunning || isCorrectingPhase {
                    Button("Reset") { coordinator.reset() }
                        .buttonStyle(.bordered)
                }
            }

            if coordinator.isBusy && !isCorrectingPhase {
                ProgressView().controlSize(.small)
            }
        }
    }

    // MARK: - Simulate Mode Controls

    private var simControlsView: some View {
        HStack(spacing: 12) {
            if engine.isRunning {
                ProgressView().controlSize(.small)
                Text("Running...").foregroundStyle(.secondary)
            } else {
                Button {
                    Task {
                        await engine.run(plateSolveService: plateSolveService)
                    }
                } label: {
                    Label("Start Alignment", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(!plateSolveService.isLoaded)

                if engine.currentStep > 0 {
                    Button("Reset") { engine.reset() }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: - Actions

    private func startRealAlignment() {
        if cameraViewModel.isConnected && !cameraViewModel.isCapturing {
            let settings = CameraSettings(
                exposureMs: exposureMs,
                gain: Int(gain),
                binning: binning
            )
            cameraViewModel.startLive(settings: settings)
        }
        coordinator.runAutoAlignment(cameraViewModel: cameraViewModel)
    }

    private func remeasure() {
        if mode == .real {
            // In correction mode, just restart the correction loop
            // (no need to redo full 3-point alignment)
            if coordinator.isCorrecting {
                coordinator.startCorrectionLoop(cameraViewModel: cameraViewModel)
            } else {
                coordinator.reset()
                startRealAlignment()
            }
            return
        } else {
            // Re-run alignment with current adjustment offsets applied.
            // After re-measure, the computed error IS the actual remaining error,
            // so reset the sliders to zero (adjustment is now the new baseline).
            engine.currentStep = 0
            engine.computedError = nil
            engine.correctionError = nil
            engine.solvedPositions = [nil, nil, nil]
            engine.statusMessage = "Re-measuring..."
            Task {
                await engine.run(plateSolveService: plateSolveService)
                // The new computed error reflects the corrected mount position.
                // Update injected errors to match (adjustment is now the baseline)
                // and reset sliders to zero.
                if let newError = engine.computedError {
                    engine.injectedAltError = newError.altErrorArcmin
                    engine.injectedAzError = newError.azErrorArcmin
                }
                engine.adjustmentAlt = 0
                engine.adjustmentAz = 0
            }
        }
    }

    // MARK: - Real Mode Helpers

    private var realStepNumber: Int {
        switch coordinator.step {
        case .idle: return 0
        case .waitingForSolve(let n): return n
        case .slewing(let n): return n
        case .computing: return 3
        case .complete: return 4
        case .correcting: return 4
        case .error: return 0
        }
    }

    private var realIsRunning: Bool {
        switch coordinator.step {
        case .idle, .complete, .correcting, .error: return false
        default: return true
        }
    }

    private var realIsWaitingForSolve: Bool {
        if case .waitingForSolve = coordinator.step { return true }
        return false
    }

    // MARK: - Slider Helper

    private func simSlider(
        label: String, value: Binding<Double>,
        range: ClosedRange<Double>, format: String
    ) -> some View {
        HStack {
            Text(label)
                .frame(width: 60, alignment: .trailing)
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: value, in: range)
                .frame(maxWidth: 150)
            Text(String(format: format, value.wrappedValue))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 50, alignment: .trailing)
        }
    }
}

private func errorColor(_ arcmin: Double) -> Color {
    if arcmin < 2 { return .green }
    if arcmin < 10 { return .yellow }
    return .red
}
