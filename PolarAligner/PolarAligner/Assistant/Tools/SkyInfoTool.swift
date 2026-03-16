import Foundation
import SwiftUI

/// Read-only tool for sky information, target suggestions, catalog search, and weather.
@MainActor
final class SkyInfoTool: AssistantTool {
    private let weatherService: WeatherService

    init(weatherService: WeatherService) {
        self.weatherService = weatherService
    }

    var definition: ToolDefinition {
        ToolDefinition(
            name: "sky_info",
            description: "Get sky, catalog, and weather information. The catalog contains ~14,000 objects (NGC, IC, Messier, Barnard, Caldwell, named stars). Actions: sky_conditions (sun/moon/darkness), object_altitude (look up any object by name/ID — e.g. 'Horsehead', 'M42', 'NGC7000', 'Sirius'), suggest_targets (best targets above horizon), catalog_search (search full catalog with filters and observation window constraints), weather_current (current weather), weather_forecast (24h hourly forecast), weather_tonight (night hours imaging forecast).",
            parameters: [
                "type": "object",
                "properties": [
                    "action": [
                        "type": "string",
                        "enum": ["sky_conditions", "object_altitude", "suggest_targets", "catalog_search", "weather_current", "weather_forecast", "weather_tonight"],
                        "description": "The query to perform"
                    ] as [String: Any],
                    "object_id": [
                        "type": "string",
                        "description": "Object name or ID to look up (e.g. 'M42', 'NGC7000', 'Horsehead', 'Sirius'). Searches by ID, name, common names, and cross-references. Required for object_altitude."
                    ] as [String: Any],
                    "search": [
                        "type": "string",
                        "description": "Search text to filter catalog entries by name or ID (e.g. 'orion', 'M31'). For catalog_search."
                    ] as [String: Any],
                    "filter": [
                        "type": "string",
                        "enum": ["all", "galaxies", "nebulae", "clusters", "planets", "above_horizon"],
                        "description": "Category filter for catalog_search (default all)"
                    ] as [String: Any],
                    "min_altitude": [
                        "type": "number",
                        "description": "Minimum altitude in degrees for suggest_targets (default 20)"
                    ] as [String: Any],
                    "object_type": [
                        "type": "string",
                        "enum": ["all", "galaxy", "nebula", "cluster", "planetary", "globular"],
                        "description": "Filter targets by type for suggest_targets (default all)"
                    ] as [String: Any]
                ] as [String: Any],
                "required": ["action"]
            ] as [String: Any]
        )
    }

    var requiresConfirmation: Bool { true }

    func describeAction(arguments: [String: Any]) -> String {
        let action = arguments["action"] as? String ?? "unknown"
        switch action {
        case "sky_conditions": return "Check sky conditions (sun, moon, darkness)"
        case "object_altitude":
            let obj = arguments["object_id"] as? String ?? "?"
            return "Check altitude of \(obj)"
        case "suggest_targets": return "Suggest observable targets"
        case "catalog_search":
            let search = arguments["search"] as? String ?? ""
            let filter = arguments["filter"] as? String ?? "all"
            return "Search catalog\(search.isEmpty ? "" : " for '\(search)'")\(filter == "all" ? "" : " (\(filter))")"
        case "weather_current": return "Check current weather"
        case "weather_forecast": return "Get 24h weather forecast"
        case "weather_tonight": return "Get tonight's imaging forecast"
        default: return "Sky info: \(action)"
        }
    }

