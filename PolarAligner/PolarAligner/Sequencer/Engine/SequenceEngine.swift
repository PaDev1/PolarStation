import Foundation

/// Main sequence execution engine. Walks the container tree, executes
/// instructions, evaluates conditions, and fires triggers.
@MainActor
class SequenceEngine: ObservableObject {
    @Published var isRunning = false
    @Published var isPaused = false
    @Published var currentInstruction: String = ""
    @Published var statusMessage: String = "Idle"
    @Published var totalFramesCaptured: Int = 0
    @Published var currentInstructionId: UUID?
    @Published var completedIds: Set<UUID> = []
    @Published var progress: SequenceProgress = SequenceProgress()

    let deviceResolver = DeviceResolver()
    let instructionRegistry = InstructionRegistry()
    let conditionEvaluator = ConditionEvaluator()
    let triggerMonitor = TriggerMonitor()

    private var runTask: Task<Void, Never>?
    private var pauseContinuation: CheckedContinuation<Void, Never>?

    init() {
        registerBuiltinExecutors()
    }

    private func registerBuiltinExecutors() {
        // Mount
        instructionRegistry.register(SlewToTargetExecutor())
        instructionRegistry.register(CenterTargetExecutor())
        instructionRegistry.register(ParkMountExecutor())
        instructionRegistry.register(UnparkMountExecutor())
        instructionRegistry.register(GoHomeExecutor())
        instructionRegistry.register(StartTrackingExecutor())

        // Camera
        instructionRegistry.register(CaptureFramesExecutor())
        instructionRegistry.register(SetCoolerExecutor())
        instructionRegistry.register(WarmupExecutor())

        // Guide
        instructionRegistry.register(StartGuidingExecutor())
        instructionRegistry.register(StopGuidingExecutor())
        instructionRegistry.register(DitherExecutor())

        // Filter
        instructionRegistry.register(SwitchFilterExecutor())

        // Plate solve
        instructionRegistry.register(PlatesolveExecutor())

        // Wait / utility
        instructionRegistry.register(WaitTimeExecutor())
        instructionRegistry.register(WaitUntilTimeExecutor())
        instructionRegistry.register(WaitUntilLocalTimeExecutor())
        instructionRegistry.register(AnnotationExecutor())

        // Focuser
        instructionRegistry.register(MoveFocuserExecutor())
        instructionRegistry.register(HaltFocuserExecutor())
        instructionRegistry.register(AutoFocusExecutor())

        // Dome
        instructionRegistry.register(SlewDomeExecutor())
        instructionRegistry.register(OpenShutterExecutor())
        instructionRegistry.register(CloseShutterExecutor())
        instructionRegistry.register(ParkDomeExecutor())
        instructionRegistry.register(HomeDomeExecutor())

        // Rotator
        instructionRegistry.register(MoveRotatorExecutor())

        // Switch
        instructionRegistry.register(SetSwitchExecutor())

        // Cover Calibrator
        instructionRegistry.register(OpenCoverExecutor())
        instructionRegistry.register(CloseCoverExecutor())
        instructionRegistry.register(CalibratorOnExecutor())
        instructionRegistry.register(CalibratorOffExecutor())

        // Safety / Weather
        instructionRegistry.register(WaitForSafeExecutor())
        instructionRegistry.register(LogWeatherExecutor())
    }

    // MARK: - Public API

    func start(document: SequenceDocument) {
        guard !isRunning else { return }
        isRunning = true
        isPaused = false
        statusMessage = "Running: \(document.name)"
        totalFramesCaptured = 0
        currentInstructionId = nil
        completedIds.removeAll()
        progress = document.progress ?? SequenceProgress()
        triggerMonitor.reset()

        runTask = Task {
            do {
                let context = ExecutionContext(
                    deviceResolver: deviceResolver,
                    targetInfo: nil,
                    progress: progress,
                    onStatus: { [weak self] msg in
                        self?.statusMessage = msg
                    }
                )
                try await executeContainer(document.rootContainer, context: context)
                statusMessage = "Sequence complete"
            } catch is CancellationError {
                statusMessage = "Sequence stopped"
            } catch {
                statusMessage = "Error: \(error.localizedDescription)"
            }
            isRunning = false
            isPaused = false
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        // Resume if paused so the task can actually cancel
        if let cont = pauseContinuation {
            pauseContinuation = nil
            cont.resume()
        }
    }

    func pause() {
        isPaused = true
        statusMessage = "Paused"
    }

    func resume() {
        isPaused = false
        statusMessage = "Resuming..."
        if let cont = pauseContinuation {
            pauseContinuation = nil
            cont.resume()
        }
    }

    // MARK: - Execution

    private func executeContainer(_ container: SequenceContainer, context: ExecutionContext) async throws {
        guard container.enabled else { return }

        let containerContext = ExecutionContext(
            deviceResolver: context.deviceResolver,
            targetInfo: container.target ?? context.targetInfo,
            progress: context.progress,
            onStatus: context.onStatus
        )

        let startTime = Date()
        var iteration = 0

        repeat {
            iteration += 1
            context.onStatus("[\(container.name)] iteration \(iteration)")

            switch container.type {
            case .sequential, .deepSkyObject:
                try await executeSequential(container, context: containerContext)
            case .parallel:
                try await executeParallel(container, context: containerContext)
            }

            // Check conditions — stop if ANY met
            let target = containerContext.targetInfo
            if conditionEvaluator.shouldStop(
                conditions: container.conditions,
                iterationCount: iteration,
                containerStartTime: startTime,
                totalFramesCaptured: totalFramesCaptured,
                targetRA: target?.ra,
                targetDec: target?.dec
            ) {
                break
            }

            // Save progress
            progress.update(containerId: container.id, state: ContainerState())

        } while !container.conditions.isEmpty  // no conditions = run once
    }

    private func executeSequential(_ container: SequenceContainer, context: ExecutionContext) async throws {
        for item in container.items {
            try Task.checkCancellation()
            try await checkPause()

            // Check triggers before
            try await triggerMonitor.checkBefore(
                triggers: container.triggers,
                containerId: container.id,
                context: context
            )

            try await executeItem(item, container: container, context: context)

            // Check triggers after
            try await triggerMonitor.checkAfter(
                triggers: container.triggers,
                containerId: container.id,
                framesCaptured: 0,
                currentFilter: nil,
                context: context
            )
        }
    }

    private func executeParallel(_ container: SequenceContainer, context: ExecutionContext) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for item in container.items {
                group.addTask { @MainActor in
                    try await self.executeItem(item, container: container, context: context)
                }
            }
            try await group.waitForAll()
        }
    }

    private func executeItem(_ item: SequenceItem, container: SequenceContainer, context: ExecutionContext) async throws {
        switch item {
        case .container(let child):
            try await executeContainer(child, context: context)
        case .instruction(let instruction):
            guard instruction.enabled else { return }
            try await executeInstruction(instruction, context: context)
        }
    }

    private func executeInstruction(_ instruction: SequenceInstruction, context: ExecutionContext) async throws {
        currentInstruction = instruction.type
        currentInstructionId = instruction.id
        context.onStatus("Executing: \(instruction.type)")

        guard let executor = instructionRegistry.executor(for: instruction.type) else {
            context.onStatus("No executor for instruction type: \(instruction.type)")
            return
        }

        try await executor.execute(instruction: instruction, context: context)
        completedIds.insert(instruction.id)
        currentInstructionId = nil
    }

    // MARK: - Pause Support

    private func checkPause() async throws {
        while isPaused {
            try Task.checkCancellation()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.pauseContinuation = continuation
            }
        }
    }
}
