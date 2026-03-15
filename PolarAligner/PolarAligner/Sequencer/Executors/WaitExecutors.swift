import Foundation

/// Executor for `wait_time` — waits a specified number of seconds.
struct WaitTimeExecutor: InstructionExecutor {
    let instructionType = "wait_time"

    func execute(instruction: SequenceInstruction, context: ExecutionContext) async throws {
        let seconds = instruction.params["seconds"]?.doubleValue ?? 0
        context.status("Waiting \(Int(seconds))s")
        try await Task.sleep(for: .seconds(seconds))
    }
}

/// Executor for `wait_until_time` — waits until a specific UTC time.
struct WaitUntilTimeExecutor: InstructionExecutor {
    let instructionType = "wait_until_time"

    func execute(instruction: SequenceInstruction, context: ExecutionContext) async throws {
        guard let timeStr = instruction.params["utc_time"]?.stringValue else {
            context.status("wait_until_time: missing utc_time parameter")
            return
        }
        let formatter = ISO8601DateFormatter()
        guard let targetTime = formatter.date(from: timeStr) else {
            context.status("wait_until_time: invalid time format")
            return
        }

        let interval = targetTime.timeIntervalSinceNow
        if interval > 0 {
            context.status("Waiting until \(timeStr)")
            try await Task.sleep(for: .seconds(interval))
        }
    }
}

/// Executor for `wait_until_local_time` — waits until a specific local time (hour:minute).
struct WaitUntilLocalTimeExecutor: InstructionExecutor {
    let instructionType = "wait_until_local_time"

    func execute(instruction: SequenceInstruction, context: ExecutionContext) async throws {
        let hour = instruction.params["hour"]?.intValue ?? 0
        let minute = instruction.params["minute"]?.intValue ?? 0

        let cal = Calendar.current
        let now = Date()

        // Find the next occurrence of this local time
        var target = cal.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
        if target <= now {
            // Already passed today — wait until tomorrow
            target = cal.date(byAdding: .day, value: 1, to: target) ?? target
        }

        let interval = target.timeIntervalSince(now)
        if interval > 0 {
            let timeStr = String(format: "%02d:%02d", hour, minute)
            context.status("Waiting until \(timeStr)")
            try await Task.sleep(for: .seconds(interval))
        }
    }
}

/// Executor for `annotation` — logs a message, no device interaction.
struct AnnotationExecutor: InstructionExecutor {
    let instructionType = "annotation"

    func execute(instruction: SequenceInstruction, context: ExecutionContext) async throws {
        let message = instruction.params["message"]?.stringValue ?? ""
        context.status("Note: \(message)")
    }
}
