import Foundation

/// Hourly weather data point for astrophotography planning.
struct WeatherHour: Identifiable {
    let id: Date
    let time: Date
    let cloudCover: Int          // total %
    let cloudCoverLow: Int       // low clouds %
    let cloudCoverMid: Int       // mid clouds %
    let cloudCoverHigh: Int      // high clouds (cirrus) %
    let temperature: Double      // °C
    let humidity: Int             // %
    let dewPoint: Double         // °C
    let windSpeed: Double        // km/h
    let visibility: Double       // meters
    let precipProbability: Int   // %

    /// Risk of dew forming on optics (temp close to dew point).
    var dewRisk: DewRisk {
        let margin = temperature - dewPoint
        if margin < 2 { return .high }
        if margin < 5 { return .moderate }
        return .low
    }

    /// Simple imaging suitability based on cloud cover.
    var imagingCondition: ImagingCondition {
        if cloudCover <= 15 { return .excellent }
        if cloudCover <= 35 { return .good }
        if cloudCover <= 60 { return .fair }
        return .poor
    }

    enum DewRisk: String { case low, moderate, high }
    enum ImagingCondition: String { case excellent, good, fair, poor }
}

/// Current weather snapshot.
struct CurrentWeather {
    let temperature: Double
    let windSpeed: Double
    let cloudCover: Int
    let humidity: Int
    let dewPoint: Double
}

/// Fetches weather data from the Open-Meteo free API.
/// No API key required. Uses observer lat/lon from UserDefaults.
@MainActor
final class WeatherService: ObservableObject {
    @Published var currentWeather: CurrentWeather?
    @Published var hourlyForecast: [WeatherHour] = []
    @Published var lastFetchDate: Date?
    @Published var error: String?
    @Published var isFetching = false

    private var refreshTimer: Timer?
    private let cacheInterval: TimeInterval = 1800 // 30 minutes

    /// Fetch weather for the given coordinates. Caches for 30 minutes.
    func fetch(lat: Double, lon: Double) async {
        // Skip if recently fetched
        if let lastFetch = lastFetchDate, Date().timeIntervalSince(lastFetch) < cacheInterval {
            return
        }
        await fetchForced(lat: lat, lon: lon)
    }

