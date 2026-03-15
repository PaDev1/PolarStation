import SwiftUI
import PolarCore
import SwiftAA

/// Holds MountTabView state that must survive tab switches.
///
/// ContentView uses `.id(selectedTab)` to prevent SwiftUI attribute-graph
/// bloat, which destroys all `@State` on every tab change.  Moving the
/// expensive / user-visible catalog state here keeps it alive in AppState.
@MainActor
final class MountTabViewModel: ObservableObject {
    // Catalog panel
    @Published var showCatalog = false
    @Published var catalogSearch = ""
    @Published var catalogFilter: CatalogFilter = .all
    @Published var planningDate: Date = Date()
    @Published var isLiveTime: Bool = true

    // Cached catalog entries (computed async off main thread)
    @Published var cachedCatalogEntries: [CatalogEntry] = []
    @Published var isCatalogLoading = false
    var catalogComputeTask: Task<Void, Never>?

    // MARK: - Types

    enum CatalogFilter: String, CaseIterable {
        case all = "All"
        case messier = "Messier"
        case planets = "Planets"
        case galaxies = "Galaxies"
        case nebulae = "Nebulae"
        case clusters = "Clusters"
        case aboveHorizon = "Above Horizon"
    }

    enum CatalogCategory {
        case deepSky
        case planet
        case moon
        case sun
    }

    struct VisibilityInfo {
        let altitudeSamples: [Double]  // altitude every 30 min for 18h (37 samples)
        let azimuthSamples: [Double]   // azimuth at same time steps (0-360°)
        let sunAltSamples: [Double]    // sun altitude at same time steps
        let peakAltDeg: Double
        let peakHoursFromNow: Double
        let riseHoursFromNow: Double?  // nil if circumpolar or never rises
        let setHoursFromNow: Double?   // nil if circumpolar or never rises
        let darkStartHours: Double?    // sun goes below -18° (night begins)
        let darkEndHours: Double?      // sun goes above -18° (night ends)
        let isCircumpolar: Bool
        let neverRises: Bool

        /// Check if object is within observation window at any sample point.
        func isVisibleInWindow(minAlt: Double, maxAlt: Double, azFrom: Double, azTo: Double) -> Bool {
            for i in 0..<altitudeSamples.count {
                let isDark = i < sunAltSamples.count && sunAltSamples[i] < -18
                if isDark && altitudeSamples[i] >= minAlt && altitudeSamples[i] <= maxAlt && azimuthInRange(azimuthSamples[i], from: azFrom, to: azTo) {
                    return true
                }
            }
            return false
        }

        func windowInterval(minAlt: Double, maxAlt: Double, azFrom: Double, azTo: Double) -> (start: Double, end: Double)? {
            let stepHours = 0.5
            var startHours: Double?
            var endHours: Double?

            for i in 0..<altitudeSamples.count {
                let isDark = i < sunAltSamples.count && sunAltSamples[i] < -18
                let inWin = isDark && altitudeSamples[i] >= minAlt && altitudeSamples[i] <= maxAlt && azimuthInRange(azimuthSamples[i], from: azFrom, to: azTo)
                if inWin && startHours == nil {
                    startHours = Double(i) * stepHours
                }
                if !inWin && startHours != nil && endHours == nil {
                    endHours = Double(i) * stepHours
                }
            }

            guard let start = startHours else { return nil }
            let end = endHours ?? Double(altitudeSamples.count - 1) * stepHours
            if start < 0.1 && end > 17.5 { return nil }
            return (start, end)
        }

        func azimuthInRange(_ az: Double, from: Double, to: Double) -> Bool {
            if from <= to {
                return az >= from && az <= to
            } else {
                return az >= from || az <= to
            }
        }
    }

    struct CatalogEntry: Identifiable {
        let id: String
        let name: String
        let detail: String
        let raHours: Double
        let decDeg: Double
        let altDeg: Double
        let azDeg: Double
        let color: Color
        let category: CatalogCategory
        let visibility: VisibilityInfo
    }

