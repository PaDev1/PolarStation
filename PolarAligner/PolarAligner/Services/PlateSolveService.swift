import Foundation
import PolarCore

/// Async wrapper around the Rust plate solver.
///
/// Handles database loading, centroid conversion, and dispatches solve calls
/// to a background queue to avoid blocking the main thread.
@MainActor
final class PlateSolveService: ObservableObject {
    @Published var isLoaded = false
    @Published var databaseInfo: String?
    @Published var lastResult: SolveResult?
    @Published var isSolving = false
    @Published var debugLog: String = ""
    private var debugLines: [String] = []
    private let maxDebugLines = 50

    private let solver = PlateSolver()
    private let solveQueue = DispatchQueue(label: "com.polaraligner.platesolve", qos: .userInitiated)

    func log(_ msg: String) {
        let ts = String(format: "%.1f", Date.now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1000))
        debugLines.append("[\(ts)] \(msg)")
        if debugLines.count > maxDebugLines { debugLines.removeFirst(debugLines.count - maxDebugLines) }
        debugLog = debugLines.joined(separator: "\n")
    }

    /// Camera sensor dimensions (ASI585MC at 2x2 binning).
    var imageWidth: UInt32 = 1920
    var imageHeight: UInt32 = 1080

    /// Estimated horizontal FOV in degrees (computed from focal length + sensor).
    /// ASI585MC sensor: 11.14mm × 6.25mm, pixel size 2.9μm.
    /// At 200mm FL: FOV = 2 * atan(11.14 / (2*200)) * 180/π ≈ 3.19°
    var fovDeg: Double = 3.2

    /// FOV tolerance in degrees. Wider = more likely to solve but slower.
    var fovToleranceDeg: Double = 1.0

    /// Load the solver database from the app bundle or a file path.
    func loadDatabase(from path: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            solveQueue.async { [solver] in
                do {
                    try solver.loadDatabase(path: path)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        isLoaded = true
        databaseInfo = solver.databaseInfo()
    }

    /// Load database from the app bundle.
    func loadBundledDatabase() async throws {
        guard let url = Bundle.main.url(forResource: "star_catalog", withExtension: "rkyv") else {
            throw PlateSolveServiceError.databaseNotInBundle
        }
        try await loadDatabase(from: url.path)
    }

    /// Solve the sky position from detected star centroids.
    ///
    /// Centroids should be in pixel coordinates with origin at top-left.
    func solve(centroids: [DetectedStar]) async throws -> SolveResult {
        isSolving = true
        defer { Task { @MainActor in isSolving = false } }

        log("[Solve] stars=\(centroids.count) img=\(imageWidth)x\(imageHeight) fov=\(String(format: "%.2f", fovDeg))° tol=\(String(format: "%.2f", fovToleranceDeg))°")

        // Convert DetectedStar to PolarCore's StarCentroid
        let starCentroids = centroids.map { star in
            StarCentroid(x: star.x, y: star.y, brightness: star.brightness)
        }

        let result: SolveResult = try await withCheckedThrowingContinuation { continuation in
            solveQueue.async { [solver, imageWidth, imageHeight, fovDeg, fovToleranceDeg] in
                do {
                    let r = try solver.solve(
                        centroids: starCentroids,
                        imageWidth: imageWidth,
                        imageHeight: imageHeight,
                        fovDeg: fovDeg,
                        fovToleranceDeg: fovToleranceDeg
                    )
                    continuation.resume(returning: r)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        log("[Solve] \(result.success ? "OK" : "FAIL") matched=\(result.matchedStars) time=\(String(format: "%.0f", result.solveTimeMs))ms fov=\(String(format: "%.2f", result.fovDeg))°")
        lastResult = result
        return result
    }

    /// Robust solve: retry with star subsets and FOV variations.
    ///
    /// Tries progressively filtered star lists and FOV adjustments to handle
    /// marginal conditions (few stars, faint stars, slight FOV mismatch).
    func solveRobust(centroids: [DetectedStar]) async throws -> SolveResult {
        let sorted = centroids.sorted { $0.brightness > $1.brightness }
        log("[Robust] stars=\(centroids.count) SNR=\(String(format: "%.1f", sorted.first?.snr ?? 0)) img=\(imageWidth)x\(imageHeight) fov=\(String(format: "%.2f", fovDeg))° tol=\(String(format: "%.1f", fovToleranceDeg))°")

        // Tier 1: Brightest subsets (tetra3 works best with 8-20 stars, not hundreds)
        for k in [20, 16, 12, 10, 8] where k <= sorted.count {
            let subset = Array(sorted.prefix(k))
            if let r = try? await solve(centroids: subset), r.success {
                log("[Robust] T1: top-\(k) brightest")
                return r
            }
        }

        // Tier 3: Remove edge stars (within 5% margin), then try brightest subsets
        let marginX = Double(imageWidth) * 0.05
        let marginY = Double(imageHeight) * 0.05
        let interior = sorted.filter {
            $0.x >= marginX && $0.x < Double(imageWidth) - marginX &&
            $0.y >= marginY && $0.y < Double(imageHeight) - marginY
        }
        if interior.count >= 4 {
            if let r = try? await solve(centroids: interior), r.success {
                log("[Robust] T3: \(interior.count) interior stars")
                return r
            }
        }

        // Tier 4: Widen tolerance with best stars
        let bestSubset = Array(sorted.prefix(min(16, sorted.count)))
        let savedFOV = fovDeg
        let savedTol = fovToleranceDeg
        defer { fovDeg = savedFOV; fovToleranceDeg = savedTol }

        for tol in [2.0, 3.0, 5.0] where tol > savedTol {
            fovToleranceDeg = tol
            if let r = try? await solve(centroids: bestSubset), r.success {
                log("[Robust] T4: tol=\(String(format: "%.1f", tol))°")
                return r
            }
        }

        // Tier 5: No FOV constraint (tolerance=0 lets tetra3 try everything)
        fovDeg = savedFOV
        fovToleranceDeg = 0
        if let r = try? await solve(centroids: bestSubset), r.success {
            log("[Robust] T5: unconstrained, solved at FOV=\(String(format: "%.2f", r.fovDeg))°")
            return r
        }

        log("[Robust] ALL TIERS FAILED with \(centroids.count) stars")
        throw PlateSolveServiceError.robustSolveFailed(starCount: centroids.count)
    }

    /// Solve using Astrometry.net remote API.
    ///
    /// Requires an API key from nova.astrometry.net.
    /// Provide optional hints (RA/Dec center + radius, FOV) to speed up the solve.
    func solveRemote(
        jpegData: Data,
        apiKey: String,
        baseURL: String = AstrometryNetService.remoteBaseURL,
        hintRA: Double? = nil,
        hintDec: Double? = nil,
        hintRadiusDeg: Double? = nil,
        onStatus: ((String) -> Void)? = nil
    ) async throws -> SolveResult {
        isSolving = true
        defer { Task { @MainActor in isSolving = false } }

        let service = AstrometryNetService(baseURL: baseURL)
        // Forward step-by-step status to the caller via callback
        if let onStatus {
            service.onStatusUpdate = onStatus
        }
        let result = try await service.solve(
            jpegData: jpegData,
            apiKey: apiKey,
            hintRA: hintRA,
            hintDec: hintDec,
            hintRadiusDeg: hintRadiusDeg,
            hintFovDeg: fovDeg
        )
        lastResult = result
        return result
    }

    /// Compute FOV from focal length (mm) and sensor width (mm).
    func setFOV(focalLengthMM: Double, sensorWidthMM: Double = 11.14) {
        fovDeg = 2.0 * atan(sensorWidthMM / (2.0 * focalLengthMM)) * 180.0 / .pi
    }

    /// Get all stars from the loaded catalog (for sky map display).
    func getStarCatalog() async -> [CatalogStar] {
        await withCheckedContinuation { continuation in
            solveQueue.async { [solver] in
                let stars = solver.getStarCatalog()
                continuation.resume(returning: stars)
            }
        }
    }
}

enum PlateSolveServiceError: Error, LocalizedError {
    case databaseNotInBundle
    case robustSolveFailed(starCount: Int)

    var errorDescription: String? {
        switch self {
        case .databaseNotInBundle:
            return "star_catalog.rkyv not found in app bundle"
        case .robustSolveFailed(let count):
            return "Plate solve failed after all retry strategies (\(count) stars detected)"
        }
    }
}
