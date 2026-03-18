import SwiftUI
import AppKit

// MARK: - Window Controller

/// Manages a floating NSPanel for the AI assistant.
@MainActor
final class AssistantWindowController {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?

    func toggle(viewModel: AssistantViewModel, showBinding: Binding<Bool>) {
        if let panel, panel.isVisible {
            panel.close()
            return
        }
        show(viewModel: viewModel, showBinding: showBinding)
    }

    func show(viewModel: AssistantViewModel, showBinding: Binding<Bool>) {
        if let panel, panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            return
        }

        let content = AssistantPanelContent(viewModel: viewModel)
        let hosting = NSHostingView(rootView: AnyView(content))

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 500),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "AI Assistant"
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.minSize = NSSize(width: 380, height: 300)
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow

        // Position near top-right of main window
        if let mainWindow = NSApp.mainWindow {
            let mainFrame = mainWindow.frame
            let x = mainFrame.maxX - 540
            let y = mainFrame.maxY - 540
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            panel.center()
        }

        // Sync close button with showAssistant state
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { _ in
            showBinding.wrappedValue = false
        }

        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        self.hostingView = hosting
    }

    func close() {
        panel?.close()
        panel = nil
        hostingView = nil
    }
}

// MARK: - Markdown Block Renderer

/// Renders an AI response with proper block-level spacing.
/// Splits content into headings, paragraphs, list items and dividers so each
/// gets appropriate vertical breathing room, unlike a single SwiftUI Text node.
struct MarkdownBlockView: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    // MARK: - Block model

    private enum Block {
        case heading(level: Int, text: String)
        case paragraph(String)
        case listItem(indent: Int, text: String)
        case divider
    }

    // MARK: - Parser

    private var blocks: [Block] {
        var result: [Block] = []
        let lines = content.components(separatedBy: "\n")
        var paragraphLines: [String] = []

        func flushParagraph() {
            let joined = paragraphLines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty { result.append(.paragraph(joined)) }
            paragraphLines.removeAll()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Horizontal rule
            if trimmed.hasPrefix("---") || trimmed == "⸻" || trimmed == "—" {
                flushParagraph()
                result.append(.divider)
                continue
            }

            // Headings: ### ## #
            if trimmed.hasPrefix("###") {
                flushParagraph()
                result.append(.heading(level: 3, text: String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if trimmed.hasPrefix("##") {
                flushParagraph()
                result.append(.heading(level: 2, text: String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if trimmed.hasPrefix("#") {
                flushParagraph()
                result.append(.heading(level: 1, text: String(trimmed.dropFirst(1)).trimmingCharacters(in: .whitespaces)))
                continue
            }

            // List items: - or *
            let listPrefixes = ["- ", "* ", "• "]
            if let prefix = listPrefixes.first(where: { trimmed.hasPrefix($0) }) {
                flushParagraph()
                let indent = (line.prefix(while: { $0 == " " }).count) / 2
                result.append(.listItem(indent: indent, text: String(trimmed.dropFirst(prefix.count))))
                continue
            }

            // Blank line → paragraph break
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            paragraphLines.append(trimmed)
        }
        flushParagraph()
        return result
    }

    // MARK: - Rendering

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inlineMarkdown(text))
                .font(level == 1 ? .headline : (level == 2 ? .subheadline : .footnote))
                .fontWeight(.semibold)
                .foregroundStyle(level == 1 ? Color.primary : Color.primary.opacity(0.85))
                .padding(.top, level == 1 ? 10 : 8)
                .padding(.bottom, 2)

        case .paragraph(let text):
            Text(inlineMarkdown(text))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

        case .listItem(let indent, let text):
            HStack(alignment: .top, spacing: 5) {
                Text("•")
                    .foregroundStyle(.secondary)
                Text(inlineMarkdown(text))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
            .padding(.leading, CGFloat(indent) * 14)

        case .divider:
            Divider()
                .padding(.vertical, 6)
        }
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}

// MARK: - Panel Content View

/// The chat UI content (no window chrome — the NSPanel provides that).
struct AssistantPanelContent: View {
    @ObservedObject var viewModel: AssistantViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if viewModel.messages.isEmpty {
                            welcomeMessage
                        }
                        ForEach(viewModel.messages) { message in
                            messageView(message)
                                .id(message.id)
                        }
                        if viewModel.isProcessing && viewModel.pendingConfirmation == nil {
                            thinkingIndicator
                        }
                    }
                    .padding()
                }
                .onChange(of: viewModel.messages.count) { _ in
                    if let last = viewModel.messages.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            // Confirmation banner
            if let confirmation = viewModel.pendingConfirmation {
                confirmationBanner(confirmation)
            }

            Divider()

            // Input + controls
            HStack(spacing: 8) {
                Button {
                    viewModel.clearConversation()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .help("Clear conversation")
                .disabled(viewModel.isProcessing)

                TextField("Ask about targets, equipment, or sky conditions...", text: $viewModel.inputText)
                    .textFieldStyle(.plain)
                    .onSubmit { viewModel.send() }
                    .disabled(viewModel.isProcessing)

                Button {
                    viewModel.send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(canSend ? .purple : .gray)
                }
                .buttonStyle(.borderless)
                .disabled(!canSend)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
    }

    private var canSend: Bool {
        !viewModel.inputText.trimmingCharacters(in: .whitespaces).isEmpty && !viewModel.isProcessing
    }

    // MARK: - Message Views

    @ViewBuilder
    private func messageView(_ message: AssistantMessage) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer()
                Text(message.content)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.blue.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.primary)
            }

        case .assistant:
            HStack(alignment: .top) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
                    .font(.system(size: 12))
                    .padding(.top, 4)
                MarkdownBlockView(content: message.content)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Spacer(minLength: 40)
            }

        case .toolInvocation:
            toolInvocationView(message)

        case .toolResult:
            toolResultView(message)

        case .error:
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(message.content)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private func toolInvocationView(_ message: AssistantMessage) -> some View {
        HStack(spacing: 6) {
            statusIcon(message.toolStatus)
            Text(message.toolName ?? "Tool")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Text(message.content)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func toolResultView(_ message: AssistantMessage) -> some View {
        DisclosureGroup {
            Text(message.content)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(6)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 10))
                Text("\(message.toolName ?? "Tool") result")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
        .padding(.leading, 20)
    }

    @ViewBuilder
    private func statusIcon(_ status: AssistantMessage.ToolStatus?) -> some View {
        switch status {
        case .pending:
            Image(systemName: "clock")
                .foregroundStyle(.orange)
                .font(.system(size: 11))
        case .approved, .running:
            ProgressView()
                .controlSize(.mini)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 11))
        case .denied:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 11))
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 11))
        case nil:
            EmptyView()
        }
    }

    private var thinkingIndicator: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text("Thinking...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 4)
    }

    private var welcomeMessage: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 28))
                .foregroundStyle(.purple.opacity(0.6))
            Text("AI Astronomy Assistant")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Ask about targets to photograph tonight, get help with imaging settings, or let me control the mount and camera.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 350)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    // MARK: - Confirmation

    private func confirmationBanner(_ confirmation: PendingToolConfirmation) -> some View {
        VStack(spacing: 8) {
            Divider()
            HStack {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tool Request")
                        .font(.caption.bold())
                    Text(confirmation.description)
                        .font(.caption)
                }
                Spacer()
                Button("Deny") {
                    viewModel.denyToolCall()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Approve") {
                    viewModel.approveToolCall()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.green)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .background(Color.orange.opacity(0.05))
    }
}
