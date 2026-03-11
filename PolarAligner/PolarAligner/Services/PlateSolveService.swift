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

    private let solver = PlateSolver()
    private let solveQueue = DispatchQueue(label: "com.polaraligner.platesolve", qos: .userInitiated)

    /// Camera sensor dimensions (ASI585MC at 2x2 binning).
    var imageWidth: UInt32 = 1920
    var imageHeight: UInt32 = 1080

    /// Estimated horizontal FOV in degrees (computed from focal length + sensor).
    /// ASI585MC sensor: 11.14mm × 6.25mm, pixel size 2.9μm.
    /// At 200mm FL: FOV = 2 * atan(11.14 / (2*200)) * 180/π ≈ 3.19°
    var fovDeg: Double = 3.2

    /// FOV tolerance in degrees.
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

    var errorDescription: String? {
        switch self {
        case .databaseNotInBundle:
            return "star_catalog.rkyv not found in app bundle"
        }
    }
}
