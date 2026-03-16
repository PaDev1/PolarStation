import SwiftUI
import PolarCore

@MainActor
final class AppState: ObservableObject {
    @Published var coreVersion: String = ""
    @Published var isConnected: Bool = false

    let plateSolveService = PlateSolveService()
    let mountService = MountService()
    let cameraViewModel = CameraViewModel()
    let guideCameraViewModel = CameraViewModel()
    let filterWheelViewModel = FilterWheelViewModel()
    let focuserViewModel = FocuserViewModel()
    let domeViewModel = DomeViewModel()
    let rotatorViewModel = RotatorViewModel()
    let switchViewModel = SwitchViewModel()
    let safetyMonitorViewModel = SafetyMonitorViewModel()
    let observingConditionsViewModel = ObservingConditionsViewModel()
    let coverCalibratorViewModel = CoverCalibratorViewModel()
    let errorTracker = ErrorTracker()
    let skyMapViewModel = SkyMapViewModel()
    let mountTabViewModel = MountTabViewModel()
    lazy var centeringSolveService: CenteringSolveService = {
        CenteringSolveService(plateSolveService: plateSolveService, mountService: mountService)
    }()
    let guideSession = GuideSession()
    let simulatedGuideEngine = SimulatedGuideEngine()
    let simulatedAlignmentEngine = SimulatedAlignmentEngine()
    let sequenceEngine = SequenceEngine()
    @Published var sequenceDocument = SequenceDocument(name: "New Sequence")
    @Published var sequenceSelectedItemId: UUID?
    lazy var guideCalibrator: GuideCalibrator = {
        GuideCalibrator(mountService: mountService, cameraViewModel: guideCameraViewModel)
    }()
    lazy var alignmentCoordinator: AlignmentCoordinator = {
        let coord = AlignmentCoordinator(
            plateSolveService: plateSolveService,
            mountService: mountService
        )
        coord.errorTracker = errorTracker
        return coord
    }()

    init() {
        coreVersion = PolarCore.polarCoreVersion()
        sequenceEngine.deviceResolver.configure(
            mount: mountService,
            camera: cameraViewModel,
            guideCamera: guideCameraViewModel,
            filterWheel: filterWheelViewModel,
            plateSolve: plateSolveService,
            guide: guideSession,
            focuser: focuserViewModel,
            dome: domeViewModel,
            rotator: rotatorViewModel,
            switchDev: switchViewModel,
            safetyMonitor: safetyMonitorViewModel,
            observingConditions: observingConditionsViewModel,
            coverCalibrator: coverCalibratorViewModel,
            centeringSolve: centeringSolveService
        )
    }

    /// Quick sanity check: compute Julian Date for a known epoch
    func testFFI() -> String {
        let jd = julianDate(year: 2000, month: 1, day: 1, hour: 12, min: 0, sec: 0.0)
        let lst = localSiderealTime(jd: jd, longitudeDeg: 24.94)

        let polaris = CelestialCoord(raDeg: 0.0, decDeg: 90.0)
        let altaz = celestialToAltaz(
            coord: polaris,
            observerLatDeg: 60.17,
            observerLonDeg: 24.94,
            timestampJd: jd
        )

        return """
        PolarCore v\(coreVersion)
        J2000.0 JD: \(String(format: "%.1f", jd))
        LST at Helsinki: \(String(format: "%.2f", lst))°
        Polaris Alt: \(String(format: "%.2f", altaz.altDeg))°
        Polaris Az: \(String(format: "%.2f", altaz.azDeg))°
        """
    }
}
