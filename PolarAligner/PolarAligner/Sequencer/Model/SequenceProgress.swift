import Foundation

/// Persisted execution state for resuming an interrupted sequence.
struct SequenceProgress: Codable, Hashable {
    var containerStates: [UUID: ContainerState]
    var lastSavedAt: Date

    init() {
        self.containerStates = [:]
        self.lastSavedAt = Date()
    }

    mutating func update(containerId: UUID, state: ContainerState) {
        containerStates[containerId] = state
        lastSavedAt = Date()
    }
}

/// Execution state of a single container.
struct ContainerState: Codable, Hashable {
    var currentItemIndex: Int
    var iterationCount: Int
    var frameCounts: [String: Int]  // filter name → count

    init() {
        self.currentItemIndex = 0
        self.iterationCount = 0
        self.frameCounts = [:]
    }
}
