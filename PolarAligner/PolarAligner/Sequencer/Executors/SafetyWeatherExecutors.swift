import Foundation

/// Executor for `wait_for_safe` — blocks until the safety monitor reports safe.
struct WaitForSafeExecutor: InstructionExecutor {
    let instructionType = "wait_for_safe"

    func execute(instruction: SequenceInstruction, context: ExecutionContext) async throws {
        guard let safety = context.deviceResolver.safetyMonitor() else {
            throw ExecutorError.deviceNotAvailable("safety_monitor")
        }
        let timeoutSec = instruction.params["timeout_sec"]?.doubleValue ?? 3600

        if safety.isSafe {
            context.status("Conditions safe")
            return
        }

        context.status("Waiting for safe conditions...")
        let deadline = Date().addingTimeInterval(timeoutSec)
        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(10))
            safety.refreshStatus()
            try await Task.sleep(for: .seconds(1))
            if safety.isSafe {
                context.status("Conditions now safe")
                return
            }
            context.status("Unsafe — waiting...")
        }
        throw ExecutorError.missingParameter("Safety monitor timeout after \(Int(timeoutSec))s — still unsafe")
    }
}

/// Executor for `log_weather` — reads current conditions and logs them.
struct LogWeatherExecutor: InstructionExecutor {
    let instructionType = "log_weather"

    func execute(instruction: SequenceInstruction, context: ExecutionContext) async throws {
        guard let weather = context.deviceResolver.observingConditions() else {
            throw ExecutorError.deviceNotAvailable("observing_conditions")
        }
        weather.refreshStatus()
        try await Task.sleep(for: .seconds(2))

        var parts: [String] = []
        if weather.temperature > -900 { parts.append(String(format: "%.1f°C", weather.temperature)) }
        if weather.humidity > -900 { parts.append(String(format: "%.0f%% RH", weather.humidity)) }
        if weather.dewpoint > -900 { parts.append(String(format: "Dew %.1f°C", weather.dewpoint)) }
        if weather.pressure > -900 { parts.append(String(format: "%.0f hPa", weather.pressure)) }
        if weather.windSpeed > -900 { parts.append(String(format: "Wind %.1f m/s", weather.windSpeed)) }
        if weather.cloudCover > -900 { parts.append(String(format: "Cloud %.0f%%", weather.cloudCover)) }
        if weather.starFwhm > -900 { parts.append(String(format: "FWHM %.1f\"", weather.starFwhm)) }

        let summary = parts.isEmpty ? "No data available" : parts.joined(separator: " | ")
        context.status("Weather: \(summary)")
    }
}
