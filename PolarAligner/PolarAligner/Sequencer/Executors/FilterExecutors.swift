import Foundation

/// Executor for `switch_filter` — changes the filter wheel position.
struct SwitchFilterExecutor: InstructionExecutor {
    let instructionType = "switch_filter"

    func execute(instruction: SequenceInstruction, context: ExecutionContext) async throws {
        guard let filterWheel = context.deviceResolver.filterWheel() else {
            throw ExecutorError.deviceNotAvailable("filter_wheel")
        }

        if let position = instruction.params["filter_position"]?.intValue {
            context.status("Switching to filter position \(position)")
            filterWheel.selectFilter(position: position)
        } else if let name = instruction.params["filter_name"]?.stringValue {
            // Find position by name
            if let idx = filterWheel.filterNames.firstIndex(of: name) {
                context.status("Switching to filter: \(name)")
                filterWheel.selectFilter(position: idx)
            } else {
                throw ExecutorError.missingParameter("Filter '\(name)' not found")
            }
        } else {
            throw ExecutorError.missingParameter("switch_filter requires filter_name or filter_position")
        }

        // Brief settle time for filter wheel
        try await Task.sleep(for: .milliseconds(500))
    }
}
