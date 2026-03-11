import Foundation

/// Matches star centroids between consecutive frames using nearest-neighbor.
///
/// Used during real-time adjustment to track how stars move as the user
/// turns altitude/azimuth screws, enabling fast error interpolation between
/// full plate solves.
struct StarMatcher {

    /// A matched pair of stars between two frames.
    struct Match {
        let reference: DetectedStar
        let current: DetectedStar
        let dx: Double  // pixels
        let dy: Double  // pixels
    }

    /// Maximum distance in pixels for a valid match.
    var maxMatchDistance: Double = 20.0

    /// Match stars from the current frame to a reference frame.
    ///
    /// Uses brightness-weighted nearest-neighbor matching. Stars are matched
    /// greedily by proximity, brightest first, so bright stars get priority.
    ///
    /// - Returns: Array of matched star pairs sorted by reference brightness.
    func match(reference: [DetectedStar], current: [DetectedStar]) -> [Match] {
        guard !reference.isEmpty, !current.isEmpty else { return [] }

        var available = current  // mutable copy; matched stars are removed
        var matches: [Match] = []

        for refStar in reference {
            var bestIdx = -1
            var bestDist = Double.greatestFiniteMagnitude

            for (i, curStar) in available.enumerated() {
                let dx = curStar.x - refStar.x
                let dy = curStar.y - refStar.y
                let dist = sqrt(dx * dx + dy * dy)
                if dist < bestDist {
                    bestDist = dist
                    bestIdx = i
                }
            }

            if bestIdx >= 0 && bestDist <= maxMatchDistance {
                let curStar = available.remove(at: bestIdx)
                matches.append(Match(
                    reference: refStar,
                    current: curStar,
                    dx: curStar.x - refStar.x,
                    dy: curStar.y - refStar.y
                ))
            }
        }

        return matches
    }

    /// Compute the median displacement vector from a set of matches.
    ///
    /// Uses median rather than mean to reject outliers (hot pixels, cosmic rays).
    static func medianDisplacement(_ matches: [Match]) -> (dx: Double, dy: Double) {
        guard !matches.isEmpty else { return (0, 0) }

        let dxs = matches.map(\.dx).sorted()
        let dys = matches.map(\.dy).sorted()
        let mid = matches.count / 2

        let medDx = matches.count % 2 == 1 ? dxs[mid] : (dxs[mid - 1] + dxs[mid]) / 2.0
        let medDy = matches.count % 2 == 1 ? dys[mid] : (dys[mid - 1] + dys[mid]) / 2.0

        return (medDx, medDy)
    }
}