    func execute(arguments: [String: Any]) async throws -> String {
        let action = arguments["action"] as? String ?? ""
        let lat = UserDefaults.standard.double(forKey: "observerLat")
        let lon = UserDefaults.standard.double(forKey: "observerLon")
        let now = Date()

        switch action {
        case "sky_conditions":
            let sunAlt = SkyObjectsService.sunAltitude(lat: lat, lon: lon, date: now)
            let moonAlt = SkyObjectsService.moonAltitude(lat: lat, lon: lon, date: now)
            let moonIllum = SkyObjectsService.moonIllumination(date: now)

            let darkness: String
            if sunAlt < -18 { darkness = "Astronomical twilight (dark sky)" }
            else if sunAlt < -12 { darkness = "Nautical twilight" }
            else if sunAlt < -6 { darkness = "Civil twilight" }
            else if sunAlt < 0 { darkness = "Sun below horizon but not dark" }
            else { darkness = "Daytime" }

            return """
            Sky Conditions at \(formatDate(now)):
            - Sun altitude: \(String(format: "%.1f", sunAlt))\u{00B0} (\(darkness))
            - Moon altitude: \(String(format: "%.1f", moonAlt))\u{00B0}
            - Moon illumination: \(String(format: "%.0f", moonIllum * 100))%
            - Observer: \(String(format: "%.2f", lat))\u{00B0}N, \(String(format: "%.2f", lon))\u{00B0}E
            """

        case "object_altitude":
            guard let objId = arguments["object_id"] as? String else {
                return "Error: object_id is required."
            }
            let query = objId.lowercased()
            // Search by ID first, then by searchText (name, common names, identifiers)
            let obj = messierCatalog.first(where: { $0.id.lowercased() == query })
                ?? messierCatalog.first(where: { $0.searchText.contains(query) })
            guard let obj else {
                return "Error: Object '\(objId)' not found in catalog. Try catalog_search to find it."
            }
            let alt = SkyObjectsService.objectAltitude(raDeg: obj.raDeg, decDeg: obj.decDeg, lat: lat, lon: lon, date: now)
            let sizeStr = obj.sizeMajor > 0 ? String(format: "%.1f' x %.1f'", obj.sizeMajor, obj.sizeMinor > 0 ? obj.sizeMinor : obj.sizeMajor) : "unknown"
            return """
            \(obj.id) - \(obj.name):
            - Type: \(obj.type.rawValue)
            - Constellation: \(obj.constellation.isEmpty ? "N/A" : obj.constellation)
            - Magnitude: \(obj.magnitude < 90 ? String(format: "%.1f", obj.magnitude) : "N/A")
            - Size: \(sizeStr)
            - RA: \(String(format: "%.3f", obj.raHours))h, Dec: \(String(format: "%.2f", obj.decDeg))\u{00B0}
            - Current altitude: \(String(format: "%.1f", alt))\u{00B0}
            - \(alt > 20 ? "Good for imaging" : alt > 0 ? "Low on horizon" : "Below horizon")
            \(obj.commonNames.isEmpty ? "" : "- Also known as: \(obj.commonNames)")
            \(obj.identifiers.isEmpty ? "" : "- Cross-references: \(obj.identifiers)")
            """

        case "suggest_targets":
            let minAlt = arguments["min_altitude"] as? Double ?? 20.0
            let typeFilter = arguments["object_type"] as? String ?? "all"

            var candidates = messierCatalog
            if typeFilter != "all" {
                candidates = candidates.filter { $0.type.rawValue.lowercased() == typeFilter }
            }

            let withAlt = candidates.compactMap { obj -> (MessierObject, Double)? in
                let alt = SkyObjectsService.objectAltitude(raDeg: obj.raDeg, decDeg: obj.decDeg, lat: lat, lon: lon, date: now)
                return alt >= minAlt ? (obj, alt) : nil
            }
            .sorted { $0.1 > $1.1 }
            .prefix(10)

            if withAlt.isEmpty {
                return "No Messier objects currently above \(String(format: "%.0f", minAlt))\u{00B0} altitude\(typeFilter != "all" ? " of type \(typeFilter)" : "")."
            }

            var result = "Top targets above \(String(format: "%.0f", minAlt))\u{00B0} altitude:\n"
            for (obj, alt) in withAlt {
                result += "- \(obj.id) \(obj.name) (\(obj.type.rawValue), mag \(String(format: "%.1f", obj.magnitude))) at \(String(format: "%.1f", alt))\u{00B0} — RA \(String(format: "%.3f", obj.raHours))h Dec \(String(format: "%.1f", obj.decDeg))\u{00B0}\n"
            }
            return result

        case "catalog_search":
            return await catalogSearch(arguments: arguments, lat: lat, lon: lon)

        // MARK: - Weather Actions

        case "weather_current":
            await weatherService.fetch(lat: lat, lon: lon)
            guard let cw = weatherService.currentWeather else {
                return "Weather data not available. Check internet connection."
            }
            let dewMargin = cw.temperature - cw.dewPoint
            return """
            Current Weather:
            - Temperature: \(String(format: "%.1f", cw.temperature))\u{00B0}C
            - Cloud cover: \(cw.cloudCover)%
            - Humidity: \(cw.humidity)%
            - Dew point: \(String(format: "%.1f", cw.dewPoint))\u{00B0}C (margin: \(String(format: "%.1f", dewMargin))\u{00B0}C, risk: \(dewMargin < 2 ? "HIGH" : dewMargin < 5 ? "moderate" : "low"))
            - Wind: \(String(format: "%.0f", cw.windSpeed)) km/h
            - Imaging: \(cw.cloudCover <= 15 ? "Excellent" : cw.cloudCover <= 35 ? "Good" : cw.cloudCover <= 60 ? "Fair" : "Poor — too cloudy")
            """

        case "weather_forecast":
            await weatherService.fetch(lat: lat, lon: lon)
            let next24h = weatherService.hourlyForecast.filter { $0.time > Date() }.prefix(24)
            guard !next24h.isEmpty else {
                return "Forecast data not available."
            }
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            var lines = ["24h Hourly Forecast:"]
            lines.append("Time  | Cloud% | Temp   | Humid% | Wind    | Dew Risk | Imaging")
            lines.append(String(repeating: "-", count: 72))
            for hour in next24h {
                lines.append("\(f.string(from: hour.time))  | \(String(format: "%3d", hour.cloudCover))%   | \(String(format: "%5.1f", hour.temperature))\u{00B0}C | \(String(format: "%3d", hour.humidity))%   | \(String(format: "%4.0f", hour.windSpeed))km/h | \(String(format: "%-8s", hour.dewRisk.rawValue)) | \(hour.imagingCondition.rawValue)")
            }
            return lines.joined(separator: "\n")

        case "weather_tonight":
            await weatherService.fetch(lat: lat, lon: lon)
            let cal = Calendar.current
            let nightHours = weatherService.hourlyForecast.filter { hour in
                let h = cal.component(.hour, from: hour.time)
                return hour.time > Date() && (h >= 18 || h <= 6)
            }.prefix(12)

            guard !nightHours.isEmpty else {
                return "No night hours in the forecast window."
            }

            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            var lines = ["Tonight's Imaging Forecast:"]
            for hour in nightHours {
                let icon = hour.cloudCover <= 15 ? "clear" : hour.cloudCover <= 35 ? "mostly clear" : hour.cloudCover <= 60 ? "partly cloudy" : "cloudy"
                lines.append("\(f.string(from: hour.time)): \(icon) (\(hour.cloudCover)% clouds), \(String(format: "%.0f", hour.temperature))\u{00B0}C, dew risk: \(hour.dewRisk.rawValue)")
            }

            let clearCount = nightHours.filter { $0.cloudCover <= 30 }.count
            lines.append("\nSummary: \(clearCount) clear hours out of \(nightHours.count) night hours")

            if let best = nightHours.min(by: { $0.cloudCover < $1.cloudCover }) {
                lines.append("Best window: \(f.string(from: best.time)) with \(best.cloudCover)% clouds")
            }

            return lines.joined(separator: "\n")

        default:
            return "Error: Unknown action '\(action)'."
        }
    }

