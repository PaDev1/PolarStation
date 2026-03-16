import Foundation

/// A tool that the AI assistant can invoke to interact with the app.
@MainActor
protocol AssistantTool {
    /// JSON-schema definition sent to the LLM.
    var definition: ToolDefinition { get }

    /// Whether this tool requires user confirmation before execution.
    var requiresConfirmation: Bool { get }

    /// Human-readable description of the pending action (for the confirmation dialog).
    func describeAction(arguments: [String: Any]) -> String

    /// Execute the tool and return a result string for the LLM.
    func execute(arguments: [String: Any]) async throws -> String
}

/// Registry of all available assistant tools.
@MainActor
final class AssistantToolRegistry {
    private var tools: [String: AssistantTool] = [:]

    func register(_ tool: AssistantTool) {
        tools[tool.definition.name] = tool
    }

    func allDefinitions() -> [ToolDefinition] {
        tools.values.map(\.definition)
    }

    func tool(named name: String) -> AssistantTool? {
        tools[name]
    }
}
