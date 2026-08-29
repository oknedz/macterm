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
                .modifier(BubbleCornerRadiusModifier(lineCount: message.content.displayLineCount, style: AppBubbleStyle()))
                
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
    @Environment(\.horizontalSizeClass) private var hSize

    /// Send is enabled only with a non-empty message and when idle.
    private var canSend: Bool {
        !isProcessing && !userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 6) {
            if userInput.hasPrefix("/") {
                Text("Commands: /clear  /theme <name>  /newtab  /help")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
            }
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask Macterm AI…", text: $userInput, axis: .vertical)
                    .font(.system(size: controller.fontSize))
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .disabled(isProcessing)
                    .onSubmit { if canSend { action() } }
                Button(action: action) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 15, weight: .bold))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(isProcessing ? Color.gray.opacity(0.3) : Color.accentColor)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("Send message")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, hSize == .compact ? 4 : 7)
        }
        .background(Color.clear)
    }
}

// MARK: - Chat bubble shape

/// Injectable styling contract for chat bubbles — swap for theming or unit tests.
protocol BubbleStyleProviding {
    /// Large value → SwiftUI clamps it to half the bubble height, yielding an oval/capsule for one line.
    var singleLineRadius: CGFloat { get }
    /// Balanced rounded-rectangle radius for wrapped (multi-line) content.
    var multiLineRadius: CGFloat { get }
}

/// Default bubble styling. `singleLineRadius` is intentionally huge so a single
/// line renders as a true oval (capsule); multi-line uses a balanced 14pt radius.
struct AppBubbleStyle: BubbleStyleProviding {
    let singleLineRadius: CGFloat = 1000
    let multiLineRadius: CGFloat = 14
}

/// Pure, value-typed radius resolver — trivially unit-testable, no side effects.
enum BubbleRadius {
    static func radius(lineCount: Int, style: BubbleStyleProviding) -> CGFloat {
        lineCount <= 1 ? style.singleLineRadius : style.multiLineRadius
    }
}

/// Reusable modifier: single-line content → oval (capsule); multi-line → rounded
/// rectangle with balanced curvature. Value-typed, no retained closures, safe to
/// apply on the main thread inside `body` (SwiftUI evaluates `body` on main).
struct BubbleCornerRadiusModifier: ViewModifier {
    let lineCount: Int
    let style: BubbleStyleProviding

    func body(content: Content) -> some View {
        content.cornerRadius(BubbleRadius.radius(lineCount: lineCount, style: style))
    }
}

extension String {
    /// Number of lines in a message (explicit newlines). Pure + value-semantic so
    /// it is computed synchronously from the model on the main thread — no layout
    /// pass or retained closure required. A true wrapped-line count would need the
    /// rendered width (GeometryReader/NSLayoutManager); the newline heuristic is the
    /// standard chat-bubble rule and keeps this cheap and testable.
    var displayLineCount: Int {
        max(1, components(separatedBy: "\n").count)
    }
}