    private func catalogSearch(arguments: [String: Any], lat: Double, lon: Double) async -> String {
        let search = arguments["search"] as? String ?? ""
        let filterRaw = arguments["filter"] as? String ?? "all"

        let catalogFilter: MountTabViewModel.CatalogFilter
        switch filterRaw {
        case "galaxies": catalogFilter = .galaxies
        case "nebulae": catalogFilter = .nebulae
        case "clusters": catalogFilter = .clusters
        case "planets": catalogFilter = .planets
        case "above_horizon": catalogFilter = .aboveHorizon
        default: catalogFilter = .all
        }

        // Read observation window from settings
        let obsEnabled = UserDefaults.standard.bool(forKey: "obsWindowEnabled")
        let obsMinAlt = UserDefaults.standard.double(forKey: "obsWindowMinAlt")
        let obsMaxAlt = UserDefaults.standard.double(forKey: "obsWindowMaxAlt")
        let obsAzFrom = UserDefaults.standard.double(forKey: "obsWindowAzFrom")
        let obsAzTo = UserDefaults.standard.double(forKey: "obsWindowAzTo")

        let entries = await Task.detached(priority: .userInitiated) {
            MountTabViewModel.buildCatalogEntries(
                lat: lat, lon: lon,
                filter: catalogFilter, search: search,
                refDate: Date(),
                obsEnabled: obsEnabled,
                obsMinAlt: obsMinAlt > 0 ? obsMinAlt : 10,
                obsMaxAlt: obsMaxAlt > 0 ? obsMaxAlt : 90,
                obsAzFrom: obsAzFrom, obsAzTo: obsAzTo > 0 ? obsAzTo : 360,
                catalog: messierCatalog
            )
        }.value

        if entries.isEmpty {
            return "No catalog entries found\(search.isEmpty ? "" : " matching '\(search)'") with filter '\(filterRaw)'."
        }

        // Sort by altitude descending, take top 15
        let sorted = entries.sorted { $0.altDeg > $1.altDeg }.prefix(15)
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm"
        let now = Date()

        var lines = ["Catalog results (\(entries.count) total, showing top \(sorted.count) by altitude):"]
        for entry in sorted {
            var info = "\(entry.name)"
            if !entry.detail.isEmpty { info += " (\(entry.detail))" }
            info += " — Alt \(String(format: "%.1f", entry.altDeg))\u{00B0}, Az \(String(format: "%.0f", entry.azDeg))\u{00B0}"
            info += ", RA \(String(format: "%.3f", entry.raHours))h Dec \(String(format: "%.1f", entry.decDeg))\u{00B0}"

            let vis = entry.visibility
            if vis.isCircumpolar {
                info += " [circumpolar]"
            } else if vis.neverRises {
                info += " [never rises]"
            } else {
                if let rise = vis.riseHoursFromNow {
                    let riseTime = now.addingTimeInterval(rise * 3600)
                    info += ", rises \(tf.string(from: riseTime))"
                }
                if let set = vis.setHoursFromNow {
                    let setTime = now.addingTimeInterval(set * 3600)
                    info += ", sets \(tf.string(from: setTime))"
                }
            }
            info += ", peak \(String(format: "%.0f", vis.peakAltDeg))\u{00B0}"

            if let darkStart = vis.darkStartHours {
                let darkTime = now.addingTimeInterval(darkStart * 3600)
                info += ", dark from \(tf.string(from: darkTime))"
            }

            lines.append("- \(entry.id): \(info)")
        }

        if obsEnabled {
            lines.append("\nObservation window active: alt \(String(format: "%.0f", obsMinAlt))-\(String(format: "%.0f", obsMaxAlt))\u{00B0}, az \(String(format: "%.0f", obsAzFrom))-\(String(format: "%.0f", obsAzTo))\u{00B0}")
        }

        return lines.joined(separator: "\n")
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm z"
        return f.string(from: date)
    }
}
