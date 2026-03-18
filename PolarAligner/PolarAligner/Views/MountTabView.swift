import SwiftUI
import PolarCore
import SwiftAA

struct MountTabView: View {
    @ObservedObject var mountService: MountService
    @ObservedObject var plateSolveService: PlateSolveService
    @Binding var sequenceDocument: SequenceDocument
    var onSwitchToSequencer: (() -> Void)?
    @ObservedObject var skyMapVM: SkyMapViewModel
    @ObservedObject var vm: MountTabViewModel
    @ObservedObject var centeringSolveService: CenteringSolveService
    @ObservedObject var cameraViewModel: CameraViewModel

    @AppStorage("observerLat") private var observerLat: Double = 60.17
    @AppStorage("observerLon") private var observerLon: Double = 24.94
    @AppStorage("focalLengthMM") private var focalLengthMM: Double = 200.0
    @AppStorage("pixelSizeMicrons") private var pixelSizeMicrons: Double = 2.9
    @AppStorage("sensorWidthPx") private var sensorWidthPx: Int = 1920
    @AppStorage("sensorHeightPx") private var sensorHeightPx: Int = 1080

    // GoTo inputs
    @State private var gotoRAText: String = "0.0"
    @State private var gotoDecText: String = "0.0"
    @State private var trackingRate: UInt8 = 0  // 0=sidereal

    // Manual control speed
    @State private var manualSpeed: ManualSpeed = .find
    @State private var mountError: String?

    // Plate solve
    @State private var solveStatus: String?
    @State private var isSolving = false

    // Remote plate solving
    @AppStorage("astrometryNetEnabled") private var astrometryNetEnabled: Bool = false
    @AppStorage("astrometryNetApiKey") private var astrometryNetApiKey: String = ""
    @AppStorage("astrometryNetLocalMode") private var astrometryNetLocalMode: Bool = false
    @AppStorage("astrometryNetLocalURL") private var astrometryNetLocalURL: String = "http://localhost:8080/api"

    private var astrometryBaseURL: String {
        astrometryNetLocalMode ? astrometryNetLocalURL : AstrometryNetService.remoteBaseURL
    }
    private var astrometryApiKey: String {
        astrometryNetLocalMode ? "local" : astrometryNetApiKey
    }

    // Ephemeral UI state
    @State private var showObsWindowPopover = false
    var assistantVM: AssistantViewModel
    var assistantWindowController: AssistantWindowController
    // Observation window (persisted via AppStorage)
    @AppStorage("obsWindowEnabled") private var obsWindowEnabled = false
    @AppStorage("obsWindowMinAlt") private var obsWindowMinAlt: Double = 10
    @AppStorage("obsWindowMaxAlt") private var obsWindowMaxAlt: Double = 90
    @AppStorage("obsWindowAzFrom") private var obsWindowAzFrom: Double = 0
    @AppStorage("obsWindowAzTo") private var obsWindowAzTo: Double = 360

    enum ManualSpeed: String, CaseIterable {
        case guide = "Guide"
        case center = "Center"
        case find = "Find"
        case slew = "Slew"

        var degPerSec: Double {
            switch self {
            case .guide:  return 0.008  // ~2x sidereal
            case .center: return 0.134  // ~32x sidereal
            case .find:   return 2.0
            case .slew:   return 8.0
            }
        }
    }

