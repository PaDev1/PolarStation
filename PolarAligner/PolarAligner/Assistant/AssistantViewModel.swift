import SwiftUI

/// A single message in the assistant conversation.
struct AssistantMessage: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let role: Role
    let content: String
    var toolName: String?
    var toolStatus: ToolStatus?

    enum Role { case user, assistant, toolInvocation, toolResult, error }
    enum ToolStatus { case pending, approved, denied, running, completed, failed }
}

/// Pending tool confirmation for user approval.
struct PendingToolConfirmation: Identifiable {
    let id = UUID()
    let toolCall: ToolCall
    let description: String
    let continuation: CheckedContinuation<Bool, Never>
}

/// Drives the AI assistant conversation with tool calling support.
@MainActor
final class AssistantViewModel: ObservableObject {
    @Published var messages: [AssistantMessage] = []
    @Published var inputText = ""
    @Published var isProcessing = false
    @Published var pendingConfirmation: PendingToolConfirmation?

    private let llmService = LLMService()
    private let mountService: MountService
    private let cameraViewModel: CameraViewModel
    private let weatherService: WeatherService
    private let toolRegistry = AssistantToolRegistry()

    /// Raw message history formatted for the current LLM provider.
    private var conversationHistory: [[String: Any]] = []

    private let maxToolLoopDepth = 5

    init(mountService: MountService, cameraViewModel: CameraViewModel, weatherService: WeatherService, skyMapViewModel: SkyMapViewModel) {
        self.mountService = mountService
        self.cameraViewModel = cameraViewModel
        self.weatherService = weatherService

        // Register tools
        toolRegistry.register(MountTool(mountService: mountService))
        toolRegistry.register(CameraTool(cameraViewModel: cameraViewModel))
        toolRegistry.register(SkyInfoTool(weatherService: weatherService))
        toolRegistry.register(SkyMapTool(skyMapViewModel: skyMapViewModel))
    }

    // MARK: - Public

    func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isProcessing else { return }
        inputText = ""

        messages.append(AssistantMessage(role: .user, content: text))

        let provider = currentProvider
        // Add user message to conversation history
        switch provider {
        case .claude:
            conversationHistory.append(["role": "user", "content": text])
        case .openai:
            conversationHistory.append(["role": "user", "content": text])
        }