    // MARK: - Catalog Computation

    /// The effective reference time for catalog computations.
    var catalogReferenceDate: Date {
        isLiveTime ? Date() : planningDate
    }

    /// Trigger async catalog recomputation. Cancels any in-progress computation.
    func recomputeCatalog(
        observerLat: Double,
        observerLon: Double,
        obsWindowEnabled: Bool,
        obsWindowMinAlt: Double,
        obsWindowMaxAlt: Double,
        obsWindowAzFrom: Double,
        obsWindowAzTo: Double
    ) {
        guard showCatalog else { return }

        catalogComputeTask?.cancel()
        isCatalogLoading = true

        let filter = catalogFilter
        let search = catalogSearch
        let refDate = catalogReferenceDate
        let catalog = messierCatalog

        catalogComputeTask = Task.detached(priority: .userInitiated) { [weak self] in
            let entries = MountTabViewModel.buildCatalogEntries(
                lat: observerLat, lon: observerLon, filter: filter, search: search,
                refDate: refDate, obsEnabled: obsWindowEnabled,
                obsMinAlt: obsWindowMinAlt, obsMaxAlt: obsWindowMaxAlt,
                obsAzFrom: obsWindowAzFrom, obsAzTo: obsWindowAzTo,
                catalog: catalog
            )

            guard !Task.isCancelled else { return }

            await MainActor.run {
                self?.cachedCatalogEntries = entries
                self?.isCatalogLoading = false
            }
        }
    }

