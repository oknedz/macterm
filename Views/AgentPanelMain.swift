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
        let context = AgentContext(
            sessionId: controller.focusedSessionId,
            workingDirectory: controller.activeCwd,
            theme: controller.themeName
        )
        await agenticSystem.processUserInput(userInput, context: context)
        userInput = ""
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
            
            Image(systemName: role == .assistant ? "brain.head.circle.fill" : "person.circle.fill")
                .font(.caption)
                .foregroundColor(role == .assistant ? .blue : .green)
        }
    }
}

struct MessageContentView: View {
    let message: AgentMessage
    
    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
            Text(message.content)
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
    
    var body: some View {
        VStack(spacing: 10) {
            Divider()
            
            HStack(spacing: 10) {
                TextField("Ask about terminal, files, themes...", text: $userInput)
                    .textFieldStyle(.roundedBorder)
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
    let agenticSystem: AgenticSystem

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(agenticSystem.availableTools, id: \.name) { tool in
                    Button(action: {
                        Task { await agenticSystem.runTool(named: tool.name) }
                    }) {
                        Text(tool.name)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.1))
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .help(tool.description)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(height: agenticSystem.availableTools.isEmpty ? 0 : 38)
    }
}
