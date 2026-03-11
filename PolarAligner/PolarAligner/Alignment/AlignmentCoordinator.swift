import Foundation
import PolarCore
import CoreLocation

/// Orchestrates the three-point polar alignment workflow.
///
/// Flow: capture→solve→slew 30°→capture→solve→slew 30°→capture→solve→compute error.
/// The coordinator is event-driven: call `submitStars(_:)` when star centroids are
/// available from the detection pipeline. The coordinator plate-solves and advances
/// the state machine automatically.
@MainActor
final class AlignmentCoordinator: ObservableObject {

    // MARK: - Published state

    @Published var step: AlignmentStep = .idle
    @Published var positions: [CelestialCoord?] = [nil, nil, nil]
    @Published var polarError: PolarError?
    @Published var statusMessage = "Press Start to begin alignment"
    @Published var isBusy = false

    // MARK: - Configuration

    /// Observer latitude in degrees (north positive).
    var observerLatDeg: Double = 60.17
    /// Observer longitude in degrees (east positive).
    var observerLonDeg: Double = 24.94
    /// RA slew between captures in degrees.
    var slewDeg: Double = 30.0

    // MARK: - Services

    let plateSolveService: PlateSolveService
    let mountService: MountService

    /// Error tracker to start when alignment completes.
    var errorTracker: ErrorTracker?

    // MARK: - State machine

    enum AlignmentStep: Equatable {
        case idle
        case waitingForSolve(Int)   // 1, 2, or 3
        case slewing(Int)           // after solving step N, slewing to next
        case computing
        case complete
        case error(String)
    }

    init(plateSolveService: PlateSolveService, mountService: MountService) {
        self.plateSolveService = plateSolveService
        self.mountService = mountService
    }

    /// Set observer location from CoreLocation.
    func setLocation(_ location: CLLocationCoordinate2D) {
        observerLatDeg = location.latitude
        observerLonDeg = location.longitude
    }

    /// Start the three-point alignment workflow.
    func startAlignment() {
        guard !isBusy else { return }
        positions = [nil, nil, nil]
        polarError = nil
        step = .waitingForSolve(1)
        statusMessage = "Capturing position 1 of 3..."
    }

    /// Reset to idle state.
    func reset() {
        step = .idle
        positions = [nil, nil, nil]
        polarError = nil
        isBusy = false
        statusMessage = "Press Start to begin alignment"
    }

    /// Submit detected stars for plate solving.
    ///
    /// Call this when star centroids are available from the detection pipeline.
    /// The coordinator will plate-solve and advance the state machine.
    func submitStars(_ stars: [DetectedStar]) {
        guard case .waitingForSolve(let n) = step, !isBusy else { return }
        guard stars.count >= 4 else {
            statusMessage = "Need at least 4 stars (have \(stars.count))"
            return
        }

        isBusy = true
        statusMessage = "Plate solving position \(n)..."

        Task {
            do {
                let result = try await plateSolveService.solve(centroids: stars)
                guard result.success else {
                    statusMessage = "Solve failed — try adjusting exposure"
                    isBusy = false
                    return
                }

                let coord = CelestialCoord(raDeg: result.raDeg, decDeg: result.decDeg)
                positions[n - 1] = coord
                statusMessage = String(format: "Position %d: RA %.2f° Dec %.2f°", n, result.raDeg, result.decDeg)

                if n < 3 {
                    await slewToNext(afterStep: n)
                } else {
                    await computeError()
                }
            } catch {
                statusMessage = "Solve error: \(error.localizedDescription)"
                isBusy = false
            }
        }
    }

    // MARK: - Private

    private func slewToNext(afterStep n: Int) async {
        step = .slewing(n)
        statusMessage = String(format: "Slewing %.0f° in RA...", slewDeg)

        do {
            try await mountService.slewRA(degrees: slewDeg)
            step = .waitingForSolve(n + 1)
            statusMessage = "Capturing position \(n + 1) of 3..."
            isBusy = false
        } catch {
            step = .error("Slew failed: \(error.localizedDescription)")
            statusMessage = "Slew failed: \(error.localizedDescription)"
            isBusy = false
        }
    }

    private func computeError() async {
        step = .computing
        statusMessage = "Computing polar alignment error..."

        guard let p1 = positions[0], let p2 = positions[1], let p3 = positions[2] else {
            step = .error("Missing positions")
            statusMessage = "Missing one or more solved positions"
            isBusy = false
            return
        }

        // Current Julian Date from system clock
        let jd = currentJulianDate()

        do {
            let error = try computePolarError(
                pos1: p1, pos2: p2, pos3: p3,
                observerLatDeg: observerLatDeg,
                observerLonDeg: observerLonDeg,
                timestampJd: jd
            )
            polarError = error
            step = .complete
            statusMessage = String(
                format: "Alignment error: %.1f' (Alt %.1f' Az %.1f')",
                error.totalErrorArcmin,
                error.altErrorArcmin,
                error.azErrorArcmin
            )

            // Auto-start error tracking for real-time adjustment
            errorTracker?.startTracking(initialError: error)
        } catch {
            step = .error("Computation failed: \(error.localizedDescription)")
            statusMessage = "Computation failed: \(error.localizedDescription)"
        }
        isBusy = false
    }

    /// Compute current Julian Date from system clock (UTC).
    private func currentJulianDate() -> Double {
        let now = Date()
        let calendar = Calendar(identifier: .gregorian)
        let utc = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents(in: utc, from: now)
        let year = Int32(components.year ?? 2024)
        let month = UInt32(components.month ?? 1)
        let day = UInt32(components.day ?? 1)
        let hour = UInt32(components.hour ?? 0)
        let min = UInt32(components.minute ?? 0)
        let sec = Double(components.second ?? 0)
        return julianDate(year: year, month: month, day: day, hour: hour, min: min, sec: sec)
    }
}
