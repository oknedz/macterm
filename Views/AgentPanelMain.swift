import SwiftUI


struct AgentPanelMain: View {
    @EnvironmentObject private var controller: TerminalController
    @State private var userInput: String = ""
    
    private var agenticSystem: AgenticSystem { controller.agenticSystem }
    
    var body: some View {
        VStack(spacing: 0) {
            AgentPanelHeader(agenticSystem: agenticSystem)
            
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(agenticSystem.conversationHistory, id: \.id) { message in
                        AgentMessageView(message: message)
                    }
                }
                .padding(12)
            }
            
            ToolSelectionStrip(agenticSystem: agenticSystem)

            AgentInputArea(
                userInput: $userInput,
                isProcessing: agenticSystem.workflowState == .analyzing || agenticSystem.workflowState == .planning || agenticSystem.workflowState == .executing
            ) {
                Task {
                    await processUserInput()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
    }
    
    private func processUserInput() async {
        let raw = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("/") {
            handleSlashCommand(raw)
            userInput = ""
            return
        }
        let context = AgentContext(
            sessionId: controller.focusedSessionId,
            workingDirectory: controller.activeCwd,
            theme: controller.themeName
        )
        await agenticSystem.processUserInput(userInput, context: context)
        userInput = ""
    }

    private func handleSlashCommand(_ raw: String) {
        let body = String(raw.dropFirst())
        let parts = body.split(separator: " ", maxSplits: 1).map(String.init)
        let cmd = parts.first?.lowercased() ?? ""
        let arg = parts.count > 1 ? parts[1] : ""
        switch cmd {
        case "clear":
            agenticSystem.conversationHistory.removeAll()
        case "theme":
            if !arg.isEmpty {
                controller.themeName = arg
            } else {
                agenticSystem.conversationHistory.append(
                    AgentMessage(role: .assistant, content: "Usage: /theme <name>", timestamp: Date()))
            }
        case "newtab", "tab":
            controller.newTab()
        case "help":
            agenticSystem.conversationHistory.append(
                AgentMessage(role: .assistant,
                    content: "Commands:\n/clear — clear chat\n/theme <name> — apply theme\n/newtab — open new tab\n/help — this list",
                    timestamp: Date()))
        default:
            agenticSystem.conversationHistory.append(
                AgentMessage(role: .assistant, content: "Unknown command: \(raw). Type /help.", timestamp: Date()))
        }
    }
}

struct AgentPanelHeader: View {
    let agenticSystem: AgenticSystem
    var body: some View {
        HStack {
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.title2)
                .foregroundColor(.blue)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Macterm AI")
                    .font(.headline)
                
                Text("AI assistant with workflow capabilities")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            WorkflowStatusIndicator(agenticSystem: agenticSystem)

            Button(action: {
                agenticSystem.conversationHistory.removeAll()
            }) {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear conversation")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.clear)
    }
}

struct WorkflowStatusIndicator: View {
    let agenticSystem: AgenticSystem
    
    var body: some View {
        HStack(spacing: 8) {
            if agenticSystem.workflowState == .idle {
                Circle()
                    .fill(Color.gray)
                    .frame(width: 10, height: 10)
                Text("Ready")
                    .font(.caption)
                    .foregroundColor(.gray)
            } else if agenticSystem.workflowState == .analyzing || agenticSystem.workflowState == .planning || agenticSystem.workflowState == .executing {
                ProgressView()
                    .scaleEffect(0.6)
                Text("Processing...")
                    .font(.caption)
                    .foregroundColor(.blue)
            } else {
                Circle()
                    .fill(Color.green)
                    .frame(width: 10, height: 10)
                Text("Complete")
                    .font(.caption)
                    .foregroundColor(.green)
            }
        }
    }
}

struct AgentMessageView: View {
    let message: AgentMessage
    
    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            if message.role == .assistant {
                AvatarView(role: .assistant)
            }
            
            MessageContentView(message: message)
            
            if message.role == .user {
                AvatarView(role: .user)
            }
        }
        .padding(.horizontal)
    }
}

struct AvatarView: View {
    let role: MessageRole
    
    var body: some View {
        ZStack {
            Circle()
                .fill(role == .assistant ? Color.blue.opacity(0.2) : Color.green.opacity(0.2))
                .frame(width: 32, height: 32)
            
            Image(systemName: role == .assistant ? "brain.fill" : "person.circle.fill")
                .font(.caption)
                .foregroundColor(role == .assistant ? .blue : .green)
        }
    }
}

struct MessageContentView: View {
    let message: AgentMessage
    @EnvironmentObject private var controller: TerminalController
    
    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
                Text(message.content).font(.system(size: controller.fontSize))
                .padding()
                .background(
                    message.role == .user ? 
                    Color.blue.opacity(0.2) : 
                    Color(NSColor.controlBackgroundColor)
                )
                .cornerRadius(12)
                
            if !message.toolCalls.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(message.toolCalls, id: \.id) { call in
                        if let result = call.result, !result.isEmpty {
                            HStack(alignment: .top, spacing: 4) {
                                Image(systemName: "terminal.fill")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text(result)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
            HStack {
                if !message.toolCalls.isEmpty {
                    Label("\(message.toolCalls.count) tools", systemImage: "wrench.fill")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Text(message.timestamp, style: .relative)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct AgentInputArea: View {
    @Binding var userInput: String
    let isProcessing: Bool
    let action: () -> Void
    @EnvironmentObject private var controller: TerminalController
    
    var body: some View {
        VStack(spacing: 10) {
            if $userInput.wrappedValue.hasPrefix("/") {
                Text("Commands: /clear  /theme <name>  /newtab  /help")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            }
            Divider()
            
            HStack(spacing: 10) {
                TextEditor(text: $userInput)
                    .font(.system(size: controller.fontSize))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 38, maxHeight: 140)
                    .padding(6)
                    .background(Color.primary.opacity(0.06))
                    .cornerRadius(6)
                    .disabled(isProcessing)
                
                Button(action: action) {
                    Image(systemName: isProcessing ? "hourglass" : "arrow.up.circle.fill")
                        .font(.title3)
                        .frame(width: 36, height: 36)
                        .background(isProcessing ? Color.gray.opacity(0.2) : Color.accentColor)
                        .foregroundColor(isProcessing ? .secondary : .white)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(isProcessing || userInput.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .background(Color.clear)
    }
}
struct ToolSelectionStrip: View {
    @ObservedObject var agenticSystem: AgenticSystem

    var body: some View {
        Group {
            if agenticSystem.availableTools.isEmpty {
                EmptyView()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(agenticSystem.availableTools, id: \.name) { tool in
                            Button(action: { Task { await agenticSystem.runTool(named: tool.name) } }) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tool.name)
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .lineLimit(1)
                                    Text(tool.description)
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                .frame(width: 132, alignment: .leading)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Color.primary.opacity(0.08))
                                .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                            .help(tool.description)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                }
                .frame(height: 58)
            }
        }
    }
}
