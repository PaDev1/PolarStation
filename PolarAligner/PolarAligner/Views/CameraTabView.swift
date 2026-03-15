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
                guideCamera.pauseLiveView()
            },
            switchCamera: { oldSource, newSource in
                let oldVM = oldSource == .main ? mainCamera : guideCamera
                oldVM.pauseLiveView()
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

    @State private var captureCount: Int = 1

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
                Picker("Source", selection: $selectedSource) {
                    ForEach(CameraViewSource.allCases, id: \.self) { source in
                        Text(source.rawValue).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)

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

                // Overlay: fps + capture progress
                VStack {
                    HStack {
                        Spacer()

                        // FPS + frame activity (top-right)
                        if viewModel.isCapturing {
                            FrameRateView(previewViewModel: viewModel.previewViewModel)
                        }
                    }
                    Spacer()
                    if viewModel.isSaving {
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
        }
        .onAppear {
            viewModel.resumeLiveView(settings: currentSettings)
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