    var body: some View {
        HSplitView {
            // Left panel: controls
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    framingHeader

                    if !mountService.isConnected {
                        notConnectedView
                    } else {
                        positionDisplay
                        Divider()
                        trackingControls
                        Divider()
                        manualControlPad
                        Divider()
                        gotoControls
                        Divider()
                        parkControls

                        if let err = mountError {
                            Text(err)
                                .foregroundStyle(.red)
                                .font(.caption)
                        }
                    }
                }
                .padding()
            }
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)

            // Right panel: sky map + optional panels below
            if vm.showSolvePanel || vm.showCatalog {
                VSplitView {
                    ZStack(alignment: .topLeading) {
                        SkyMapView(viewModel: skyMapVM, onAskAI: askAIAboutTarget) { raHours, decDeg in
                            if vm.isLiveTime { gotoTarget(raHours: raHours, decDeg: decDeg) }
                        }
                        panelToggleButtons
                        // Planning mode indicator on map
                        if !vm.isLiveTime {
                            Text("Planning mode — GoTo disabled")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.orange.opacity(0.7))
                                .foregroundStyle(.white)
                                .cornerRadius(4)
                                .padding(.leading, 80)
                                .padding(.top, 6)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(minHeight: 200)

                    if vm.showSolvePanel {
                        solvePanel
                            .frame(minHeight: 120, idealHeight: 180)
                    }
                    if vm.showCatalog {
                        catalogPanel
                            .frame(minHeight: 150, idealHeight: 250)
                    }
                }
                .frame(minWidth: 400)
            } else {
                ZStack(alignment: .topLeading) {
                    SkyMapView(viewModel: skyMapVM, onAskAI: askAIAboutTarget) { raHours, decDeg in
                        gotoTarget(raHours: raHours, decDeg: decDeg)
                    }
                    panelToggleButtons
                }
                .frame(minWidth: 400)
            }
        }
        .onAppear {
            loadStarCatalog()
            updateCameraFOV()
            skyMapVM.observerLatDeg = observerLat
            skyMapVM.observerLonDeg = observerLon
            // Initialize map center to observer's latitude so the visible pole is near top
            if skyMapVM.mountRA == nil {
                skyMapVM.centerDec = observerLat
            }
        }
        .onChange(of: mountService.status) { oldStatus, newStatus in
            // Light polling returns NaN for altDeg/azDeg which breaks
            // Equatable (NaN != NaN), causing onChange to fire on every
            // poll even when nothing changed. Compare the fields we care about.
            if let old = oldStatus, let new = newStatus,
               old.raHours == new.raHours,
               old.decDeg == new.decDeg,
               old.tracking == new.tracking,
               old.slewing == new.slewing {
                return
            }
            skyMapVM.syncToMount(status: newStatus)
        }
        .onChange(of: centeringSolveService.lastSolveResult) { _, result in
            guard let result, result.success else { return }
            skyMapVM.solvedRA = result.raDeg
            skyMapVM.solvedDec = result.decDeg
            skyMapVM.solvedRollDeg = result.rollDeg
            skyMapVM.solvedFOVDeg = result.fovDeg
            // Re-center sky map at solved position so overlay is visible
            skyMapVM.followMount = false
            skyMapVM.centerMap(raDeg: result.raDeg, decDeg: result.decDeg)
        }
        .onChange(of: plateSolveService.isLoaded) { _, loaded in
            if loaded { loadStarCatalog() }
        }
        .onChange(of: focalLengthMM) { updateCameraFOV() }
        .onChange(of: observerLat) { skyMapVM.observerLatDeg = observerLat }
        .onChange(of: observerLon) { skyMapVM.observerLonDeg = observerLon }
        .onChange(of: vm.planningDate) {
            skyMapVM.referenceDate = vm.isLiveTime ? nil : vm.planningDate
            recomputeCatalog()
        }
        .onChange(of: vm.isLiveTime) {
            skyMapVM.referenceDate = vm.isLiveTime ? nil : vm.planningDate
            recomputeCatalog()
        }
        .onChange(of: vm.showCatalog) {
            if vm.showCatalog {
                recomputeCatalog()
            } else if !vm.isLiveTime {
                // Closing catalog reverts to live time
                vm.isLiveTime = true
                vm.planningDate = Date()
            }
        }
        .onChange(of: vm.catalogFilter) { recomputeCatalog() }
        .onChange(of: vm.catalogSearch) { recomputeCatalog() }
        .onChange(of: obsWindowEnabled) { recomputeCatalog() }
        .onChange(of: obsWindowMinAlt) { recomputeCatalog() }
        .onChange(of: obsWindowMaxAlt) { recomputeCatalog() }
        .onChange(of: obsWindowAzFrom) { recomputeCatalog() }
        .onChange(of: obsWindowAzTo) { recomputeCatalog() }
    }

    private var panelToggleButtons: some View {
        HStack(spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    vm.showSolvePanel.toggle()
                }
                // When closing the panel, clear solved overlay so FOV rect follows mount
                if vm.showSolvePanel {
                    skyMapVM.solvedRA = nil
                    skyMapVM.solvedDec = nil
                    skyMapVM.solvedRollDeg = nil
                    skyMapVM.solvedFOVDeg = nil
                }
            } label: {
                Image(systemName: vm.showSolvePanel ? "scope" : "dot.scope")
                    .font(.system(size: 16))
                    .padding(8)
                    .background(.black.opacity(0.6))
                    .clipShape(Circle())
                    .foregroundStyle(vm.showSolvePanel ? .green : .white)
            }
            .buttonStyle(.plain)
            .help("Toggle center & solve panel")

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    vm.showCatalog.toggle()
                }
            } label: {
                Image(systemName: vm.showCatalog ? "list.bullet.circle.fill" : "list.bullet.circle")
                    .font(.system(size: 16))
                    .padding(8)
                    .background(.black.opacity(0.6))
                    .clipShape(Circle())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help("Toggle object catalog")
        }
        .padding(8)
    }

    // MARK: - Center & Solve Panel

    private var solvePanel: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                // Status line
                HStack(spacing: 6) {
                    switch centeringSolveService.state {
                    case .idle:
                        Image(systemName: "scope")
                            .foregroundStyle(.secondary)
                    case .solving:
                        ProgressView().controlSize(.small)
                    case .centering(let attempt):
                        ProgressView().controlSize(.small)
                        Text("Attempt \(attempt)/\(centeringSolveService.maxAttempts)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .converged:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failed:
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                    Text(centeringSolveService.statusMessage)
                        .font(.system(size: 11))
                        .lineLimit(2)
                        .foregroundStyle(solvePanelTextColor)
                    Spacer()
                }

                // Action buttons
                HStack(spacing: 8) {
                    Button("Solve") {
                        Task {
                            await centeringSolveService.solveOnce(stars: cameraViewModel.detectedStars)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(centeringSolveService.state.isActive)
                    .help("One-shot plate solve — updates sky map FOV overlay")

                    Button("Center") {
                        guard let target = currentGoToTarget else { return }
                        centeringSolveService.centerOnTarget(
                            targetRAHours: target.raHours,
                            targetDecDeg: target.decDeg,
                            starProvider: { [weak cameraViewModel] in
                                cameraViewModel?.detectedStars ?? []
                            }
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(centeringSolveService.state.isActive || !mountService.isConnected || currentGoToTarget == nil)
                    .help(currentGoToTarget == nil ? "Enter target coordinates or select from catalog first" : "Iterative plate-solve centering on target")

                    if centeringSolveService.state.isActive {
                        Button("Stop") {
                            centeringSolveService.cancel()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.red)
                    }

                    Spacer()

                    // Tolerance & attempts
                    HStack(spacing: 4) {
                        Text("Tol:")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        TextField("", value: $centeringSolveService.toleranceArcmin, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 40)
                            .font(.system(size: 11))
                        Text("′")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 4) {
                        Text("Max:")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        TextField("", value: $centeringSolveService.maxAttempts, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 30)
                            .font(.system(size: 11))
                    }
                }

                // Remote solve buttons (shown when Astrometry.net is configured)
                if astrometryNetEnabled {
                    HStack(spacing: 8) {
                        Image(systemName: "network")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 10))
                        Button("Solve (remote)") {
                            Task {
                                guard let jpeg = cameraViewModel.currentFrameJPEG() else {
                                    centeringSolveService.statusMessage = "No camera frame — connect camera and start preview"
                                    return
                                }
                                if cameraViewModel.detectedStars.isEmpty {
                                    centeringSolveService.statusMessage = "No stars detected locally — image may be dark or out of focus. Submitting anyway..."
                                }
                                await centeringSolveService.solveOnceRemote(
                                    jpegData: jpeg,
                                    apiKey: astrometryApiKey,
                                    baseURL: astrometryBaseURL
                                )
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(centeringSolveService.state.isActive)
                        .help("One-shot solve via Astrometry.net — slower but works without local star detection")

                        Button("Center (remote)") {
                            guard let target = currentGoToTarget else { return }
                            centeringSolveService.centerOnTargetRemote(
                                targetRAHours: target.raHours,
                                targetDecDeg: target.decDeg,
                                frameProvider: { [weak cameraViewModel] in
                                    cameraViewModel?.currentFrameJPEG()
                                },
                                apiKey: astrometryApiKey,
                                baseURL: astrometryBaseURL
                            )
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(centeringSolveService.state.isActive || !mountService.isConnected || currentGoToTarget == nil)
                        .help(currentGoToTarget == nil ? "Select a target first" : "Iterative centering using remote Astrometry.net solver")

                        Spacer()

                        Text(astrometryNetLocalMode ? "Local" : "nova.astrometry.net")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }

                // Simulation button — always available if catalog loaded and mount connected
                if mountService.isConnected && plateSolveService.isLoaded {
                    HStack(spacing: 8) {
                        Image(systemName: "wand.and.stars")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 10))
                        Button("Simulate Solve") {
                            guard let status = mountService.status else { return }
                            Task {
                                await centeringSolveService.simulateSolve(
                                    mountRADeg: status.raHours * 15.0,
                                    mountDecDeg: status.decDeg,
                                    fovDeg: plateSolveService.fovDeg,
                                    imageWidth: Int(plateSolveService.imageWidth),
                                    imageHeight: Int(plateSolveService.imageHeight)
                                )
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(centeringSolveService.state.isActive)
                        .help("Generate a synthetic star field at the mount's reported position and solve it — validates solver config without a real camera image")

                        Spacer()

                        Text("Simulates at mount position")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }

                // Results
                if let result = centeringSolveService.lastSolveResult, result.success {
                    Divider()
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                        GridRow {
                            Text("Solved").foregroundStyle(.secondary)
                            Text(String(format: "RA %.4fh  Dec %+.3f°", result.raDeg / 15.0, result.decDeg))
                        }
                        if let offset = centeringSolveService.lastOffsetArcmin,
                           let raOff = centeringSolveService.lastRAOffsetArcmin,
                           let decOff = centeringSolveService.lastDecOffsetArcmin {
                            GridRow {
                                Text("Offset").foregroundStyle(.secondary)
                                Text(String(format: "%.1f′  (RA %+.1f′  Dec %+.1f′)", offset, raOff, decOff))
                                    .foregroundStyle(offset < centeringSolveService.toleranceArcmin ? .green : .orange)
                            }
                        }
                        GridRow {
                            Text("Rotation").foregroundStyle(.secondary)
                            Text(String(format: "%.1f°", result.rollDeg))
                        }
                        GridRow {
                            Text("FOV").foregroundStyle(.secondary)
                            Text(String(format: "%.2f°  •  %d stars  •  %.0fms", result.fovDeg, result.matchedStars, result.solveTimeMs))
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                }
            }
            .padding(10)
        }
    }

    private var solvePanelTextColor: Color {
        switch centeringSolveService.state {
        case .converged: return .green
        case .failed: return .red
        case .solving, .centering: return .primary
        case .idle: return .secondary
        }
    }

    /// Current GoTo target from the text fields (used by Center button).
    private var currentGoToTarget: (raHours: Double, decDeg: Double)? {
        guard let ra = Double(gotoRAText), let dec = Double(gotoDecText),
              ra > 0 || dec != 0 else { return nil }
        return (ra, dec)
    }

    // MARK: - Not Connected

    private var notConnectedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Mount not connected")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Go to Settings to connect your mount via ASCOM Alpaca or LX200 serial.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Header

    private var framingHeader: some View {
        HStack {
            Text("Framing & Mount")
                .font(.title)
            Spacer()
            Button {
                vm.showAssistant.toggle()
                assistantWindowController.toggle(
                    viewModel: assistantVM,
                    showBinding: Binding(
                        get: { vm.showAssistant },
                        set: { vm.showAssistant = $0 }
                    )
                )
            } label: {
                Image(systemName: "sparkles")
                    .font(.system(size: 14))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(vm.showAssistant ? .purple : nil)
            .help("AI Assistant")
        }
    }

    // MARK: - Position Display

    private var positionDisplay: some View {
        GroupBox("Position") {
            VStack(alignment: .leading, spacing: 6) {
                if let s = mountService.status {
                    HStack {
                        Text("RA").frame(width: 30, alignment: .trailing).foregroundStyle(.secondary)
                        Text(formatRA(s.raHours))
                            .font(.system(.body, design: .monospaced))
                    }
                    HStack {
                        Text("Dec").frame(width: 30, alignment: .trailing).foregroundStyle(.secondary)
                        Text(formatDec(s.decDeg))
                            .font(.system(.body, design: .monospaced))
                    }

                    // Alt/Az read directly from mount
                    HStack {
                        Text("Alt").frame(width: 30, alignment: .trailing).foregroundStyle(.secondary)
                        Text(String(format: "%+.2f°", s.altDeg))
                            .font(.system(.body, design: .monospaced))
                        Text("Az").foregroundStyle(.secondary)
                        Text(String(format: "%.2f°", s.azDeg))
                            .font(.system(.body, design: .monospaced))
                    }

                    HStack(spacing: 12) {
                        statusBadge(s.tracking ? "Tracking" : "Idle", color: s.tracking ? .green : .gray)
                        if s.slewing { statusBadge("Slewing", color: .orange) }
                        if s.atPark { statusBadge("Parked", color: .blue) }
                    }
                } else {
                    Text("Waiting for status...")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Tracking Controls

    private var trackingControls: some View {
        GroupBox("Tracking") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle("Tracking", isOn: Binding(
                        get: { mountService.status?.tracking ?? false },
                        set: { enabled in
                            Task {
                                do {
                                    try await mountService.setTracking(enabled)
                                    mountError = nil
                                } catch { mountError = error.localizedDescription }
                            }
                        }
                    ))

                    Spacer()

                    Button("Stop") {
                        Task {
                            do {
                                try await mountService.abort()
                                mountError = nil
                            } catch { mountError = error.localizedDescription }
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }

                Picker("Rate", selection: $trackingRate) {
                    Text("Sidereal").tag(UInt8(0))
                    Text("Lunar").tag(UInt8(1))
                    Text("Solar").tag(UInt8(2))
                    Text("King").tag(UInt8(3))
                }
                .pickerStyle(.menu)
                .onChange(of: trackingRate) { _, newRate in
                    Task {
                        do {
                            try await mountService.setTrackingRate(newRate)
                            mountError = nil
                        } catch { mountError = error.localizedDescription }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Manual NSEW Control Pad

    private var manualControlPad: some View {
        GroupBox("Manual Control") {
            VStack(spacing: 8) {
                Picker("Speed", selection: $manualSpeed) {
                    ForEach(ManualSpeed.allCases, id: \.self) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
                .pickerStyle(.menu)

                // NSEW pad
                VStack(spacing: 4) {
                    // North
                    HStack {
                        Spacer()
                        MoveButton(label: "N", systemImage: "chevron.up",
                                   maxRate: manualSpeed.degPerSec) { rate in
                            moveAxis(axis: 1, rate: rate)
                        }
                        Spacer()
                    }

                    // West - Stop - East
                    HStack(spacing: 4) {
                        Spacer()
                        MoveButton(label: "W", systemImage: "chevron.left",
                                   maxRate: -manualSpeed.degPerSec) { rate in
                            moveAxis(axis: 0, rate: rate)
                        }

                        Button(action: {
                            Task {
                                do {
                                    try await mountService.abort()
                                    mountError = nil
                                } catch { mountError = error.localizedDescription }
                            }
                        }) {
                            Image(systemName: "stop.fill")
                                .frame(width: 40, height: 40)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)

                        MoveButton(label: "E", systemImage: "chevron.right",
                                   maxRate: manualSpeed.degPerSec) { rate in
                            moveAxis(axis: 0, rate: rate)
                        }
                        Spacer()
                    }

                    // South
                    HStack {
                        Spacer()
                        MoveButton(label: "S", systemImage: "chevron.down",
                                   maxRate: -manualSpeed.degPerSec) { rate in
                            moveAxis(axis: 1, rate: rate)
                        }
                        Spacer()
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - GoTo Controls

    private var gotoControls: some View {
        GroupBox("GoTo") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("RA (h)")
                        .frame(width: 50, alignment: .trailing)
                    TextField("0.000", text: $gotoRAText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
                HStack {
                    Text("Dec (°)")
                        .frame(width: 50, alignment: .trailing)
                    TextField("0.000", text: $gotoDecText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }

                HStack(spacing: 8) {
                    Button("GoTo") {
                        guard let ra = Double(gotoRAText), let dec = Double(gotoDecText) else { return }
                        gotoTarget(raHours: ra, decDeg: dec)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!mountService.isConnected)

                    // Quick targets
                    Menu("Quick Targets") {
                        Button("Polaris (RA 2.53h Dec +89.26°)") {
                            gotoTarget(raHours: 2.53, decDeg: 89.26)
                        }
                        Divider()
                        ForEach(messierCatalog.prefix(20)) { obj in
                            Button("\(obj.id) \(obj.name) (mag \(String(format: "%.1f", obj.magnitude)))") {
                                gotoTarget(raHours: obj.raHours, decDeg: obj.decDeg)
                            }
                        }
                    }
                }

                if let status = solveStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Park Controls

    private var parkControls: some View {
        GroupBox("Park / Home") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Button("Go Home") {
                        Task {
                            do {
                                try await mountService.findHome()
                                mountError = nil
                            } catch { mountError = error.localizedDescription }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Alpaca: find home position. LX200: GoTo Polaris.")

                    Button("Unpark") {
                        Task {
                            do {
                                try await mountService.unpark()
                                mountError = nil
                            } catch { mountError = error.localizedDescription }
                        }
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button("Park") {
                        Task {
                            do {
                                try await mountService.park()
                                mountError = nil
                            } catch { mountError = error.localizedDescription }
                        }
                    }
                    .buttonStyle(.bordered)
                    .help("Park mount (west-facing position)")
                }

                Text("Home = Polaris  •  Park = west position")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Catalog Panel

    private var catalogPanel: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                if vm.isCatalogLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                }
                TextField("Search objects...", text: $vm.catalogSearch)
                    .textFieldStyle(.plain)

                Divider()
                    .frame(height: 16)

                // Date/time picker for planning
                if vm.isLiveTime {
                    Button {
                        vm.planningDate = Date()
                        vm.isLiveTime = false
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "clock")
                            Text("Now")
                        }
                        .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Switch to planning mode to view a different date/time")
                } else {
                    DatePicker("", selection: $vm.planningDate)
                        .labelsHidden()
                        .frame(width: 170)

                    Button {
                        vm.isLiveTime = true
                        vm.planningDate = Date()
                    } label: {
                        Image(systemName: "clock.badge.checkmark")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.orange)
                    .help("Return to live time")
                }

                Divider()
                    .frame(height: 16)

                // Observation window
                Button {
                    showObsWindowPopover.toggle()
                } label: {
                    Image(systemName: obsWindowEnabled ? "camera.viewfinder" : "viewfinder")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(obsWindowEnabled ? .cyan : nil)
                .help("Observation window — limit by altitude and azimuth")
                .popover(isPresented: $showObsWindowPopover) {
                    observationWindowPopover
                }

                Picker("", selection: $vm.catalogFilter) {
                    ForEach(MountTabViewModel.CatalogFilter.allCases, id: \.self) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 120)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(vm.isLiveTime ? Color(nsColor: .controlBackgroundColor) : Color.orange.opacity(0.08))

            if vm.isCatalogLoading && vm.cachedCatalogEntries.isEmpty {
                VStack {
                    Spacer()
                    ProgressView("Computing catalog...")
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }

            List(vm.cachedCatalogEntries, id: \.id) { entry in
                HStack(spacing: 8) {
                    // Type indicator
                    Circle()
                        .fill(entry.color)
                        .frame(width: 8, height: 8)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                            .font(.system(size: 12, weight: .medium))
                        Text(entry.detail)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    // Altitude sparkline
                    AltitudeSparkline(
                        visibility: entry.visibility, color: entry.color,
                        referenceDate: vm.catalogReferenceDate,
                        obsWindow: obsWindowEnabled ? (minAlt: obsWindowMinAlt, maxAlt: obsWindowMaxAlt, azFrom: obsWindowAzFrom, azTo: obsWindowAzTo) : nil
                    )
                        .frame(width: 110, height: 30)

                    // Visibility summary
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "Alt %+.1f°  Az %.0f°", entry.altDeg, entry.azDeg))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(entry.altDeg > 0 ? .green : .red)
                        Text(vm.visibilitySummary(entry.visibility))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    HStack(spacing: 4) {
                        Button("GoTo") {
                            gotoTarget(raHours: entry.raHours, decDeg: entry.decDeg)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!mountService.isConnected || !vm.isLiveTime || entry.altDeg <= 0)

                        Button {
                            centerOnObject(raHours: entry.raHours, decDeg: entry.decDeg)
                        } label: {
                            Image(systemName: "scope")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Center map on object")

                        Button {
                            addToSequencer(entry: entry)
                        } label: {
                            Image(systemName: "text.badge.plus")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(obsWindowEnabled && !entry.visibility.isVisibleInWindow(
                            minAlt: obsWindowMinAlt, maxAlt: obsWindowMaxAlt,
                            azFrom: obsWindowAzFrom, azTo: obsWindowAzTo
                        ))
                        .help(obsWindowEnabled && !entry.visibility.isVisibleInWindow(
                            minAlt: obsWindowMinAlt, maxAlt: obsWindowMaxAlt,
                            azFrom: obsWindowAzFrom, azTo: obsWindowAzTo
                        ) ? "No observable time in window" : "Add to sequencer")
                    }
                }
                .padding(.vertical, 4)
            }
            .listStyle(.plain)
        }
    }

    // Types are defined in MountTabViewModel

    /// Trigger async catalog recomputation via the view model.
    private func recomputeCatalog() {
        vm.recomputeCatalog(
            observerLat: observerLat,
            observerLon: observerLon,
            obsWindowEnabled: obsWindowEnabled,
            obsWindowMinAlt: obsWindowMinAlt,
            obsWindowMaxAlt: obsWindowMaxAlt,
            obsWindowAzFrom: obsWindowAzFrom,
            obsWindowAzTo: obsWindowAzTo
        )
    }

    private func addToSequencer(entry: MountTabViewModel.CatalogEntry) {
        let target = TargetInfo(
            name: entry.name,
            ra: entry.raHours,
            dec: entry.decDeg,
            trackingRate: trackingRateFor(entry.category)
        )

        var items = defaultInstructions(for: entry.category)
        var conditions: [SequenceCondition] = []

        // When observation window is active, add timing constraints
        if obsWindowEnabled,
           let interval = entry.visibility.windowInterval(
               minAlt: obsWindowMinAlt, maxAlt: obsWindowMaxAlt, azFrom: obsWindowAzFrom, azTo: obsWindowAzTo
           ) {
            let refDate = vm.catalogReferenceDate

            // Wait until the object enters the window
            if interval.start > 0.1 {
                let startDate = refDate.addingTimeInterval(interval.start * 3600)
                let cal = Calendar.current
                let startHour = cal.component(.hour, from: startDate)
                let startMinute = cal.component(.minute, from: startDate)
                items.insert(.instruction(SequenceInstruction(
                    type: SequenceInstruction.waitUntilLocalTime,
                    params: ["hour": .int(startHour), "minute": .int(startMinute)]
                )), at: 0)
            }

            // Stop looping when the object leaves the window
            let endDate = refDate.addingTimeInterval(interval.end * 3600)
            let cal = Calendar.current
            let endHour = cal.component(.hour, from: endDate)
            let endMinute = cal.component(.minute, from: endDate)
            conditions.append(SequenceCondition(
                type: SequenceCondition.loopUntilLocalTime,
                params: ["hour": .int(endHour), "minute": .int(endMinute)]
            ))
        }

        let container = SequenceContainer(
            name: entry.name,
            type: .deepSkyObject,
            target: target,
            items: items,
            conditions: conditions
        )

        sequenceDocument.rootContainer.items.append(.container(container))
        onSwitchToSequencer?()
    }

    private func trackingRateFor(_ category: MountTabViewModel.CatalogCategory) -> TrackingRate? {
        switch category {
        case .deepSky: return nil  // sidereal (default)
        case .planet: return nil   // sidereal — planetary imaging uses ms exposures, drift is negligible
        case .moon: return .lunar
        case .sun: return .solar
        }
    }

    /// Create default instruction set based on object category.
    private func defaultInstructions(for category: MountTabViewModel.CatalogCategory) -> [SequenceItem] {
        var items: [SequenceItem] = []

        // Slew to target
        items.append(.instruction(SequenceInstruction(
            type: SequenceInstruction.slewToTarget,
            deviceRole: "mount"
        )))

        // Set tracking rate (always — uses target's trackingRate)
        items.append(.instruction(SequenceInstruction(
            type: SequenceInstruction.startTracking,
            deviceRole: "mount"
        )))

        switch category {
        case .deepSky:
            // DSO: center target, start guiding, capture
            items.append(.instruction(SequenceInstruction(
                type: SequenceInstruction.centerTarget,
                deviceRole: "mount",
                params: ["attempts": .int(3)]
            )))
            items.append(.instruction(SequenceInstruction(
                type: SequenceInstruction.startGuiding,
                deviceRole: "guide_camera"
            )))
            items.append(.instruction(SequenceInstruction(
                type: SequenceInstruction.captureFrames,
                deviceRole: "imaging_camera",
                params: [
                    "exposure_sec": .double(120),
                    "count": .int(10),
                    "dither_enabled": .bool(true),
                    "dither_every_n": .int(3),
                    "dither_pixels": .double(5.0)
                ]
            )))
            items.append(.instruction(SequenceInstruction(
                type: SequenceInstruction.stopGuiding,
                deviceRole: "guide_camera"
            )))

        case .planet:
            // Planets: short exposures, no guiding needed
            items.append(.instruction(SequenceInstruction(
                type: SequenceInstruction.captureFrames,
                deviceRole: "imaging_camera",
                params: [
                    "exposure_sec": .double(0.05),
                    "count": .int(1000),
                    "frame_type": .string("Light")
                ]
            )))

        case .moon:
            // Moon: short exposures, lunar tracking
            items.append(.instruction(SequenceInstruction(
                type: SequenceInstruction.captureFrames,
                deviceRole: "imaging_camera",
                params: [
                    "exposure_sec": .double(0.01),
                    "count": .int(500),
                    "frame_type": .string("Light")
                ]
            )))

        case .sun:
            // Sun: very short exposures, solar tracking, solar filter assumed
            items.append(.instruction(SequenceInstruction(
                type: SequenceInstruction.captureFrames,
                deviceRole: "imaging_camera",
                params: [
                    "exposure_sec": .double(0.001),
                    "count": .int(500),
                    "frame_type": .string("Light")
                ]
            )))
        }

        return items
    }

    // MARK: - Observation Window Popover

    private var observationWindowPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Observation Window", isOn: $obsWindowEnabled)
                .font(.headline)

            if obsWindowEnabled {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Min altitude")
                                .frame(width: 90, alignment: .trailing)
                            Slider(value: $obsWindowMinAlt, in: 0...60, step: 5)
                                .frame(width: 120)
                            Text(String(format: "%.0f°", obsWindowMinAlt))
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 30)
                        }

                        HStack {
                            Text("Max altitude")
                                .frame(width: 90, alignment: .trailing)
                            Slider(value: $obsWindowMaxAlt, in: 10...90, step: 5)
                                .frame(width: 120)
                            Text(String(format: "%.0f°", obsWindowMaxAlt))
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 30)
                        }

                        HStack {
                            Text("Azimuth from")
                                .frame(width: 90, alignment: .trailing)
                            Slider(value: $obsWindowAzFrom, in: 0...359, step: 5)
                                .frame(width: 120)
                            Text(String(format: "%.0f°", obsWindowAzFrom))
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 30)
                        }

                        HStack {
                            Text("Azimuth to")
                                .frame(width: 90, alignment: .trailing)
                            Slider(value: $obsWindowAzTo, in: 0...360, step: 5)
                                .frame(width: 120)
                            Text(String(format: "%.0f°", obsWindowAzTo))
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 30)
                        }

                        // Compass reference
                        HStack(spacing: 0) {
                            Spacer()
                            Text("N=0°  E=90°  S=180°  W=270°")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }

                        // Summary
                        Text(obsWindowSummary)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
        .frame(width: 320)
    }

    private var obsWindowSummary: String {
        let altStr = obsWindowMaxAlt < 90
            ? String(format: "%.0f°–%.0f° altitude", obsWindowMinAlt, obsWindowMaxAlt)
            : String(format: "Above %.0f°", obsWindowMinAlt)
        if obsWindowAzFrom == 0 && obsWindowAzTo == 360 {
            return "\(altStr), all directions"
        }
        let dirs = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        func dirName(_ az: Double) -> String {
            let idx = Int((az + 22.5).truncatingRemainder(dividingBy: 360) / 45.0)
            return dirs[idx % 8]
        }
        return "\(altStr), \(dirName(obsWindowAzFrom)) → \(dirName(obsWindowAzTo))"
    }

    private func centerOnObject(raHours: Double, decDeg: Double) {
        skyMapVM.followMount = false
        skyMapVM.centerMap(raDeg: raHours * 15.0, decDeg: decDeg)
    }

    // MARK: - Helpers

    private func statusBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func formatRA(_ hours: Double) -> String {
        let h = Int(hours)
        let minTotal = (hours - Double(h)) * 60.0
        let m = Int(minTotal)
        let s = (minTotal - Double(m)) * 60.0
        return String(format: "%02dh %02dm %05.2fs", h, m, s)
    }

    private func formatDec(_ deg: Double) -> String {
        let sign = deg >= 0 ? "+" : "-"
        let absDeg = abs(deg)
        let d = Int(absDeg)
        let minTotal = (absDeg - Double(d)) * 60.0
        let m = Int(minTotal)
        let s = (minTotal - Double(m)) * 60.0
        return String(format: "%@%02d° %02d' %04.1f\"", sign, d, m, s)
    }

    private func askAIAboutTarget(name: String, raHours: Double, decDeg: Double) {
        let binding = Binding(get: { vm.showAssistant }, set: { vm.showAssistant = $0 })
        assistantWindowController.show(viewModel: assistantVM, showBinding: binding)
        assistantVM.askAboutTarget(name: name, raHours: raHours, decDeg: decDeg)
    }

    private func gotoTarget(raHours: Double, decDeg: Double) {
        guard mountService.isConnected else { return }
        gotoRAText = String(format: "%.4f", raHours)
        gotoDecText = String(format: "%.4f", decDeg)
        Task {
            do {
                try await mountService.gotoRADec(raHours: raHours, decDeg: decDeg)
                mountError = nil
            } catch {
                mountError = error.localizedDescription
            }
        }
    }

    private func moveAxis(axis: UInt8, rate: Double) {
        Task {
            do {
                try await mountService.moveAxis(axis, rateDegPerSec: rate)
                mountError = nil
            } catch {
                mountError = error.localizedDescription
            }
        }
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

    private func updateCameraFOV() {
        let arcsecPerPix = pixelSizeMicrons * 206.265 / focalLengthMM
        let w = max(Double(cameraViewModel.captureWidth), Double(sensorWidthPx))
        let h = max(Double(cameraViewModel.captureHeight), Double(sensorHeightPx))
        let fov = arcsecPerPix * w / 3600.0
        skyMapVM.cameraFOVDeg = fov
        skyMapVM.sensorAspect = w / h
    }
}

// MARK: - Move Button (press-and-hold with progressive speed ramp)

struct MoveButton: View {
    let label: String
    let systemImage: String
    let maxRate: Double           // signed: positive or negative direction
    let onMove: (Double) -> Void  // called with current rate (0 = stop)

    @State private var isPressed = false
    @State private var pressStart: Date?
    @State private var rampTimer: Timer?
    @State private var rampProgress: Double = 0  // 0–1 for visual feedback

    private let minRate: Double = 0.004   // ~1x sidereal
    private let rampDuration: Double = 2.5 // seconds to reach max speed
    private let tickInterval: Double = 0.15

    var body: some View {
        Image(systemName: systemImage)
            .font(.title2)
            .frame(width: 40, height: 40)
            .background(isPressed
                ? Color.accentColor.opacity(0.15 + 0.45 * rampProgress)
                : Color.secondary.opacity(0.15))
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isPressed {
                            isPressed = true
                            startRamp()
                        }
                    }
                    .onEnded { _ in
                        stopRamp()
                        isPressed = false
                    }
            )
            .help(label)
    }

    private func computeRate(elapsed: TimeInterval) -> Double {
        let absMax = abs(maxRate)
        guard absMax > minRate else {
            return maxRate // no ramp if max is already at/below minimum
        }
        let t = min(elapsed / rampDuration, 1.0)
        let absRate = minRate + (absMax - minRate) * t * t // quadratic ramp
        return maxRate >= 0 ? absRate : -absRate
    }

    private func startRamp() {
        pressStart = Date()
        rampProgress = 0
        // Start immediately at minimum rate
        onMove(maxRate >= 0 ? minRate : -minRate)
        rampTimer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { _ in
            guard let start = pressStart else { return }
            let elapsed = Date().timeIntervalSince(start)
            let t = min(elapsed / rampDuration, 1.0)
            rampProgress = t
            onMove(computeRate(elapsed: elapsed))
        }
    }

    private func stopRamp() {
        rampTimer?.invalidate()
        rampTimer = nil
        pressStart = nil
        rampProgress = 0
        onMove(0)
    }
}

// MARK: - Altitude Sparkline

/// Tiny altitude-over-time chart for catalog entries.
/// Dark sky periods shaded, solid line above horizon, dashed below.
private struct AltitudeSparkline: View {
    let visibility: MountTabViewModel.VisibilityInfo
    let color: Color
    var referenceDate: Date = Date()
    var obsWindow: (minAlt: Double, maxAlt: Double, azFrom: Double, azTo: Double)?

    var body: some View {
        Canvas { context, size in
            let samples = visibility.altitudeSamples
            let sunSamples = visibility.sunAltSamples
            guard samples.count > 1 else { return }

            let w = size.width
            let h = size.height
            let n = CGFloat(samples.count - 1)
            let maxAlt = max(visibility.peakAltDeg, 10)
            let minAlt = min(samples.min() ?? 0, -5)
            let range = maxAlt - minAlt

            func yFor(_ alt: Double) -> CGFloat {
                h * (1.0 - (alt - minAlt) / range)
            }
            func xFor(_ i: Int) -> CGFloat {
                w * CGFloat(i) / n
            }

            // --- Dark sky background (sun < -18°, astronomical night) ---
            // Find dark intervals and draw shaded rectangles
            if sunSamples.count == samples.count {
                var darkStart: Int?
                for i in 0...samples.count {
                    let isDark = i < samples.count && sunSamples[i] < -18
                    if isDark && darkStart == nil {
                        darkStart = i
                    } else if !isDark, let start = darkStart {
                        // Draw dark region from start to i-1
                        let x0 = xFor(start)
                        let x1 = xFor(i - 1)
                        let rect = CGRect(x: x0, y: 0, width: x1 - x0, height: h)
                        context.fill(Path(rect), with: .color(.indigo.opacity(0.2)))
                        darkStart = nil
                    }
                }

                // Twilight zones (sun between -18° and -6°): lighter shade
                var twilightStart: Int?
                for i in 0...samples.count {
                    let isTwilight = i < samples.count && sunSamples[i] >= -18 && sunSamples[i] < -6
                    if isTwilight && twilightStart == nil {
                        twilightStart = i
                    } else if !isTwilight, let start = twilightStart {
                        let x0 = xFor(start)
                        let x1 = xFor(i - 1)
                        let rect = CGRect(x: x0, y: 0, width: x1 - x0, height: h)
                        context.fill(Path(rect), with: .color(.blue.opacity(0.08)))
                        twilightStart = nil
                    }
                }
            }

            // --- Observation window: green fill for in-window periods ---
            if let win = obsWindow {
                let azSamples = visibility.azimuthSamples

                // Min altitude line
                let effectiveMinAlt = max(win.minAlt, 0)
                if effectiveMinAlt > minAlt && effectiveMinAlt < maxAlt {
                    let minAltY = yFor(effectiveMinAlt)
                    var minAltPath = Path()
                    minAltPath.move(to: CGPoint(x: 0, y: minAltY))
                    minAltPath.addLine(to: CGPoint(x: w, y: minAltY))
                    context.stroke(minAltPath, with: .color(.green.opacity(0.3)),
                                  style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                }

                // Max altitude line
                if win.maxAlt < 90 && win.maxAlt > minAlt && win.maxAlt < maxAlt {
                    let maxAltY = yFor(win.maxAlt)
                    var maxAltPath = Path()
                    maxAltPath.move(to: CGPoint(x: 0, y: maxAltY))
                    maxAltPath.addLine(to: CGPoint(x: w, y: maxAltY))
                    context.stroke(maxAltPath, with: .color(.green.opacity(0.3)),
                                  style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                }

                func inWindow(_ az: Double) -> Bool {
                    if win.azFrom <= win.azTo {
                        return az >= win.azFrom && az <= win.azTo
                    } else {
                        return az >= win.azFrom || az <= win.azTo
                    }
                }

                // Green filled area under the curve where object is in the window
                var greenPath = Path()
                var greenStarted = false
                let floorY = yFor(effectiveMinAlt)
                for i in 0..<samples.count {
                    let x = xFor(i)
                    let isDark = i < sunSamples.count && sunSamples[i] < -18
                    let isIn = isDark && samples[i] >= win.minAlt && samples[i] <= win.maxAlt && inWindow(azSamples[i])
                    if isIn {
                        let y = yFor(samples[i])
                        if !greenStarted {
                            greenPath.move(to: CGPoint(x: x, y: floorY))
                            greenPath.addLine(to: CGPoint(x: x, y: y))
                            greenStarted = true
                        } else {
                            greenPath.addLine(to: CGPoint(x: x, y: y))
                        }
                    } else if greenStarted {
                        greenPath.addLine(to: CGPoint(x: xFor(i - 1), y: floorY))
                        greenPath.closeSubpath()
                        greenStarted = false
                    }
                }
                if greenStarted {
                    greenPath.addLine(to: CGPoint(x: xFor(samples.count - 1), y: floorY))
                    greenPath.closeSubpath()
                }
                context.fill(greenPath, with: .color(.green.opacity(0.18)))
            }

            // --- Horizon line (alt = 0) ---
            let horizonY = yFor(0)
            var horizPath = Path()
            horizPath.move(to: CGPoint(x: 0, y: horizonY))
            horizPath.addLine(to: CGPoint(x: w, y: horizonY))
            context.stroke(horizPath, with: .color(.white.opacity(0.2)), lineWidth: 0.5)

            // --- Fill under the above-horizon curve ---
            var fillPath = Path()
            var fillStarted = false
            for i in 0..<samples.count {
                let x = xFor(i)
                let alt = max(samples[i], 0)
                let y = yFor(alt)
                if samples[i] > 0 {
                    if !fillStarted {
                        fillPath.move(to: CGPoint(x: x, y: horizonY))
                        fillPath.addLine(to: CGPoint(x: x, y: y))
                        fillStarted = true
                    } else {
                        fillPath.addLine(to: CGPoint(x: x, y: y))
                    }
                } else if fillStarted {
                    fillPath.addLine(to: CGPoint(x: x, y: horizonY))
                    fillPath.closeSubpath()
                    fillStarted = false
                }
            }
            if fillStarted {
                fillPath.addLine(to: CGPoint(x: xFor(samples.count - 1), y: horizonY))
                fillPath.closeSubpath()
            }
            context.fill(fillPath, with: .color(color.opacity(0.12)))

            // --- Altitude curve ---
            var curvePath = Path()
            for i in 0..<samples.count {
                let x = xFor(i)
                let y = yFor(samples[i])
                if i == 0 { curvePath.move(to: CGPoint(x: x, y: y)) }
                else { curvePath.addLine(to: CGPoint(x: x, y: y)) }
            }

            // Below-horizon portions dashed, above solid — draw full curve then clip
            // Simple approach: draw dashed for all, then overdraw solid for above parts
            context.stroke(curvePath, with: .color(color.opacity(0.25)),
                          style: StrokeStyle(lineWidth: 1.0, dash: [2, 2]))

            // Solid segments where above horizon
            var solidPath = Path()
            var solidStarted = false
            for i in 0..<samples.count {
                let x = xFor(i)
                let y = yFor(samples[i])
                if samples[i] > 0 {
                    if !solidStarted { solidPath.move(to: CGPoint(x: x, y: y)); solidStarted = true }
                    else { solidPath.addLine(to: CGPoint(x: x, y: y)) }
                } else {
                    solidStarted = false
                }
            }
            context.stroke(solidPath, with: .color(color), lineWidth: 1.5)

            // --- "Now" marker ---
            let nowY = yFor(samples[0])
            let dotRect = CGRect(x: 0, y: nowY - 2.5, width: 5, height: 5)
            context.fill(Path(ellipseIn: dotRect), with: .color(.white))

            // --- Peak marker with altitude label ---
            let peakX = w * CGFloat(visibility.peakHoursFromNow / 18.0)
            let peakY = yFor(visibility.peakAltDeg)
            let peakRect = CGRect(x: peakX - 2, y: peakY - 2, width: 4, height: 4)
            context.fill(Path(ellipseIn: peakRect), with: .color(color))

            // Peak altitude label
            if visibility.peakAltDeg > 5 {
                let label = Text(String(format: "%.0f°", visibility.peakAltDeg))
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundColor(color.opacity(0.8))
                context.draw(label, at: CGPoint(x: peakX, y: peakY - 5), anchor: .bottom)
            }

            // --- Event markers with local times ---
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm"

            // Collect events: (hours, label, color)
            var events: [(hours: Double, label: String, color: Color)] = []

            let hasRiseSet = visibility.riseHoursFromNow != nil || visibility.setHoursFromNow != nil

            if let rise = visibility.riseHoursFromNow, rise > 0.2 && rise < 17.5 {
                let t = fmt.string(from: referenceDate.addingTimeInterval(rise * 3600))
                events.append((rise, "↑" + t, color))
            }
            if let set = visibility.setHoursFromNow, set > 0.2 && set < 17.5 {
                let t = fmt.string(from: referenceDate.addingTimeInterval(set * 3600))
                events.append((set, "↓" + t, color))
            }

            // Only show darkness markers when the object also has rise/set events,
            // otherwise every circumpolar row shows identical sun-only times
            if hasRiseSet {
                if let ds = visibility.darkStartHours, ds > 0.2 && ds < 17.5 {
                    let t = fmt.string(from: referenceDate.addingTimeInterval(ds * 3600))
                    events.append((ds, t, .indigo))
                }
                if let de = visibility.darkEndHours, de > 0.2 && de < 17.5 {
                    let t = fmt.string(from: referenceDate.addingTimeInterval(de * 3600))
                    events.append((de, t, .indigo))
                }
            }

            // For circumpolar objects, show peak time instead
            if !hasRiseSet && visibility.peakHoursFromNow > 0.5 && visibility.peakHoursFromNow < 17.5 {
                let t = fmt.string(from: referenceDate.addingTimeInterval(visibility.peakHoursFromNow * 3600))
                events.append((visibility.peakHoursFromNow, "⬆" + t, color.opacity(0.8)))
            }

            // Remove events too close together (< 1.5h apart) — keep the first
            events.sort { $0.hours < $1.hours }
            var filtered: [(hours: Double, label: String, color: Color)] = []
            for ev in events {
                if let last = filtered.last, abs(ev.hours - last.hours) < 1.5 { continue }
                filtered.append(ev)
            }

            for ev in filtered {
                let tx = w * CGFloat(ev.hours / 18.0)
                var tick = Path()
                tick.move(to: CGPoint(x: tx, y: 0))
                tick.addLine(to: CGPoint(x: tx, y: h))
                context.stroke(tick, with: .color(ev.color.opacity(0.4)),
                              style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))

                let label = Text(ev.label)
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundColor(ev.color.opacity(0.7))
                context.draw(label, at: CGPoint(x: tx, y: h), anchor: .bottom)
            }
        }
        .help(sparklineTooltip)
    }

    private var sparklineTooltip: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        func timeStr(_ h: Double) -> String {
            fmt.string(from: referenceDate.addingTimeInterval(h * 3600))
        }
        if visibility.neverRises { return "Below horizon for next 18h" }
        if visibility.isCircumpolar {
            return String(format: "Circumpolar — peak %.0f° at %@", visibility.peakAltDeg, timeStr(visibility.peakHoursFromNow))
        }
        var s = String(format: "Peak %.0f° at %@", visibility.peakAltDeg, timeStr(visibility.peakHoursFromNow))
        if let rise = visibility.riseHoursFromNow { s += "  Rises \(timeStr(rise))" }
        if let set = visibility.setHoursFromNow { s += "  Sets \(timeStr(set))" }
        return s
    }
}
