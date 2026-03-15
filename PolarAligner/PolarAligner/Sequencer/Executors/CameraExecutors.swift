import Foundation

/// Executor for `set_cooler` — enables the camera cooler and waits until
/// the sensor temperature reaches the target (within tolerance).
struct SetCoolerExecutor: InstructionExecutor {
    let instructionType = "set_cooler"

    /// How often to check the sensor temperature.
    private let pollIntervalSeconds: Double = 3

    func execute(instruction: SequenceInstruction, context: ExecutionContext) async throws {
        guard let camera = context.deviceResolver.camera() else {
            throw ExecutorError.deviceNotAvailable("imaging_camera")
        }

        let enabled = instruction.params["enabled"]?.boolValue ?? true
        let targetC = instruction.params["target_celsius"]?.intValue ?? -10
        let toleranceC = instruction.params["tolerance_c"]?.doubleValue ?? 1.0
        let timeoutSeconds = instruction.params["timeout_sec"]?.doubleValue ?? 600

        if !enabled {
            context.status("Turning cooler off")
            camera.setCoolerOff()
            camera.stopTemperaturePolling()
            return
        }

        context.status("Setting cooler to \(targetC)°C")
        camera.setCoolerOn(targetCelsius: targetC)

        // Ensure temperature polling is active so sensorTempC stays up to date
        camera.startTemperaturePolling()

        // Wait for the sensor to reach target temperature
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var lastReportedTemp: Double?

        while Date() < deadline {
            try Task.checkCancellation()

            if let currentTemp = camera.sensorTempC {
                let delta = abs(currentTemp - Double(targetC))

                // Update status on every poll so the UI stays live
                if lastReportedTemp == nil || abs(currentTemp - (lastReportedTemp ?? 0)) >= 0.3 {
                    let power = camera.coolerPowerPercent.map { " [\($0)%]" } ?? ""
                    context.status(String(format: "Cooling: %.1f°C → %d°C (Δ%.1f°C)%@", currentTemp, targetC, delta, power))
                    lastReportedTemp = currentTemp
                }

                if delta <= toleranceC {
                    context.status(String(format: "Cooler reached target: %.1f°C", currentTemp))
                    return
                }
            } else {
                context.status("Cooling to \(targetC)°C (waiting for temperature reading...)")
            }

            try await Task.sleep(for: .seconds(pollIntervalSeconds))
        }

        // Timed out but don't fail — cooler is still running, just slow
        let finalTemp = camera.sensorTempC.map { String(format: "%.1f°C", $0) } ?? "unknown"
        context.status("Cooler timeout after \(Int(timeoutSeconds))s — current: \(finalTemp), target: \(targetC)°C. Continuing.")
    }
}

/// Executor for `warmup` — gradually warms the camera sensor.
struct WarmupExecutor: InstructionExecutor {
    let instructionType = "warmup"

    func execute(instruction: SequenceInstruction, context: ExecutionContext) async throws {
        guard let camera = context.deviceResolver.camera() else {
            throw ExecutorError.deviceNotAvailable("imaging_camera")
        }

        context.status("Warming up camera")
        camera.warmup()
        camera.startTemperaturePolling()

        // Poll until cooler is off or sensor is near ambient
        let deadline = Date().addingTimeInterval(300)  // 5 min max
        while Date() < deadline {
            try Task.checkCancellation()

            if !camera.coolerEnabled {
                context.status("Camera warmed up, cooler off")
                return
            }

            if let temp = camera.sensorTempC {
                context.status(String(format: "Warming up: %.1f°C", temp))
                if temp >= 15 {
                    context.status("Camera warm enough, cooler off")
                    camera.setCoolerOff()
                    return
                }
            }

            try await Task.sleep(for: .seconds(3))
        }

        context.status("Warmup complete")
    }
}
