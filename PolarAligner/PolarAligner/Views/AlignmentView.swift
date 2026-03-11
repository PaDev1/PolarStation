import SwiftUI
import PolarCore

/// Step-by-step polar alignment UI.
///
/// Shows prerequisites, camera preview, progress through the three-point
/// capture workflow, and the computed alignment error with correction directions.
struct AlignmentView: View {
    @ObservedObject var coordinator: AlignmentCoordinator
    @ObservedObject var cameraViewModel: CameraViewModel
    @Binding var selectedTab: String?

    // Camera settings for auto-start live preview
    @AppStorage("exposureMs") private var exposureMs: Double = 500
    @AppStorage("gain") private var gain: Double = 300
    @AppStorage("binning") private var binning: Int = 2

    var body: some View {
        HSplitView {
            // Left panel: prerequisites, steps, controls
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Polar Alignment")
                        .font(.title)

                    prerequisitesView

                    if allPrerequisitesMet || isRunning {
                        Divider()
                        StepIndicatorRow(currentStep: stepNumber, totalSteps: 3)

                        // Status
                        Text(coordinator.statusMessage)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)

                        // Position results
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(0..<3, id: \.self) { i in
                                PositionRow(
                                    index: i + 1,
                                    coord: coordinator.positions[i],
                                    isActive: stepNumber == i + 1
                                )
                            }
                        }
                        .padding()
                        .background(.quaternary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                        // Error result
                        if let error = coordinator.polarError {
                            PolarErrorCard(error: error)

                            Button("Begin Adjustment") {
                                selectedTab = "adjustment"
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                        }

                        Divider()
                        controlsView
                    }

                    Spacer()
                }
                .padding()
            }
            .frame(minWidth: 320, idealWidth: 380, maxWidth: 420)

