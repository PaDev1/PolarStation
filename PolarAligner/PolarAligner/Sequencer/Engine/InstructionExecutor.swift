import Foundation

/// Context passed to instruction executors during execution.
struct ExecutionContext {
    let deviceResolver: DeviceResolver
    let targetInfo: TargetInfo?
    let progress: SequenceProgress
    let onStatus: (String) -> Void

    func status(_ message: String) {
        onStatus(message)
    }
}

/// Protocol for executing a specific instruction type.
@MainActor
protocol InstructionExecutor {
    /// The instruction type string this executor handles (e.g. "capture_frames").
    var instructionType: String { get }

    /// Execute the instruction. Throws on failure, supports cancellation via Task.
    func execute(instruction: SequenceInstruction, context: ExecutionContext) async throws
}

/// Registry mapping instruction type strings to their executors.
@MainActor
class InstructionRegistry {
    private var executors: [String: InstructionExecutor] = [:]

    func register(_ executor: InstructionExecutor) {
        executors[executor.instructionType] = executor
    }

    func executor(for type: String) -> InstructionExecutor? {
        executors[type]
    }

    var registeredTypes: [String] {
        Array(executors.keys).sorted()
    }
}