    /// Force fetch weather regardless of cache.
    func fetchForced(lat: Double, lon: Double) async {
        guard !isFetching else { return }
        isFetching = true
        error = nil

        do {
            let hourlyVars = [
                "cloud_cover", "cloud_cover_low", "cloud_cover_mid", "cloud_cover_high",
                "temperature_2m", "relative_humidity_2m", "dew_point_2m",
                "wind_speed_10m", "visibility", "precipitation_probability"
            ].joined(separator: ",")

            let currentVars = "temperature_2m,wind_speed_10m,cloud_cover,relative_humidity_2m,dew_point_2m"

            let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&hourly=\(hourlyVars)&current=\(currentVars)&timezone=auto&forecast_days=2"

            guard let url = URL(string: urlString) else {
                throw WeatherError.invalidURL
            }

            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw WeatherError.httpError
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw WeatherError.parseError("Invalid JSON")
            }

            // Parse current weather
            if let current = json["current"] as? [String: Any] {
                currentWeather = CurrentWeather(
                    temperature: current["temperature_2m"] as? Double ?? 0,
                    windSpeed: current["wind_speed_10m"] as? Double ?? 0,
                    cloudCover: current["cloud_cover"] as? Int ?? 0,
                    humidity: current["relative_humidity_2m"] as? Int ?? 0,
                    dewPoint: current["dew_point_2m"] as? Double ?? 0
                )
            }

            // Parse hourly forecast
            if let hourly = json["hourly"] as? [String: Any],
               let times = hourly["time"] as? [String],
               let cloudCover = hourly["cloud_cover"] as? [Any],
               let cloudLow = hourly["cloud_cover_low"] as? [Any],
               let cloudMid = hourly["cloud_cover_mid"] as? [Any],
               let cloudHigh = hourly["cloud_cover_high"] as? [Any],
               let temps = hourly["temperature_2m"] as? [Any],
               let humidity = hourly["relative_humidity_2m"] as? [Any],
               let dewPoints = hourly["dew_point_2m"] as? [Any],
               let wind = hourly["wind_speed_10m"] as? [Any],
               let vis = hourly["visibility"] as? [Any],
               let precip = hourly["precipitation_probability"] as? [Any] {

                // Open-Meteo returns "2026-03-16T00:00" (no seconds)
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
                formatter.locale = Locale(identifier: "en_US_POSIX")

                var hours: [WeatherHour] = []
                for i in 0..<times.count {
                    guard let date = formatter.date(from: times[i]) else { continue }
                    hours.append(WeatherHour(
                        id: date,
                        time: date,
                        cloudCover: asInt(cloudCover[i]),
                        cloudCoverLow: asInt(cloudLow[i]),
                        cloudCoverMid: asInt(cloudMid[i]),
                        cloudCoverHigh: asInt(cloudHigh[i]),
                        temperature: asDouble(temps[i]),
                        humidity: asInt(humidity[i]),
                        dewPoint: asDouble(dewPoints[i]),
                        windSpeed: asDouble(wind[i]),
                        visibility: asDouble(vis[i]),
                        precipProbability: asInt(precip[i])
                    ))
                }
                hourlyForecast = hours
            }

            lastFetchDate = Date()
            isFetching = false
        } catch {
            self.error = error.localizedDescription
            isFetching = false
        }
    }

    /// Start auto-refreshing every 30 minutes.
    func startAutoRefresh(lat: Double, lon: Double) {
        stopAutoRefresh()
        Task { await fetch(lat: lat, lon: lon) }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: cacheInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.fetchForced(lat: lat, lon: lon)
            }
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Convenience for LLM / UI

    /// Summary string for the AI assistant system prompt.
    func summaryForLLM() -> String {
        var parts: [String] = []

        if let cw = currentWeather {
            parts.append("Current weather: \(String(format: "%.1f", cw.temperature))\u{00B0}C, cloud cover \(cw.cloudCover)%, humidity \(cw.humidity)%, dew point \(String(format: "%.1f", cw.dewPoint))\u{00B0}C, wind \(String(format: "%.0f", cw.windSpeed)) km/h")
            let dewMargin = cw.temperature - cw.dewPoint
            if dewMargin < 2 {
                parts.append("WARNING: High dew risk — temperature very close to dew point")
            }
        }

        // 24h hourly forecast
        let next24h = hourlyForecast.filter { $0.time > Date() }.prefix(24)
        if !next24h.isEmpty {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            var lines: [String] = ["24h forecast (time: cloud% temp\u{00B0}C wind humidity% dew-risk):"]
            for hour in next24h {
                lines.append("  \(f.string(from: hour.time)): \(hour.cloudCover)% \(String(format: "%.0f", hour.temperature))\u{00B0}C \(String(format: "%.0f", hour.windSpeed))km/h \(hour.humidity)% dew:\(hour.dewRisk.rawValue)")
            }
            parts.append(lines.joined(separator: "\n"))

            let nightHours = next24h.filter {
                let h = Calendar.current.component(.hour, from: $0.time)
                return h >= 18 || h <= 6
            }
            let clearNightHours = nightHours.filter { $0.cloudCover <= 30 }
            if !nightHours.isEmpty {
                parts.append("\(clearNightHours.count) clear night hours out of \(nightHours.count)")
            }
        }

        return parts.isEmpty ? "Weather data not available" : parts.joined(separator: "\n")
    }

    /// Hours tonight suitable for imaging (cloud cover ≤ threshold).
    func clearHoursTonight(maxCloudCover: Int = 30) -> [WeatherHour] {
        let cal = Calendar.current
        return hourlyForecast.filter { hour in
            let h = cal.component(.hour, from: hour.time)
            let isTonight = hour.time > Date()
            return isTonight && (h >= 18 || h <= 6) && hour.cloudCover <= maxCloudCover
        }
    }

    // MARK: - Helpers

    private func asInt(_ value: Any) -> Int {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        return 0
    }

    private func asDouble(_ value: Any) -> Double {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return 0
    }
}

enum WeatherError: LocalizedError {
    case invalidURL
    case httpError
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid weather API URL"
        case .httpError: return "Weather API request failed"
        case .parseError(let msg): return "Weather parse error: \(msg)"
        }
    }
}
