import SwiftUI
import PolarCore

struct MountTabView: View {
    @ObservedObject var mountService: MountService
    @ObservedObject var plateSolveService: PlateSolveService
    @StateObject private var skyMapVM = SkyMapViewModel()

    @AppStorage("observerLat") private var observerLat: Double = 60.17
    @AppStorage("observerLon") private var observerLon: Double = 24.94
    @AppStorage("focalLengthMM") private var focalLengthMM: Double = 200.0

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
                    Text("Mount Control")
                        .font(.title)

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

            // Right panel: sky map
            VStack(spacing: 0) {
                SkyMapView(viewModel: skyMapVM) { raHours, decDeg in
                    gotoTarget(raHours: raHours, decDeg: decDeg)
                }
            }
            .frame(minWidth: 400)
        }
        .onAppear {
            loadStarCatalog()
            updateCameraFOV()
            skyMapVM.observerLatDeg = observerLat
            skyMapVM.observerLonDeg = observerLon
        }
        .onChange(of: mountService.status) { _, newStatus in
            skyMapVM.syncToMount(status: newStatus)
        }
        .onChange(of: plateSolveService.isLoaded) { _, loaded in
            if loaded { loadStarCatalog() }
        }
        .onChange(of: focalLengthMM) { updateCameraFOV() }
        .onChange(of: observerLat) { skyMapVM.observerLatDeg = observerLat }
        .onChange(of: observerLon) { skyMapVM.observerLonDeg = observerLon }
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

                    // Alt/Az computed from RA/Dec
                    let jd = currentJD()
                    let lstDeg = localSiderealTime(jd: jd, longitudeDeg: observerLon)
                    let haDeg = (lstDeg - s.raHours * 15.0).truncatingRemainder(dividingBy: 360.0)
                    let coord = CelestialCoord(raDeg: s.raHours * 15.0, decDeg: s.decDeg)
                    let altaz = celestialToAltaz(coord: coord, observerLatDeg: observerLat, observerLonDeg: observerLon, timestampJd: jd)
                    HStack {
                        Text("Alt").frame(width: 30, alignment: .trailing).foregroundStyle(.secondary)
                        Text(String(format: "%+.2f°", altaz.altDeg))
                            .font(.system(.body, design: .monospaced))
                        Text("Az").foregroundStyle(.secondary)
                        Text(String(format: "%.2f°", altaz.azDeg))
                            .font(.system(.body, design: .monospaced))
                    }
                    HStack {
                        Text("LST").frame(width: 30, alignment: .trailing).foregroundStyle(.secondary)
                        Text(String(format: "%.2f°", lstDeg))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text("HA").foregroundStyle(.secondary)
                        Text(String(format: "%+.2f°", haDeg))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
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
                .pickerStyle(.segmented)
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
                .pickerStyle(.segmented)

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
        GroupBox("Park") {
            HStack(spacing: 12) {
                Button("Park") {
                    Task {
                        do {
                            try await mountService.park()
                            mountError = nil
                        } catch { mountError = error.localizedDescription }
                    }
                }
                .buttonStyle(.bordered)

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
            }
            .padding(.vertical, 4)
        }
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

    private func currentJD() -> Double {
        // Direct conversion from Swift Date (seconds since 2001-01-01 00:00:00 UTC)
        // to Julian Date. Avoids calendar/timezone component extraction entirely.
        // JD of Swift reference date (2001-01-01 00:00 UTC) = 2451910.5
        Date().timeIntervalSinceReferenceDate / 86400.0 + 2451910.5
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
        // ASI585MC sensor: 3840x2160 pixels at 2.9μm = 11.14mm x 6.26mm
        // Binning does NOT change physical FOV (same sensor area, fewer pixels)
        let sensorWidthMM = 11.14
        let fov = 2.0 * atan(sensorWidthMM / (2.0 * focalLengthMM)) * 180.0 / .pi
        skyMapVM.cameraFOVDeg = fov
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
