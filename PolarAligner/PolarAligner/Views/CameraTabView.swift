import SwiftUI

/// Which camera feed to display in the Camera tab.
enum CameraViewSource: String, CaseIterable {
    case main = "Main Camera"
    case guide = "Guide Camera"
}

/// Camera tab: live preview viewer for connected cameras, with capture support.
/// Connections are managed in Settings — this tab just displays the selected camera's feed.
///
/// Outer shell does NOT observe either camera to avoid layout storms from @Published changes
/// on both cameras simultaneously. Only the inner CameraViewerContent observes the active camera.
struct CameraTabView: View {
    let mainCamera: CameraViewModel
    let guideCamera: CameraViewModel

    @State private var selectedSource: CameraViewSource = .main

    var body: some View {
        CameraViewerContent(
            viewModel: selectedSource == .main ? mainCamera : guideCamera,
            selectedSource: $selectedSource,
            pauseAll: {
                mainCamera.pauseLiveView()
                // Don't stop guide camera if main camera is actively capturing —
                // stopping the guide Alpaca grabber calls abortExposure, which on
                // shared INDIGO servers can interrupt the main camera's exposure.
                // Also skip if guide camera is running star detection (guiding active).
                if !mainCamera.isSaving && !guideCamera.starDetectionEnabled {
                    guideCamera.pauseLiveView()
                }
            },
            switchCamera: { oldSource, newSource in
                let oldVM = oldSource == .main ? mainCamera : guideCamera
                // Don't pause the guide camera if it's being used for guiding
                // (starDetectionEnabled = true means a guide session is running).
                // Don't pause either camera if it's actively saving frames.
                if !oldVM.isSaving && !oldVM.starDetectionEnabled {
                    oldVM.pauseLiveView()
                }
            }
        )
    }
}

/// Inner content that observes only the active camera.
private struct CameraViewerContent: View {
    @ObservedObject var viewModel: CameraViewModel
    @Binding var selectedSource: CameraViewSource

    var pauseAll: () -> Void
    var switchCamera: (CameraViewSource, CameraViewSource) -> Void

    // Camera settings (shared with SettingsView)
    @AppStorage("exposureMs") private var exposureMs: Double = 500
    @AppStorage("gain") private var gain: Double = 300
    @AppStorage("binning") private var binning: Int = 2

    // Guide camera settings
    @AppStorage("guideExposureMs") private var guideExposureMs: Double = 500
    @AppStorage("guideGain") private var guideGain: Double = 300
    @AppStorage("guideBinning") private var guideBinning: Int = 2

    // Capture settings (shared with SettingsView)
    @AppStorage("captureFolder") private var captureFolder: String = ""
    @AppStorage("captureFormat") private var captureFormat: String = "fits"
    @AppStorage("captureColorMode") private var captureColorMode: String = "rgb"
    @AppStorage("capturePrefix") private var capturePrefix: String = "capture"

    @AppStorage("stfStrength") private var stfStrength: Double = 0.15

    @State private var captureCount: Int = 1
    @State private var displayRotationDeg: Double = 0.0
    @State private var showControls: Bool = false
    @State private var showDebugLog: Bool = false

    private var effectiveExposureMs: Double {
        selectedSource == .main ? exposureMs : guideExposureMs
    }

    private var effectiveGain: Double {
        selectedSource == .main ? gain : guideGain
    }