    /// Pure computation — runs on background thread, no main thread blocking.
    nonisolated static func buildCatalogEntries(
        lat: Double, lon: Double,
        filter: CatalogFilter, search: String,
        refDate: Date, obsEnabled: Bool,
        obsMinAlt: Double, obsMaxAlt: Double,
        obsAzFrom: Double, obsAzTo: Double,
        catalog: [MessierObject]
    ) -> [CatalogEntry] {
        let geo = GeographicCoordinates(
            positivelyWestwardLongitude: Degree(-lon),
            latitude: Degree(lat)
        )
        let jd = JulianDay(refDate)

        func compassAz(_ swiftAAAz: Double) -> Double {
            (swiftAAAz + 180.0).truncatingRemainder(dividingBy: 360.0)
        }

        func computeVis(raDeg: Double, decDeg: Double) -> VisibilityInfo {
            let sampleCount = 37
            let stepSeconds: TimeInterval = 1800

            var samples: [Double] = []
            var azSamples: [Double] = []
            var sunSamples: [Double] = []
            var peakAlt = -90.0
            var peakIndex = 0

            let eq = EquatorialCoordinates(alpha: Hour(raDeg / 15.0), delta: Degree(decDeg))

            for i in 0..<sampleCount {
                let t = refDate.addingTimeInterval(Double(i) * stepSeconds)
                let tjd = JulianDay(t)
                let horiz = eq.makeHorizontalCoordinates(for: geo, at: tjd)
                let alt = horiz.altitude.value
                samples.append(alt)
                let az = (horiz.azimuth.value + 180.0).truncatingRemainder(dividingBy: 360.0)
                azSamples.append(az)
                if alt > peakAlt {
                    peakAlt = alt
                    peakIndex = i
                }
                let sun = Sun(julianDay: tjd)
                let sunHoriz = sun.makeHorizontalCoordinates(with: geo)
                sunSamples.append(sunHoriz.altitude.value)
            }

            var riseHours: Double?
            var setHours: Double?
            for i in 1..<sampleCount {
                let prev = samples[i - 1]
                let curr = samples[i]
                if prev <= 0 && curr > 0 && riseHours == nil {
                    let frac = -prev / (curr - prev)
                    riseHours = (Double(i - 1) + frac) * 0.5
                }
                if prev > 0 && curr <= 0 && riseHours != nil && setHours == nil {
                    let frac = prev / (prev - curr)
                    setHours = (Double(i - 1) + frac) * 0.5
                }
            }

            var darkStartHours: Double?
            var darkEndHours: Double?
            for i in 1..<sampleCount {
                let prev = sunSamples[i - 1]
                let curr = sunSamples[i]
                if prev >= -18 && curr < -18 && darkStartHours == nil {
                    let frac = (prev - (-18)) / (prev - curr)
                    darkStartHours = (Double(i - 1) + frac) * 0.5
                }
                if prev < -18 && curr >= -18 && darkEndHours == nil {
                    let frac = ((-18) - prev) / (curr - prev)
                    darkEndHours = (Double(i - 1) + frac) * 0.5
                }
            }

            return VisibilityInfo(
                altitudeSamples: samples,
                azimuthSamples: azSamples,
                sunAltSamples: sunSamples,
                peakAltDeg: peakAlt,
                peakHoursFromNow: Double(peakIndex) * 0.5,
                riseHoursFromNow: riseHours,
                setHoursFromNow: setHours,
                darkStartHours: darkStartHours,
                darkEndHours: darkEndHours,
                isCircumpolar: samples.allSatisfy { $0 > 0 },
                neverRises: samples.allSatisfy { $0 <= 0 }
            )
        }

        var entries: [CatalogEntry] = []

        // Planets
        if filter == .all || filter == .planets || filter == .aboveHorizon {
            let sun = Sun(julianDay: jd)
            let sunEq = sun.equatorialCoordinates
            let sunHoriz = sun.makeHorizontalCoordinates(with: geo)
            entries.append(CatalogEntry(
                id: "planet_sun", name: "Sun",
                detail: "", raHours: sunEq.alpha.value, decDeg: sunEq.delta.value,
                altDeg: sunHoriz.altitude.value, azDeg: compassAz(sunHoriz.azimuth.value),
                color: .yellow, category: .sun,
                visibility: computeVis(raDeg: sunEq.alpha.value * 15.0, decDeg: sunEq.delta.value)
            ))

            let moon = Moon(julianDay: jd)
            let moonEq = moon.equatorialCoordinates
            let moonHoriz = EquatorialCoordinates(alpha: moonEq.alpha, delta: moonEq.delta)
                .makeHorizontalCoordinates(for: geo, at: jd)
            let illum = moon.illuminatedFraction()
            entries.append(CatalogEntry(
                id: "planet_moon", name: "Moon",
                detail: String(format: "%.0f%%", illum * 100),
                raHours: moonEq.alpha.value, decDeg: moonEq.delta.value,
                altDeg: moonHoriz.altitude.value, azDeg: compassAz(moonHoriz.azimuth.value),
                color: .init(white: 0.85), category: .moon,
                visibility: computeVis(raDeg: moonEq.alpha.value * 15.0, decDeg: moonEq.delta.value)
            ))

            let planetDefs: [(Planet, String, Color)] = [
                (Mercury(julianDay: jd), "Mercury", .gray),
                (Venus(julianDay: jd), "Venus", .white),
                (Mars(julianDay: jd), "Mars", .red),
                (Jupiter(julianDay: jd), "Jupiter", .orange),
                (Saturn(julianDay: jd), "Saturn", .init(red: 0.9, green: 0.8, blue: 0.4)),
                (Uranus(julianDay: jd), "Uranus", .cyan),
                (Neptune(julianDay: jd), "Neptune", .blue),
            ]
            for (planet, name, color) in planetDefs {
                let eq = planet.equatorialCoordinates
                let horiz = EquatorialCoordinates(alpha: eq.alpha, delta: eq.delta)
                    .makeHorizontalCoordinates(for: geo, at: jd)
                let mag = planet.magnitude.value
                let displayMag = mag.isNaN ? 99.0 : mag
                entries.append(CatalogEntry(
                    id: "planet_\(name.lowercased())", name: name,
                    detail: displayMag < 99 ? String(format: "mag %.1f", displayMag) : "",
                    raHours: eq.alpha.value, decDeg: eq.delta.value,
                    altDeg: horiz.altitude.value, azDeg: compassAz(horiz.azimuth.value),
                    color: color, category: .planet,
                    visibility: computeVis(raDeg: eq.alpha.value * 15.0, decDeg: eq.delta.value)
                ))
            }
        }

        // Messier objects
        if filter != .planets {
            for obj in catalog {
                switch filter {
                case .galaxies: guard obj.type == .galaxy else { continue }
                case .nebulae: guard obj.type == .nebula || obj.type == .planetary else { continue }
                case .clusters: guard obj.type == .cluster || obj.type == .globular else { continue }
                case .messier, .all, .aboveHorizon: break
                case .planets: continue
                }

                let horiz = EquatorialCoordinates(
                    alpha: Hour(obj.raDeg / 15.0),
                    delta: Degree(obj.decDeg)
                ).makeHorizontalCoordinates(for: geo, at: jd)

                let color: Color = {
                    switch obj.type {
                    case .galaxy: return .yellow
                    case .nebula: return .red
                    case .cluster: return .cyan
                    case .planetary: return .green
                    case .globular: return .orange
                    case .other: return .gray
                    }
                }()

                entries.append(CatalogEntry(
                    id: obj.id,
                    name: "\(obj.id) \(obj.name)",
                    detail: "\(obj.type.rawValue)  mag \(String(format: "%.1f", obj.magnitude))",
                    raHours: obj.raHours,
                    decDeg: obj.decDeg,
                    altDeg: horiz.altitude.value,
                    azDeg: compassAz(horiz.azimuth.value),
                    color: color,
                    category: .deepSky,
                    visibility: computeVis(raDeg: obj.raDeg, decDeg: obj.decDeg)
                ))
            }
        }

        if filter == .aboveHorizon {
            entries = entries.filter { $0.altDeg > 0 }
        }

        if obsEnabled {
            entries = entries.filter {
                $0.visibility.isVisibleInWindow(
                    minAlt: obsMinAlt, maxAlt: obsMaxAlt,
                    azFrom: obsAzFrom, azTo: obsAzTo
                )
            }
        }

        if !search.isEmpty {
            let query = search.lowercased()
            entries = entries.filter { $0.name.lowercased().contains(query) || $0.detail.lowercased().contains(query) }
        }

        entries.sort { a, b in
            if a.altDeg > 0 && b.altDeg <= 0 { return true }
            if a.altDeg <= 0 && b.altDeg > 0 { return false }
            return a.altDeg > b.altDeg
        }

        return entries
    }

    // MARK: - Helpers

    func visibilitySummary(_ v: VisibilityInfo) -> String {
        if v.neverRises { return "Below horizon" }
        if v.isCircumpolar { return String(format: "Circumpolar  peak %.0f°", v.peakAltDeg) }

        var parts: [String] = []
        if let rise = v.riseHoursFromNow {
            if rise < 0.1 {
                parts.append("Rising now")
            } else {
                parts.append("Rises \(localTimeStr(hoursFromNow: rise))")
            }
        }
        parts.append(String(format: "Peak %.0f° %@", v.peakAltDeg, localTimeStr(hoursFromNow: v.peakHoursFromNow)))
        if let set = v.setHoursFromNow {
            parts.append("Sets \(localTimeStr(hoursFromNow: set))")
        }
        if let ds = v.darkStartHours {
            parts.append("Dark \(localTimeStr(hoursFromNow: ds))")
        }
        return parts.joined(separator: "  ")
    }

    func localTimeStr(hoursFromNow: Double) -> String {
        let date = catalogReferenceDate.addingTimeInterval(hoursFromNow * 3600)
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: date)
    }
}