        isProcessing = true
        Task {
            // Ensure weather data is fresh before building system prompt
            let lat = UserDefaults.standard.double(forKey: "observerLat")
            let lon = UserDefaults.standard.double(forKey: "observerLon")
            await weatherService.fetch(lat: lat, lon: lon)

            await runConversationLoop()
            isProcessing = false
        }
    }

    func clearConversation() {
        messages.removeAll()
        conversationHistory.removeAll()
    }

    func approveToolCall() {
        pendingConfirmation?.continuation.resume(returning: true)
        pendingConfirmation = nil
    }

    func denyToolCall() {
        pendingConfirmation?.continuation.resume(returning: false)
        pendingConfirmation = nil
    }

    // MARK: - Conversation Loop

    private func runConversationLoop() async {
        let provider = currentProvider
        let endpoint = currentEndpoint
        let apiKey = currentApiKey
        let model = currentModel

        guard !apiKey.isEmpty else {
            messages.append(AssistantMessage(role: .error, content: "AI assistant not configured. Set your API key in Settings."))
            return
        }

        for _ in 0..<maxToolLoopDepth {
            do {
                let systemPrompt = buildSystemPrompt()
                let (response, rawMessage) = try await llmService.chat(
                    systemPrompt: systemPrompt,
                    messages: conversationHistory,
                    tools: toolRegistry.allDefinitions(),
                    provider: provider,
                    endpoint: endpoint,
                    apiKey: apiKey,
                    model: model
                )

                // Add raw assistant message to history
                conversationHistory.append(rawMessage)

                switch response {
                case .text(let text):
                    messages.append(AssistantMessage(role: .assistant, content: text))
                    return // Done — no more tool calls

                case .toolUse(let toolCalls):
                    // Process each tool call
                    for toolCall in toolCalls {
                        let result = await processToolCall(toolCall, provider: provider)

                        // Add tool result to conversation history
                        switch provider {
                        case .claude:
                            conversationHistory.append(
                                LLMService.claudeToolResultMessage(toolUseId: toolCall.id, result: result)
                            )
                        case .openai:
                            conversationHistory.append(
                                LLMService.openAIToolResultMessage(toolCallId: toolCall.id, result: result)
                            )
                        }
                    }
                    // Loop continues — call LLM again with tool results
                }
            } catch {
                messages.append(AssistantMessage(role: .error, content: "Error: \(error.localizedDescription)"))
                return
            }
        }

        // Max depth reached
        messages.append(AssistantMessage(role: .assistant, content: "I've reached the maximum number of tool calls for this turn. Please send another message to continue."))
    }

    private func processToolCall(_ toolCall: ToolCall, provider: LLMProvider) async -> String {
        guard let tool = toolRegistry.tool(named: toolCall.name) else {
            let msg = "Unknown tool: \(toolCall.name)"
            messages.append(AssistantMessage(role: .error, content: msg))
            return msg
        }

        let description = tool.describeAction(arguments: toolCall.arguments)

        // Show tool invocation in chat
        var invocationMsg = AssistantMessage(role: .toolInvocation, content: description, toolName: toolCall.name, toolStatus: .pending)
        messages.append(invocationMsg)
        let invocationIndex = messages.count - 1

        // Always require user confirmation
        let approved = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            pendingConfirmation = PendingToolConfirmation(
                toolCall: toolCall,
                description: description,
                continuation: continuation
            )
        }

        if !approved {
            messages[invocationIndex].toolStatus = .denied
            return "User denied this action."
        }

        messages[invocationIndex].toolStatus = .running

        do {
            let result = try await tool.execute(arguments: toolCall.arguments)
            messages[invocationIndex].toolStatus = .completed

            // Show result in chat (collapsed)
            messages.append(AssistantMessage(role: .toolResult, content: result, toolName: toolCall.name, toolStatus: .completed))
            return result
        } catch {
            messages[invocationIndex].toolStatus = .failed
            let errorMsg = "Tool error: \(error.localizedDescription)"
            messages.append(AssistantMessage(role: .toolResult, content: errorMsg, toolName: toolCall.name, toolStatus: .failed))
            return errorMsg
        }
    }

    // MARK: - System Prompt

    private func buildSystemPrompt() -> String {
        let lat = UserDefaults.standard.double(forKey: "observerLat")
        let lon = UserDefaults.standard.double(forKey: "observerLon")
        let focalLength = UserDefaults.standard.double(forKey: "focalLengthMM")
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss z"

        var context = """
        You are an expert astrophotography assistant integrated into PolarStation, a telescope control application.
        You help the user plan observations, suggest targets, answer questions about deep sky objects and imaging techniques, and control equipment.

        Current observation context:
        - Date/Time: \(formatter.string(from: now))
        - Observer location: \(String(format: "%.4f", lat))\u{00B0}N, \(String(format: "%.4f", lon))\u{00B0}E
        """

        if focalLength > 0 {
            context += "\n- Telescope focal length: \(String(format: "%.0f", focalLength))mm"
        }

        // Mount status
        if mountService.isConnected, let s = mountService.status {
            context += """

            - Mount: Connected (\(mountService.backendName ?? "unknown"))
            - Mount position: RA \(String(format: "%.4f", s.raHours))h, Dec \(String(format: "%.2f", s.decDeg))\u{00B0}
            - Alt \(String(format: "%.1f", s.altDeg))\u{00B0}, Az \(String(format: "%.1f", s.azDeg))\u{00B0}
            - Tracking: \(s.tracking), Slewing: \(s.slewing), Parked: \(s.atPark)
            """
        } else {
            context += "\n- Mount: Not connected"
        }

        // Camera status
        if cameraViewModel.isConnected {
            context += """

            - Camera: Connected (\(cameraViewModel.captureWidth)x\(cameraViewModel.captureHeight))
            - Stars detected: \(cameraViewModel.detectedStars.count)
            """
        } else {
            context += "\n- Camera: Not connected"
        }

        // Sky conditions
        let sunAlt = SkyObjectsService.sunAltitude(lat: lat, lon: lon, date: now)
        let moonAlt = SkyObjectsService.moonAltitude(lat: lat, lon: lon, date: now)
        let moonIllum = SkyObjectsService.moonIllumination(date: now)
        context += """

        - Sun altitude: \(String(format: "%.1f", sunAlt))\u{00B0}
        - Moon altitude: \(String(format: "%.1f", moonAlt))\u{00B0}, illumination: \(String(format: "%.0f", moonIllum * 100))%
        \(weatherService.summaryForLLM())

        You have tools to: query sky conditions and suggest targets (sky_info), control the mount (mount_control), and query camera status (camera_control).
        When suggesting targets, consider the user's location, time, and equipment.
        When the user wants to go to an object, use the mount_control tool with the object's RA (in hours) and Dec (in degrees).
        Be concise and practical. Use object designations (M42, NGC 7000, etc.) and include key imaging parameters when relevant.
        """

        return context
    }

    // MARK: - Settings Access

    private var currentProvider: LLMProvider {
        let raw = UserDefaults.standard.string(forKey: "llmProvider") ?? LLMProvider.claude.rawValue
        return LLMProvider(rawValue: raw) ?? .claude
    }

    private var currentEndpoint: String {
        currentProvider.defaultEndpoint
    }

    private var currentApiKey: String {
        UserDefaults.standard.string(forKey: "llmApiKey") ?? ""
    }

    private var currentModel: String {
        let model = UserDefaults.standard.string(forKey: "llmModel") ?? ""
        return model.isEmpty ? currentProvider.defaultModel : model
    }
}
