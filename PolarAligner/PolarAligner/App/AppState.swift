import SwiftUI
import PolarCore

@MainActor
final class AppState: ObservableObject {
    @Published var coreVersion: String = ""
    @Published var isConnected: Bool = false

    let plateSolveService = PlateSolveService()
    let mountService = MountService()
    let cameraViewModel = CameraViewModel()
    let errorTracker = ErrorTracker()
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
