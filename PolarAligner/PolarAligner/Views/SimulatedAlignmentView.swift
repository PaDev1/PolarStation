import SwiftUI
import PolarCore

/// Simulator UI for the three-point polar alignment workflow.
///
/// Layout: HSplitView. Left panel has setup controls and results.
/// Right panel has a sky map (top) for choosing camera pointing and
/// a camera preview (bottom) showing the rendered star field.
struct SimulatedAlignmentView: View {
    @ObservedObject var engine: SimulatedAlignmentEngine
    @ObservedObject var plateSolveService: PlateSolveService
    @StateObject private var skyMapVM = SkyMapViewModel()

    var body: some View {
        HSplitView {
            // Left panel: controls
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Alignment Simulator")
                        .font(.title)

                    setupGroupBox
                    Divider()
                    progressGroupBox

                    if engine.currentStep == 4 {
                        Divider()
                        adjustmentGroupBox
                        Divider()
                        resultsGroupBox
                    }

                    Spacer()
                }
                .padding()
            }
            .frame(minWidth: 320, idealWidth: 380, maxWidth: 420)

            // Right panel: sky map + camera preview
            VSplitView {
                // Sky map for choosing camera pointing
                ZStack(alignment: .bottomLeading) {
                    SkyMapView(viewModel: skyMapVM) { _, _ in }

                    // Star count + pointing info overlay
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
                .frame(minHeight: 200, idealHeight: 300)
                .onTapGesture { location in
                    // This won't fire because SkyMapView has its own gestures.
                    // Instead, we use onChange to track skyMapVM center changes.
                }

                // Simulated star field preview
                VStack(spacing: 0) {
                    ZStack {
                        Color.black

                        if let image = engine.previewImage {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        }

                        // Star count + status overlay
                        VStack {
                            HStack {
                                if engine.isRunning || engine.currentStep == 4 {
                                    HStack(spacing: 6) {
                                        Image(systemName: "star.fill")
                                            .foregroundStyle(.yellow)
                                            .font(.caption2)
                                        Text("\(engine.lastDetectedCount) detected")
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(.yellow)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.black.opacity(0.6))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                }

                                Spacer()

                                if engine.isRunning {
                                    Text("Simulating...")
                                        .font(.system(.caption, design: .monospaced))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(.black.opacity(0.6))
                                        .foregroundStyle(.purple)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                            }
                            Spacer()
                        }
                        .padding(8)
                    }

                    // Bottom status bar
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
        }
        .onAppear {
            setupSkyMap()
            // Auto-render preview with default pointing
            Task {
                await engine.renderPreview(plateSolveService: plateSolveService)
            }
        }
        .onChange(of: plateSolveService.isLoaded) { _, loaded in
            if loaded { loadStarCatalog() }
        }
        // When user drags the sky map, update engine pointing and re-render preview
        .onChange(of: skyMapVM.centerRA) { _, newRA in
            guard !engine.isRunning else { return }
            engine.initialRA = newRA
            engine.initialDec = skyMapVM.centerDec
            updateSkyMapFOV()
            debouncePreview()
        }
        .onChange(of: skyMapVM.centerDec) { _, newDec in
            guard !engine.isRunning else { return }
            engine.initialDec = newDec
            updateSkyMapFOV()
            debouncePreview()
        }
        .onChange(of: engine.initialDec) {
            updateSkyMapFOV()
            debouncePreview()
        }
        .onChange(of: engine.cameraRollDeg) {
            updateSkyMapFOV()
            debouncePreview()
        }
        .onChange(of: engine.seeingFWHM) {
            debouncePreview()
        }
    }

    // MARK: - Sky Map Setup

    private func setupSkyMap() {
        skyMapVM.observerLatDeg = engine.observerLatDeg
        skyMapVM.observerLonDeg = engine.observerLonDeg
        skyMapVM.mapFOV = 30.0  // Start zoomed in a bit
        skyMapVM.followMount = false
        skyMapVM.startLSTTimer()
        loadStarCatalog()
        updateSkyMapFOV()

        // Set initial center to engine's current pointing
        let ra = engine.initialRA ?? (skyMapVM.lstRadians * 180.0 / .pi + 15.0)
        skyMapVM.centerRA = ra.truncatingRemainder(dividingBy: 360.0)
        skyMapVM.centerDec = engine.initialDec
    }

    private func loadStarCatalog() {
        guard plateSolveService.isLoaded else { return }
        guard skyMapVM.catalogStars.isEmpty else { return }
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

    // Debounce preview rendering during rapid drag
    @State private var previewTask: Task<Void, Never>?

    private func debouncePreview() {
        previewTask?.cancel()
        previewTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000) // 150ms
            guard !Task.isCancelled else { return }
            await engine.renderPreview(plateSolveService: plateSolveService)
        }
    }

    // MARK: - Setup GroupBox

    private var setupGroupBox: some View {
        GroupBox("Simulation Setup") {
            VStack(alignment: .leading, spacing: 10) {
                // Solver DB prerequisite
                HStack(spacing: 8) {
                    Image(systemName: plateSolveService.isLoaded ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(plateSolveService.isLoaded ? .green : .red)
                    Text("Solver DB")
                        .fontWeight(.medium)
                    Spacer()
                    Text(plateSolveService.isLoaded
                         ? (plateSolveService.databaseInfo ?? "Loaded")
                         : "Load in Settings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                // Injected error sliders
                Text("Injected Error")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                simSlider(label: "Alt", value: $engine.injectedAltError,
                          range: -30...30, format: "%+.1f'")
                simSlider(label: "Az", value: $engine.injectedAzError,
                          range: -30...30, format: "%+.1f'")

                Divider()

                // Detector toggle
                HStack(spacing: 6) {
                    Picker("Detector", selection: $engine.useClassicalDetector) {
                        Text("Classical").tag(true)
                        Text("CoreML").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 180)

                    Image(systemName: engine.useClassicalDetector ? "cpu" : "brain")
                        .foregroundStyle(engine.useClassicalDetector ? .blue : .green)
                        .font(.caption)
                }

                // Camera parameters
                simSlider(label: "Seeing", value: $engine.seeingFWHM,
                          range: 0.5...6.0, format: "%.1f\"")
                simSlider(label: "Roll", value: $engine.cameraRollDeg,
                          range: 0...360, format: "%.0f°")

                Divider()

                // Start / Reset buttons
                HStack(spacing: 12) {
                    if engine.isRunning {
                        ProgressView()
                            .controlSize(.small)
                        Text("Running...")
                            .foregroundStyle(.secondary)
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
                            Button("Reset") {
                                engine.reset()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Progress GroupBox

    private var progressGroupBox: some View {
        GroupBox("Progress") {
            VStack(alignment: .leading, spacing: 8) {
                StepIndicatorRow(
                    currentStep: min(engine.currentStep, 3),
                    totalSteps: 3
                )

                ForEach(0..<3, id: \.self) { i in
                    HStack {
                        Text("Position \(i + 1)")
                            .fontWeight(engine.currentStep == i + 1 ? .semibold : .regular)
                            .foregroundStyle(engine.currentStep == i + 1 ? .primary : .secondary)

                        Spacer()

                        if let result = engine.solvedPositions[i] {
                            Text(String(format: "RA %.2f° Dec %+.2f°", result.raDeg, result.decDeg))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.green)
                        } else if engine.currentStep == i + 1 && engine.isRunning {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("—")
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Adjustment GroupBox

    private var adjustmentGroupBox: some View {
        GroupBox("Manual Adjustment") {
            VStack(alignment: .leading, spacing: 10) {
                if let error = engine.computedError {
                    // Current computed error display
                    HStack(spacing: 24) {
                        VStack {
                            Text("Alt Error")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(String(format: "%+.1f'", error.altErrorArcmin))
                                .font(.system(.title3, design: .monospaced))
                        }
                        VStack {
                            Text("Az Error")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(String(format: "%+.1f'", error.azErrorArcmin))
                                .font(.system(.title3, design: .monospaced))
                        }
                        VStack {
                            Text("Total")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(String(format: "%.1f'", error.totalErrorArcmin))
                                .font(.system(.title3, design: .monospaced))
                                .foregroundStyle(errorColor(error.totalErrorArcmin))
                        }
                    }
                }

                Divider()

                Text("Simulate turning mount knobs:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                simSlider(label: "Alt scale", value: $engine.mountAltitudeDeg,
                          range: (engine.observerLatDeg - 5)...(engine.observerLatDeg + 5),
                          format: "%.1f°")
                simSlider(label: "Az adj.", value: $engine.adjustmentAz,
                          range: -30...30, format: "%+.1f'")

                // Effective remaining error display
                let effectiveAlt = (engine.mountAltitudeDeg - engine.observerLatDeg) * 60.0
                let effectiveAz = engine.injectedAzError - engine.adjustmentAz
                let effectiveTotal = sqrt(effectiveAlt * effectiveAlt + effectiveAz * effectiveAz)
                HStack(spacing: 4) {
                    Text("Effective error:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "Alt %+.1f'  Az %+.1f'  (%.1f')", effectiveAlt, effectiveAz, effectiveTotal))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(errorColor(effectiveTotal))
                }

                Divider()

                Button {
                    Task {
                        await engine.run(plateSolveService: plateSolveService)
                    }
                } label: {
                    Label("Re-measure", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(engine.isRunning || !plateSolveService.isLoaded)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Results GroupBox

    private var resultsGroupBox: some View {
        GroupBox("Results") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("")
                        .frame(width: 80, alignment: .trailing)
                    Text("Alt")
                        .frame(width: 70, alignment: .trailing)
                        .font(.caption.bold())
                    Text("Az")
                        .frame(width: 70, alignment: .trailing)
                        .font(.caption.bold())
                    Text("Total")
                        .frame(width: 70, alignment: .trailing)
                        .font(.caption.bold())
                }

                // Injected row
                HStack {
                    Text("Injected")
                        .frame(width: 80, alignment: .trailing)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%+.1f'", engine.injectedAltError))
                        .frame(width: 70, alignment: .trailing)
                        .font(.system(.caption, design: .monospaced))
                    Text(String(format: "%+.1f'", engine.injectedAzError))
                        .frame(width: 70, alignment: .trailing)
                        .font(.system(.caption, design: .monospaced))
                    let injTotal = sqrt(engine.injectedAltError * engine.injectedAltError +
                                        engine.injectedAzError * engine.injectedAzError)
                    Text(String(format: "%.1f'", injTotal))
                        .frame(width: 70, alignment: .trailing)
                        .font(.system(.caption, design: .monospaced))
                }

                // Computed row
                if let error = engine.computedError {
                    HStack {
                        Text("Computed")
                            .frame(width: 80, alignment: .trailing)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(String(format: "%+.1f'", error.altErrorArcmin))
                            .frame(width: 70, alignment: .trailing)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.green)
                        Text(String(format: "%+.1f'", error.azErrorArcmin))
                            .frame(width: 70, alignment: .trailing)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.green)
                        Text(String(format: "%.1f'", error.totalErrorArcmin))
                            .frame(width: 70, alignment: .trailing)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.green)
                    }

                    // Delta row
                    let dAlt = error.altErrorArcmin - engine.injectedAltError
                    let dAz = error.azErrorArcmin - engine.injectedAzError
                    HStack {
                        Text("Delta")
                            .frame(width: 80, alignment: .trailing)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(String(format: "%+.1f'", dAlt))
                            .frame(width: 70, alignment: .trailing)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(abs(dAlt) < 1 ? .green : .orange)
                        Text(String(format: "%+.1f'", dAz))
                            .frame(width: 70, alignment: .trailing)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(abs(dAz) < 1 ? .green : .orange)
                        let dTotal = sqrt(dAlt * dAlt + dAz * dAz)
                        Text(String(format: "%.1f'", dTotal))
                            .frame(width: 70, alignment: .trailing)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(dTotal < 1 ? .green : .orange)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Helpers

    private func simSlider(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: String
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

    private func errorColor(_ arcmin: Double) -> Color {
        if arcmin < 2 { return .green }
        if arcmin < 10 { return .yellow }
        return .red
    }
}
