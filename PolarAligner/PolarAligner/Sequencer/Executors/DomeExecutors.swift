import Foundation

/// Executor for `slew_dome` — slews dome to a target azimuth.
struct SlewDomeExecutor: InstructionExecutor {
    let instructionType = "slew_dome"

    func execute(instruction: SequenceInstruction, context: ExecutionContext) async throws {
        guard let dome = context.deviceResolver.dome() else {
            throw ExecutorError.deviceNotAvailable("dome")
        }
        let azimuth = instruction.params["azimuth"]?.doubleValue ?? 0
        context.status("Slewing dome to \(String(format: "%.1f", azimuth))°")
        dome.slewToAzimuth(azimuth)

        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(2))
            dome.refreshStatus()
            try await Task.sleep(for: .seconds(0.5))
            if !dome.isSlewing {
                context.status("Dome at \(String(format: "%.1f", dome.azimuth))°")
                return
            }
        }
        context.status("Dome slew timeout")
    }
}

/// Executor for `open_shutter`.
struct OpenShutterExecutor: InstructionExecutor {
    let instructionType = "open_shutter"

    func execute(instruction: SequenceInstruction, context: ExecutionContext) async throws {
        guard let dome = context.deviceResolver.dome() else {
            throw ExecutorError.deviceNotAvailable("dome")
        }
        context.status("Opening shutter")
        dome.openShutter()

        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(2))
            dome.refreshStatus()
            try await Task.sleep(for: .seconds(0.5))
            if dome.shutterStatus == 0 {  // 0 = open
                context.status("Shutter open")
                return
            }
        }
        context.status("Shutter open timeout — status: \(dome.shutterLabel)")
    }
}

/// Executor for `close_shutter`.
struct CloseShutterExecutor: InstructionExecutor {
    let instructionType = "close_shutter"

    func execute(instruction: SequenceInstruction, context: ExecutionContext) async throws {
        guard let dome = context.deviceResolver.dome() else {
            throw ExecutorError.deviceNotAvailable("dome")
        }
        context.status("Closing shutter")
        dome.closeShutter()

        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(2))
            dome.refreshStatus()
            try await Task.sleep(for: .seconds(0.5))
            if dome.shutterStatus == 1 {  // 1 = closed
                context.status("Shutter closed")
                return
            }
        }
        context.status("Shutter close timeout — status: \(dome.shutterLabel)")
    }
}

/// Executor for `park_dome`.
struct ParkDomeExecutor: InstructionExecutor {
    let instructionType = "park_dome"

    func execute(instruction: SequenceInstruction, context: ExecutionContext) async throws {
        guard let dome = context.deviceResolver.dome() else {
            throw ExecutorError.deviceNotAvailable("dome")
        }
        context.status("Parking dome")
        dome.park()

        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(2))
            dome.refreshStatus()
            try await Task.sleep(for: .seconds(0.5))
            if dome.atPark {
                context.status("Dome parked")
                return
            }
        }
        context.status("Dome park timeout")
    }
}

/// Executor for `home_dome`.
struct HomeDomeExecutor: InstructionExecutor {
    let instructionType = "home_dome"

    func execute(instruction: SequenceInstruction, context: ExecutionContext) async throws {
        guard let dome = context.deviceResolver.dome() else {
            throw ExecutorError.deviceNotAvailable("dome")
        }
        context.status("Finding dome home")
        dome.findHome()

        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(2))
            dome.refreshStatus()
            try await Task.sleep(for: .seconds(0.5))
            if dome.atHome {
                context.status("Dome at home")
                return
            }
        }
        context.status("Dome home timeout")
    }
}
