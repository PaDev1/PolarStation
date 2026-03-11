import SwiftUI

/// Camera tab: live preview, capture sequences with file saving.
struct CameraTabView: View {
    @ObservedObject var viewModel: CameraViewModel

    // Camera settings (shared with SettingsView)
    @AppStorage("exposureMs") private var exposureMs: Double = 500
    @AppStorage("gain") private var gain: Double = 300
    @AppStorage("binning") private var binning: Int = 2

    // Capture settings (shared with SettingsView)
    @AppStorage("captureFolder") private var captureFolder: String = ""
    @AppStorage("captureFormat") private var captureFormat: String = "fits"
    @AppStorage("captureColorMode") private var captureColorMode: String = "rgb"
    @AppStorage("capturePrefix") private var capturePrefix: String = "capture"

    @State private var captureCount: Int = 1

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Top toolbar
            HStack(spacing: 12) {
                Picker("Camera", selection: $viewModel.selectedCameraIndex) {
                    Text("No camera").tag(-1)
                    ForEach(Array(viewModel.discoveredCameras.enumerated()), id: \.offset) { index, cam in
                        Text(cam.name).tag(index)
                    }
                }
                .frame(maxWidth: 250)

                Button(action: viewModel.discoverCameras) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Scan for cameras")

                Divider().frame(height: 20)

                if viewModel.isConnected {
                    Button("Disconnect") {
                        viewModel.disconnect()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("Connect") {
                        viewModel.connect()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.selectedCamera == nil)
                }

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
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "camera")
                            .font(.system(size: 48))
                            .foregroundStyle(.tertiary)
                        Text("Connect a camera to start")
                            .foregroundStyle(.secondary)
                    }
                }

                // Overlay: fps + star count + capture progress
                VStack {
                    HStack {
                        // Star detection info (top-left)
                        if viewModel.isCapturing && viewModel.starDetectionEnabled {
                            HStack(spacing: 6) {
                                Image(systemName: "star.fill")
                                    .foregroundStyle(.yellow)
                                    .font(.caption2)
                                Text("\(viewModel.detectedStars.count) stars")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.yellow)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        }

                        Spacer()

                        // FPS (top-right)
                        if viewModel.isCapturing {
                            Text(String(format: "%.1f fps", viewModel.previewViewModel.frameRate))
                                .font(.system(.caption, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.black.opacity(0.6))
                                .foregroundStyle(.green)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
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
                    .disabled(viewModel.selectedCamera == nil)
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
                        .disabled(viewModel.selectedCamera == nil || viewModel.isCapturing)

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
                Text(exposureMs >= 1000
                     ? String(format: "%.1f s", exposureMs / 1000)
                     : String(format: "%.0f ms", exposureMs))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(String(format: "G%.0f", gain))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("\(binning)x\(binning)")
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

                // Star detection toggle + status
                Divider().frame(height: 20)
                Toggle(isOn: $viewModel.starDetectionEnabled) {
                    HStack(spacing: 4) {
                        Image(systemName: viewModel.starDetectorModelLoaded ? "brain" : "brain.fill")
                            .foregroundStyle(viewModel.starDetectorModelLoaded ? .green : .red)
                        Text(viewModel.starDetectorModelLoaded ? "ML" : "No ML")
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help(viewModel.starDetectorStatus)

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
            viewModel.discoverCameras()
        }
    }

    // MARK: - Helpers

    private var currentSettings: CameraSettings {
        CameraSettings(
            exposureMs: exposureMs,
            gain: Int(gain),
            binning: binning
        )
    }

    private var captureFolderURL: URL {
        if captureFolder.isEmpty {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Pictures/PolarAligner")
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
        let totalSec = exposureMs * Double(captureCount) / 1000
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
        viewModel.startCaptureSequence(
            count: captureCount,
            settings: currentSettings,
            format: format,
            colorMode: colorMode,
            folder: captureFolderURL,
            prefix: capturePrefix.isEmpty ? "capture" : capturePrefix
        )
    }
}