    private var effectiveBinning: Int {
        selectedSource == .main ? binning : guideBinning
    }

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Top toolbar
            HStack(spacing: 12) {
                // Debug log toggle
                Button {
                    showDebugLog.toggle()
                } label: {
                    Image(systemName: "terminal")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(showDebugLog ? .green : .secondary)
                .help("Toggle camera debug log")

                Spacer()

                // Status
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(viewModel.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            // MARK: - Preview area
            ZStack {
                Color.black

                if viewModel.isConnected {
                    CameraPreviewView(viewModel: viewModel.previewViewModel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "camera")
                            .font(.system(size: 48))
                            .foregroundStyle(.tertiary)
                        Text("Connect \(selectedSource.rawValue.lowercased()) in Settings")
                            .foregroundStyle(.secondary)
                    }
                }

                // Overlay: controls (top-left), fps (top-right), progress (bottom)
                VStack {
                    HStack(alignment: .top) {
                        // Camera controls overlay — top left
                        CameraControlsOverlay(
                            isExpanded: $showControls,
                            isEnabled: viewModel.isConnected,
                            exposureMs: $exposureMs,
                            gain: $gain,
                            binning: $binning,
                            onApply: {
                                // Restart live view so new settings take effect immediately
                                if viewModel.isCapturing && !viewModel.isSaving {
                                    viewModel.stopCapture()
                                    viewModel.startLive(settings: currentSettings)
                                }
                            }
                        )

                        Spacer()

                        // FPS + frame activity (top-right)
                        if viewModel.isCapturing {
                            FrameRateView(previewViewModel: viewModel.previewViewModel)
                        }
                    }
                    Spacer()
                    if viewModel.isSaving, let startDate = viewModel.exposureStartDate {
                        ExposureTimerView(
                            startDate: startDate,
                            durationSec: viewModel.currentExposureSec,
                            capturedCount: viewModel.capturedCount,
                            targetCount: viewModel.targetCount
                        )
                        .padding()
                    } else if viewModel.isSaving {
                        HStack {
                            ProgressView(
                                value: Double(viewModel.capturedCount),
                                total: Double(max(viewModel.targetCount, 1))
                            )
                            .tint(.green)
                            Text("\(viewModel.capturedCount)/\(viewModel.targetCount)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding()
                    }
                }
                .padding(8)
            }

            Divider()

            // MARK: - Bottom controls
            HStack(spacing: 16) {
                // Live preview (no saving)
                if viewModel.isCapturing && !viewModel.isSaving {
                    Button {
                        viewModel.stopCapture()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                } else if !viewModel.isSaving {
                    Button {
                        viewModel.startLive(settings: currentSettings)
                    } label: {
                        Label("Live", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.isConnected)
                }

                // Capture with count (saves files)
                if viewModel.isSaving {
                    Button {
                        viewModel.stopCapture()
                    } label: {
                        Label("Abort", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                } else {
                    HStack(spacing: 4) {
                        Button {
                            startCapture()
                        } label: {
                            Label("Capture", systemImage: "camera.shutter.button")
                        }
                        .buttonStyle(.bordered)
                        .disabled(!viewModel.isConnected || viewModel.isCapturing)

                        TextField("", value: $captureCount, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 50)
                            .multilineTextAlignment(.center)

                        Stepper("", value: $captureCount, in: 1...999)
                            .labelsHidden()

                        Text(totalExposureLabel)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }

                Divider().frame(height: 20)

                // Quick settings readout
                Text(effectiveExposureMs >= 1000
                     ? String(format: "%.1f s", effectiveExposureMs / 1000)
                     : String(format: "%.0f ms", effectiveExposureMs))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(String(format: "G%.0f", effectiveGain))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("\(effectiveBinning)x\(effectiveBinning)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(captureFormat.uppercased())
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                if viewModel.selectedCamera?.isColorCamera == true {
                    Text(colorMode.displayName)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Divider().frame(height: 20)

                // Auto-stretch toggle + strength slider
                Button {
                    viewModel.previewViewModel.autoStretchEnabled.toggle()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "wand.and.stars")
                        Text(viewModel.previewViewModel.autoStretchEnabled ? "STF On" : "STF Off")
                            .font(.system(size: 11))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(viewModel.previewViewModel.autoStretchEnabled ? .cyan : nil)
                .foregroundStyle(viewModel.previewViewModel.autoStretchEnabled ? .cyan : .secondary)
                .help("Auto-stretch — adjusts display to reveal faint detail")

                if viewModel.previewViewModel.autoStretchEnabled && viewModel.isConnected {
                    Slider(value: $stfStrength, in: 0.05...0.40)
                        .frame(width: 80)
                        .controlSize(.small)
                        .help("Stretch amount: left = subtle (dark bg), right = aggressive")
                        .onChange(of: stfStrength) { _, newVal in
                            viewModel.previewViewModel.stfStrength = Float(newVal)
                        }
                }

                Divider().frame(height: 20)

                // Rotation control
                HStack(spacing: 4) {
                    Button {
                        displayRotationDeg = 0
                        viewModel.previewViewModel.displayRotationRad = 0
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help("Reset rotation")

                    TextField("", value: Binding(
                        get: { displayRotationDeg },
                        set: { newVal in
                            displayRotationDeg = newVal
                            viewModel.previewViewModel.displayRotationRad = Float(newVal * .pi / 180.0)
                        }
                    ), format: .number.precision(.fractionLength(1)))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 50)
                    .font(.system(.caption, design: .monospaced))

                    Text("°")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // Auto-rotate from last plate solve
                    Button("Auto") {
                        let solvedRot = UserDefaults.standard.double(forKey: "lastSolvedRotation")
                        if solvedRot != 0 {
                            displayRotationDeg = -solvedRot  // negate to counter camera rotation
                            viewModel.previewViewModel.displayRotationRad = Float(-solvedRot * .pi / 180.0)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help("Auto-rotate using last plate solve rotation")
                }

                Spacer()

                if viewModel.captureWidth > 0 && viewModel.isConnected {
                    Text("\(viewModel.captureWidth)x\(viewModel.captureHeight)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)

            // Error banner
            if let error = viewModel.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.caption)
                    Spacer()
                    Button("Dismiss") {
                        viewModel.errorMessage = nil
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.red.opacity(0.15))
            }

            // Debug log strip (hidden by default, toggle with button in toolbar)
            if showDebugLog {
                Divider()
                VStack(spacing: 0) {
                    HStack {
                        Text("Camera Log")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(viewModel.debugLog, forType: .string)
                        }
                        .font(.caption2)
                        .buttonStyle(.borderless)
                        Button("Clear") {
                            viewModel.debugLog = ""
                        }
                        .font(.caption2)
                        .buttonStyle(.borderless)
                        Button("Hide") { showDebugLog = false }
                            .font(.caption2)
                            .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 4)

                    ScrollView(.vertical) {
                        Text(viewModel.debugLog)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 4)
                    }
                    .frame(height: 120)
                    .background(Color.black.opacity(0.85))
                }
            }
        }
        .onAppear {
            // Sync persisted STF strength to the view model
            viewModel.previewViewModel.stfStrength = Float(stfStrength)
            // Only resume if the viewModel isn't already running (e.g. guide camera
            // running for guiding). resumeLiveView guards on wasLiveBeforePause but
            // we also skip if the camera is already active to avoid interfering.
            if !viewModel.isCapturing {
                viewModel.resumeLiveView(settings: currentSettings)
            }
        }
        .onDisappear {
            pauseAll()
        }
        .onChange(of: selectedSource) { oldValue, newValue in
            switchCamera(oldValue, newValue)
            viewModel.resumeLiveView(settings: currentSettings)
        }
    }

    // MARK: - Helpers

    private var currentSettings: CameraSettings {
        CameraSettings(
            exposureMs: effectiveExposureMs,
            gain: Int(effectiveGain),
            binning: effectiveBinning
        )
    }

    private var captureFolderURL: URL {
        if captureFolder.isEmpty {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Pictures/PolarStation")
        }
        return URL(fileURLWithPath: captureFolder)
    }

    private var format: CaptureFormat {
        CaptureFormat(rawValue: captureFormat.uppercased()) ?? .fits
    }

    private var colorMode: CaptureColorMode {
        CaptureColorMode(rawValue: captureColorMode) ?? .rgb
    }

    private var totalExposureLabel: String {
        let totalSec = effectiveExposureMs * Double(captureCount) / 1000
        if totalSec < 60 {
            return String(format: "Σ %.0fs", totalSec)
        } else if totalSec < 3600 {
            let m = Int(totalSec) / 60
            let s = Int(totalSec) % 60
            return s > 0 ? String(format: "Σ %dm %ds", m, s) : String(format: "Σ %dm", m)
        } else {
            let h = Int(totalSec) / 3600
            let m = (Int(totalSec) % 3600) / 60
            return m > 0 ? String(format: "Σ %dh %dm", h, m) : String(format: "Σ %dh", h)
        }
    }

    private var statusColor: Color {
        if viewModel.isSaving { return .orange }
        if viewModel.isCapturing { return .green }
        if viewModel.isConnected { return .yellow }
        return .red
    }

    private func startCapture() {
        let prefix = capturePrefix.isEmpty ? "capture" : capturePrefix
        viewModel.startCaptureSequence(
            count: captureCount,
            settings: currentSettings,
            format: format,
            colorMode: colorMode,
            folder: captureFolderURL,
            prefix: prefix
        )
    }
}

// MARK: - Camera Controls Overlay
private struct CameraControlsOverlay: View {
    @Binding var isExpanded: Bool
    var isEnabled: Bool
    @Binding var exposureMs: Double
    @Binding var gain: Double
    @Binding var binning: Int
    var onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Toggle button — always visible
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14))
                    .padding(8)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(isEnabled ? .white : .secondary)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    // Exposure
                    HStack(spacing: 6) {
                        Text("Exp")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, alignment: .leading)
                        TextField("", value: Binding(
                            get: {
                                exposureMs >= 1000 ? exposureMs / 1000.0 : exposureMs
                            },
                            set: { newVal in
                                exposureMs = exposureMs >= 1000 ? newVal * 1000.0 : newVal
                            }
                        ), format: .number.precision(.fractionLength(exposureMs >= 1000 ? 1 : 0)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 52)
                        .font(.system(.caption, design: .monospaced))
                        Text(exposureMs >= 1000 ? "s" : "ms")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Stepper("", value: $exposureMs, in: 1...300000, step: exposureMs >= 1000 ? 1000 : 100)
                            .labelsHidden()
                            .onChange(of: exposureMs) { _, _ in onApply() }
                    }

                    // Gain
                    HStack(spacing: 6) {
                        Text("Gain")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, alignment: .leading)
                        TextField("", value: $gain, format: .number.precision(.fractionLength(0)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 52)
                            .font(.system(.caption, design: .monospaced))
                        Text("")
                            .frame(width: 16)
                        Stepper("", value: $gain, in: 0...1000, step: 10)
                            .labelsHidden()
                            .onChange(of: gain) { _, _ in onApply() }
                    }

                    // Binning
                    HStack(spacing: 6) {
                        Text("Bin")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, alignment: .leading)
                        Picker("", selection: $binning) {
                            Text("1x").tag(1)
                            Text("2x").tag(2)
                            Text("3x").tag(3)
                            Text("4x").tag(4)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 120)
                        .onChange(of: binning) { _, _ in onApply() }
                    }
                }
                .padding(10)
                .background(.black.opacity(0.75))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .transition(.opacity.combined(with: .move(edge: .top)))
                .disabled(!isEnabled)
            }
        }
    }
}

// MARK: - Exposure Timer View
private struct ExposureTimerView: View {
    let startDate: Date
    let durationSec: Double
    let capturedCount: Int
    let targetCount: Int

    @State private var elapsed: Double = 0
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                ProgressView(value: min(elapsed, durationSec), total: max(durationSec, 1))
                    .tint(.orange)
                Text(timeLabel)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(width: 52, alignment: .trailing)
            }
            HStack {
                ProgressView(
                    value: Double(capturedCount),
                    total: Double(max(targetCount, 1))
                )
                .tint(.green)
                Text("\(capturedCount)/\(targetCount)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(width: 52, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.black.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onReceive(timer) { _ in
            elapsed = Date().timeIntervalSince(startDate)
        }
    }

    private var timeLabel: String {
        let remaining = max(0, durationSec - elapsed)
        if remaining >= 10 {
            return String(format: "-%ds", Int(remaining.rounded()))
        } else {
            return String(format: "-%.1fs", remaining)
        }
    }
}