            // Right panel: camera preview
            VStack(spacing: 0) {
                if cameraViewModel.isCapturing {
                    ZStack {
                        CameraPreviewView(viewModel: cameraViewModel.previewViewModel)

                        // Star count overlay
                        VStack {
                            HStack {
                                if cameraViewModel.starDetectionEnabled {
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
                            }
                            Spacer()
                        }
                        .padding(8)
                    }
                } else if cameraViewModel.isConnected {
                    VStack(spacing: 12) {
                        Image(systemName: "camera")
                            .font(.system(size: 48))
                            .foregroundStyle(.tertiary)
                        Text("Press Start to begin live preview")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.tertiary)
                        Text("Connect a camera to see the sky")
                            .foregroundStyle(.secondary)
                        Text("Go to Camera tab to connect")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(white: 0.05))
                }
            }
            .frame(minWidth: 400)
        }
    }

    // MARK: - Prerequisites

    private var allPrerequisitesMet: Bool {
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

    // MARK: - Controls

    private var controlsView: some View {
        VStack(spacing: 12) {
            // Star count indicator when waiting for capture
            if isWaitingForSolve {
                let starCount = cameraViewModel.detectedStars.count
                HStack(spacing: 8) {
                    Image(systemName: "star.fill")
                        .foregroundStyle(starCount >= 8 ? .yellow : .gray)
                    Text("\(starCount) stars detected")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(starCount >= 8 ? .primary : .secondary)
                    if starCount < 8 {
                        Text("(need 8+)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 16) {
                if !isRunning {
                    Button("Start Alignment") {
                        startAlignment()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!allPrerequisitesMet || coordinator.isBusy)
                }

                if isWaitingForSolve {
                    Button("Capture") {
                        captureAndSolve()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(coordinator.isBusy || cameraViewModel.detectedStars.count < 4)
                }

                if isRunning || coordinator.step == .complete {
                    Button("Reset") {
                        coordinator.reset()
                    }
                    .buttonStyle(.bordered)
                }
            }

            if coordinator.isBusy {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Actions

    private func startAlignment() {
        // Auto-start camera live preview if not already capturing
        if cameraViewModel.isConnected && !cameraViewModel.isCapturing {
            let settings = CameraSettings(
                exposureMs: exposureMs,
                gain: Int(gain),
                binning: binning
            )
            cameraViewModel.startLive(settings: settings)
        }

        coordinator.startAlignment()
    }

    private func captureAndSolve() {
        let stars = cameraViewModel.detectedStars
        guard stars.count >= 4 else { return }
        coordinator.submitStars(stars)
    }

    // MARK: - Helpers

    private var stepNumber: Int {
        switch coordinator.step {
        case .idle: return 0
        case .waitingForSolve(let n): return n
        case .slewing(let n): return n
        case .computing: return 3
        case .complete: return 3
        case .error: return 0
        }
    }

    private var isRunning: Bool {
        switch coordinator.step {
        case .idle, .complete, .error: return false
        default: return true
        }
    }

    private var isWaitingForSolve: Bool {
        if case .waitingForSolve = coordinator.step { return true }
        return false
    }
}

// MARK: - Prerequisite Row

struct PrerequisiteRow: View {
    let name: String
    let met: Bool
    let detail: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: met ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(met ? .green : .red)
            Text(name)
                .fontWeight(.medium)
            Spacer()
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Subviews

struct StepIndicatorRow: View {
    let currentStep: Int
    let totalSteps: Int

    var body: some View {
        HStack(spacing: 12) {
            ForEach(1...totalSteps, id: \.self) { i in
                StepCircle(number: i, state: state(for: i))

                if i < totalSteps {
                    Rectangle()
                        .fill(i < currentStep ? Color.green : Color.gray.opacity(0.3))
                        .frame(height: 2)
                        .frame(maxWidth: 40)
                }
            }
        }
    }

    private func state(for step: Int) -> StepCircle.State {
        if step < currentStep { return .complete }
        if step == currentStep { return .active }
        return .pending
    }
}

struct StepCircle: View {
    let number: Int
    let state: State

    enum State {
        case pending, active, complete
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(fillColor)
                .frame(width: 36, height: 36)
            if state == .complete {
                Image(systemName: "checkmark")
                    .foregroundStyle(.white)
                    .font(.system(size: 14, weight: .bold))
            } else {
                Text("\(number)")
                    .foregroundStyle(state == .active ? .white : .secondary)
                    .font(.system(size: 14, weight: .semibold))
            }
        }
    }

    private var fillColor: Color {
        switch state {
        case .complete: return .green
        case .active: return .blue
        case .pending: return Color.gray.opacity(0.2)
        }
    }
}

struct PositionRow: View {
    let index: Int
    let coord: CelestialCoord?
    let isActive: Bool

    var body: some View {
        HStack {
            Text("Position \(index)")
                .fontWeight(isActive ? .semibold : .regular)
                .foregroundStyle(isActive ? .primary : .secondary)

            Spacer()

            if let c = coord {
                Text(String(format: "RA %.3f°  Dec %+.3f°", c.raDeg, c.decDeg))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.green)
            } else if isActive {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text("—")
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct PolarErrorCard: View {
    let error: PolarError

    var body: some View {
        VStack(spacing: 12) {
            Text("Alignment Error")
                .font(.headline)

            // Total error with color coding
            Text(String(format: "%.1f arcmin", error.totalErrorArcmin))
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(errorColor)

            // Corrections needed
            HStack(spacing: 32) {
                VStack {
                    Text("Altitude")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%+.1f'", error.altErrorArcmin))
                        .font(.system(.title2, design: .monospaced))
                    Text(error.altErrorArcmin > 0 ? "Lower" : "Raise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack {
                    Text("Azimuth")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%+.1f'", error.azErrorArcmin))
                        .font(.system(.title2, design: .monospaced))
                    Text(error.azErrorArcmin > 0 ? "Turn Left" : "Turn Right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(errorColor.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var errorColor: Color {
        if error.totalErrorArcmin < 2 { return .green }
        if error.totalErrorArcmin < 10 { return .yellow }
        return .red
    }
}
