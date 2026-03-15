import Foundation

/// Maps device role strings to live application services.
///
/// At runtime, the sequencer asks the resolver for a service by role name.
/// This decouples the sequence document (portable) from the app's actual
/// service instances.
@MainActor
class DeviceResolver {
    private var mountService: MountService?
    private var cameraViewModel: CameraViewModel?
    private var guideCameraViewModel: CameraViewModel?
    private var filterWheelViewModel: FilterWheelViewModel?
    private var plateSolveService: PlateSolveService?
    private var guideSession: GuideSession?
    private var focuserViewModel: FocuserViewModel?
    private var domeViewModel: DomeViewModel?
    private var rotatorViewModel: RotatorViewModel?
    private var switchViewModel: SwitchViewModel?
    private var safetyMonitorViewModel: SafetyMonitorViewModel?
    private var observingConditionsViewModel: ObservingConditionsViewModel?
    private var coverCalibratorViewModel: CoverCalibratorViewModel?

    func configure(
        mount: MountService,
        camera: CameraViewModel,
        guideCamera: CameraViewModel,
        filterWheel: FilterWheelViewModel,
        plateSolve: PlateSolveService,
        guide: GuideSession? = nil,
        focuser: FocuserViewModel? = nil,
        dome: DomeViewModel? = nil,
        rotator: RotatorViewModel? = nil,
        switchDev: SwitchViewModel? = nil,
        safetyMonitor: SafetyMonitorViewModel? = nil,
        observingConditions: ObservingConditionsViewModel? = nil,
        coverCalibrator: CoverCalibratorViewModel? = nil
    ) {
        self.mountService = mount
        self.cameraViewModel = camera
        self.guideCameraViewModel = guideCamera
        self.filterWheelViewModel = filterWheel
        self.plateSolveService = plateSolve
        self.guideSession = guide
        self.focuserViewModel = focuser
        self.domeViewModel = dome
        self.rotatorViewModel = rotator
        self.switchViewModel = switchDev
        self.safetyMonitorViewModel = safetyMonitor
        self.observingConditionsViewModel = observingConditions
        self.coverCalibratorViewModel = coverCalibrator
    }

    func mount() -> MountService? { mountService }
    func camera() -> CameraViewModel? { cameraViewModel }
    func guideCamera() -> CameraViewModel? { guideCameraViewModel }
    func filterWheel() -> FilterWheelViewModel? { filterWheelViewModel }
    func plateSolver() -> PlateSolveService? { plateSolveService }
    func guide() -> GuideSession? { guideSession }
    func focuser() -> FocuserViewModel? { focuserViewModel }
    func dome() -> DomeViewModel? { domeViewModel }
    func rotator() -> RotatorViewModel? { rotatorViewModel }
    func switchDev() -> SwitchViewModel? { switchViewModel }
    func safetyMonitor() -> SafetyMonitorViewModel? { safetyMonitorViewModel }
    func observingConditions() -> ObservingConditionsViewModel? { observingConditionsViewModel }
    func coverCalibrator() -> CoverCalibratorViewModel? { coverCalibratorViewModel }

    /// Resolve a device role string to check if the device is available.
    func isAvailable(role: String) -> Bool {
        switch role {
        case "mount": return mountService?.isConnected ?? false
        case "imaging_camera": return cameraViewModel != nil
        case "guide_camera": return guideCameraViewModel != nil
        case "filter_wheel": return filterWheelViewModel?.isConnected ?? false
        case "focuser": return focuserViewModel?.isConnected ?? false
        case "dome": return domeViewModel?.isConnected ?? false
        case "rotator": return rotatorViewModel?.isConnected ?? false
        case "switch": return switchViewModel?.isConnected ?? false
        case "safety_monitor": return safetyMonitorViewModel?.isConnected ?? false
        case "observing_conditions": return observingConditionsViewModel?.isConnected ?? false
        case "cover_calibrator": return coverCalibratorViewModel?.isConnected ?? false
        default: return false
        }
    }
}
