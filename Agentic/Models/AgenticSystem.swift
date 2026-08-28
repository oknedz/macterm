// Copyright © 2026 Zdenko. All rights reserved.
import Foundation
import SwiftUI

/// Core agentic system for macterm integration
/// Provides AI-powered workflow capabilities while preserving terminal functionality
@MainActor
class AgenticSystem: ObservableObject {
    @Published var isActive: Bool = false
    @Published var conversationHistory: [AgentMessage] = []
    @Published var availableTools: [ToolInfo] = []
    
    enum WorkflowState {
        case idle, analyzing, planning, executing, completing
    }
    
    @Published var workflowState: WorkflowState = .idle
    
    // MARK: - Dependencies
    private let toolRegistry: ToolRegistry
    private let extensionSystem: ExtensionSystem

    /// LLM provider for response generation. Swap to a real provider (e.g. swift-ai-sdk)
    /// without touching any call site in `AgenticSystem`.
    var provider: AgentProvider = CloudAgentProvider.detected()
    
    // MARK: - Initialization
    @MainActor
    init(
        toolRegistry: ToolRegistry? = nil,
        extensionSystem: ExtensionSystem? = nil
    ) {
        self.toolRegistry = toolRegistry ?? ToolRegistry.shared
        self.extensionSystem = extensionSystem ?? ExtensionSystem.shared
        setupAgenticSystem()
    }
    
    private func setupAgenticSystem() {
        availableTools = toolRegistry.getAllTools()
        extensionSystem.setupBuiltInExtensions()
        availableTools = extensionSystem.getTools()
        
        isActive = true
    }
    
    /// Reconfigure tools with TerminalController reference
    func configureTools(with controller: TerminalController) {
        extensionSystem.configure(with: controller)
        availableTools = extensionSystem.getTools()
    }
    
    // MARK: - Public API
    func processUserInput(_ input: String, context: AgentContext) async {
        workflowState = .analyzing
        
        // Add user message to conversation
        let userMessage = AgentMessage(
            role: .user,
            content: input,
            timestamp: Date(),
            toolCalls: []
        )
        conversationHistory.append(userMessage)
        
        // Analyze intent from user input
        let intent = analyzeIntent(from: input)
        
        // Find relevant tools based on intent
        let relevantTools = extensionSystem.getTools().filter { $0.supportsIntent(intent) }
        
        // Execute relevant tools if available
        var toolResults: [ToolResult] = []
        if !relevantTools.isEmpty {
            toolResults = await executeTools(relevantTools, input: input, context: context)
        }
        
        // Generate AI response
        let aiResponse = await provider.generateResponse(
            input: input,
            intent: intent,
            toolResults: toolResults,
            context: context
        )
        
        // Add AI response to conversation
        let assistantMessage = AgentMessage(
            role: .assistant,
            content: aiResponse.text,
            timestamp: Date(),
            toolCalls: toolResults.map { ToolCall(id: UUID().uuidString, name: $0.toolName, parameters: [:], result: $0.error?.localizedDescription ?? ($0.result.map { String(describing: $0) })) }
        )
        conversationHistory.append(assistantMessage)
        
        workflowState = .completing
        
        // Reset to idle after a brief moment to show completion
        try? await Task.sleep(nanoseconds: 500_000_000)
        workflowState = .idle
    }

    /// Directly invoke a registered tool by name (used by the panel's tool launcher).
    /// Records the invocation + result in the conversation so the user sees the outcome.
    func runTool(named name: String, parameters: [String: Any] = [:]) async {
        guard let tool = extensionSystem.getTools().first(where: { $0.name == name }) else {
            conversationHistory.append(
                AgentMessage(role: .assistant, content: "Unknown tool: \(name)", timestamp: Date())
            )
            return
        }

        conversationHistory.append(
            AgentMessage(role: .user, content: "▸ \(name)", timestamp: Date())
        )

        workflowState = .executing
        let outcome: ToolResult
        do {
            let value = try await tool.action(parameters)
            outcome = ToolResult(toolName: name, result: value, error: nil)
        } catch {
            outcome = ToolResult(toolName: name, result: nil, error: error)
        }
        workflowState = .idle

        let text = outcome.error?.localizedDescription
            ?? (outcome.result.map { String(describing: $0) } ?? "Done")
        conversationHistory.append(
            AgentMessage(
                role: .assistant,
                content: text,
                timestamp: Date(),
                toolCalls: [ToolCall(id: UUID().uuidString, name: name, parameters: parameters, result: text)]
            )
        )
    }
    
    // MARK: - Intent Recognition
    private func analyzeIntent(from input: String) -> AgentIntent {
        let lowercased = input.lowercased()

        if lowercased.contains("theme") || lowercased.contains("appearance") {
            return AgentIntent(type: .theme_management)
        } else if lowercased.contains("file") || lowercased.contains("directory") || lowercased.contains("folder") || lowercased.contains("open") {
            return AgentIntent(type: .file_access)
        } else if lowercased.contains("tab") || lowercased.contains("split") || lowercased.contains("pane") || lowercased.contains("session") {
            return AgentIntent(type: .session_management)
        } else if lowercased.contains("terminal") || lowercased.contains("execute") || lowercased.contains("run") || lowercased.contains("command") || lowercased.contains("cd") || lowercased.contains("clear") {
            return AgentIntent(type: .terminal_command)
        } else {
            return AgentIntent(type: .tool_execution)
        }
    }
    
    // MARK: - Tool Execution
    private func executeTools(_ tools: [ToolInfo], input: String, context: AgentContext) async -> [ToolResult] {
        var results: [ToolResult] = []
        
        for tool in tools {
            let parameters = createToolParameters(for: tool, input: input, context: context)
            do {
                let result = try await tool.action(parameters)
                results.append(ToolResult(toolName: tool.name, result: result, error: nil))
            } catch {
                results.append(ToolResult(toolName: tool.name, result: nil, error: error))
            }
        }
        
        return results
    }
    
    // MARK: - Parameter Creation
    private func createToolParameters(for tool: ToolInfo, input: String, context: AgentContext) -> [String: Any] {
        var parameters: [String: Any] = [:]
        
        switch tool.name {
        case "terminal_execute":
            parameters["command"] = input
            if let sessionId = context.sessionId {
                parameters["sessionId"] = sessionId
            }
        case "file_tree":
            parameters["path"] = context.workingDirectory ?? "."
            parameters["includeHidden"] = false
        case "apply_theme":
            parameters["theme"] = extractThemeName(from: input) ?? "onedark"
            parameters["options"] = [:]
        default:
            parameters["input"] = input
        }
        
        return parameters
    }
    
    
}

// MARK: - Supporting Types

struct AgentMessage: Identifiable {
    let id = UUID()
    let role: MessageRole
    let content: String
    let toolCalls: [ToolCall]
    let timestamp: Date
    
    init(role: MessageRole, content: String, timestamp: Date, toolCalls: [ToolCall] = []) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.timestamp = timestamp
    }
}

enum MessageRole {
    case user, assistant, system
}

struct ToolCall {
    let id: String
    let name: String
    let parameters: [String: Any]
    let result: String?

    init(id: String, name: String, parameters: [String: Any], result: String? = nil) {
        self.id = id
        self.name = name
        self.parameters = parameters
        self.result = result
    }
}

struct ToolResult {
    let toolName: String
    let result: Any?
    let error: Error?
}

struct ToolInfo {
    let name: String
    let description: String
    let parameters: [String: ParameterProperty]
    let action: AgenticToolAction
    
    typealias AgenticToolAction = ([String: Any]) async throws -> Any
    
    func supportsIntent(_ intent: AgentIntent) -> Bool {
        switch intent.type {
        case .theme_management:
            return name == "apply_theme"
        case .file_access:
            return name == "file_tree"
        case .terminal_command:
            return name == "terminal_execute"
        case .session_management:
            return name == "macterm_new_tab"
        default:
            return false
        }
    }
}

struct ParameterProperty {
    let type: ParameterType
    let description: String
    let defaultValue: Any?
}

enum ParameterType {
    case string, number, boolean, object, array
}

struct AgentIntent {
    let type: IntentType
}

enum IntentType {
    case tool_execution
    case file_access
    case terminal_command
    case settings_modification
    case project_analysis
    case theme_management
    case session_management
}

struct AIResponse {
    let text: String
    let intent: AgentIntent
    let confidence: Double
}

/// Extract a known theme slug from free-text input (shared by the agent and providers).
func extractThemeName(from input: String) -> String? {
    let themes = ["onedark", "tokyo-night", "dracula", "github-light", "everforest"]
    let lowercased = input.lowercased()
    for theme in themes {
        if lowercased.contains(theme) {
            return theme
        }
    }
    return nil
}

/// Abstraction over the LLM that turns user input + tool results into a response.
/// `MockProvider` is the local default; a real provider (e.g. swift-ai-sdk) can
/// conform to this without changing any call site in `AgenticSystem`.
@MainActor
protocol AgentProvider {
    func generateResponse(
        input: String,
        intent: AgentIntent,
        toolResults: [ToolResult],
        context: AgentContext
    ) async -> AIResponse
}

/// Local placeholder: returns canned, intent-shaped text. No network / keys.
struct MockProvider: AgentProvider {
    func generateResponse(
        input: String,
        intent: AgentIntent,
        toolResults: [ToolResult],
        context: AgentContext
    ) async -> AIResponse {
        let responseText: String
        switch intent.type {
        case .theme_management:
            responseText = "I'll help you apply the theme. The theme \(extractThemeName(from: input) ?? "onedark") will be applied to your terminal."
        case .file_access:
            responseText = "I'll help you access the file system. I can show you the directory structure and contents."
        case .terminal_command:
            responseText = "I'll execute your terminal command: \(input)"
        case .tool_execution:
            responseText = "I'll help you with that request using the available tools."
        case .settings_modification:
            responseText = "I'll help you modify settings. What would you like to change?"
        case .project_analysis:
            responseText = "I'll analyze your project structure and provide insights."
        case .session_management:
            responseText = "I'll help manage your sessions and workspaces."
        }

        return AIResponse(
            text: responseText,
            intent: intent,
            confidence: 0.85
        )
    }
}

/// Real LLM provider backed by OpenRouter (OpenAI-compatible `/v1/chat/completions`).
/// Reads `OPENROUTER_API_KEY` from the environment; when absent it transparently
/// falls back to `MockProvider` so the agent never breaks. Network/parse errors
/// also degrade to the mock text instead of throwing into the UI.
struct CloudAgentProvider: AgentProvider {
    /// Pick the best provider available on this machine. Extend here for Azure /
    /// OpenCode once their deployment/env wiring is settled.
    static func detected() -> AgentProvider {
        if let key = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"],
           !key.isEmpty {
            return CloudAgentProvider()
        }
        return MockProvider()
    }

    private var apiKey: String? { ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] }
    private var model: String {
        ProcessInfo.processInfo.environment["MACTERM_MODEL"] ?? "openai/gpt-4o-mini"
    }

    func generateResponse(
        input: String,
        intent: AgentIntent,
        toolResults: [ToolResult],
        context: AgentContext
    ) async -> AIResponse {
        guard let key = apiKey, !key.isEmpty else {
            return await MockProvider().generateResponse(input: input, intent: intent,
                                                        toolResults: toolResults, context: context)
        }

        var messages: [[String: String]] = []
        messages.append(["role": "system",
                         "content": "You are Macterm's built-in assistant for terminal, file, theme and session tasks. Be concise and concrete."])
        if !toolResults.isEmpty {
            let summary = toolResults.map { r -> String in
                if let e = r.error { return "\(r.toolName) error: \(e.localizedDescription)" }
                return "\(r.toolName): \(r.result.map { String(describing: $0) } ?? "ok")"
            }.joined(separator: "\n")
            messages.append(["role": "system", "content": "Tool results:\n\(summary)"])
        }
        messages.append(["role": "user", "content": input])

        guard let url = URL(string: "https://openrouter.ai/api/v1/chat/completions") else {
            return await MockProvider().generateResponse(input: input, intent: intent,
                                                        toolResults: toolResults, context: context)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("macterm", forHTTPHeaderField: "HTTP-Referer")
        req.timeoutInterval = 30
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": 0.3,
            "max_tokens": 1024
        ]
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            return await MockProvider().generateResponse(input: input, intent: intent,
                                                        toolResults: toolResults, context: context)
        }

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let text = message["content"] as? String {
                return AIResponse(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                  intent: intent, confidence: 0.95)
            }
        } catch {
            // fall through to mock
        }
        return await MockProvider().generateResponse(input: input, intent: intent,
                                                    toolResults: toolResults, context: context)
    }
}
// MARK: - Protocol Definitions

@MainActor
protocol ToolRegistryProtocol {
    func registerTool(_ tool: ToolInfo)
    func getToolsForIntent(_ intent: AgentIntent) -> [ToolInfo]
    func getAllTools() -> [ToolInfo]
}

@MainActor
class ToolRegistry: ToolRegistryProtocol {
    static let shared = ToolRegistry()
    
    private var tools: [String: ToolInfo] = [:]
    
    func registerTool(_ tool: ToolInfo) {
        tools[tool.name] = tool
    }
    
    func getToolsForIntent(_ intent: AgentIntent) -> [ToolInfo] {
        return Array(tools.values).filter { $0.supportsIntent(intent) }
    }
    
    func getAllTools() -> [ToolInfo] {
        return Array(tools.values)
    }
}

@MainActor
protocol ExtensionSystemProtocol {
    func registerExtension(_ ext: AgentExtension)
    func getTools() -> [ToolInfo]
    func setupBuiltInExtensions()
}

@MainActor
class ExtensionSystem: ExtensionSystemProtocol {
    static let shared = ExtensionSystem()
    
    private var extensions: [String: AgentExtension] = [:]
    private var tools: [ToolInfo] = []
    private weak var terminalController: TerminalController?
    
    func registerExtension(_ ext: AgentExtension) {
        extensions[ext.name] = ext
    }
    
    func getTools() -> [ToolInfo] {
        return tools
    }
    
    func setupBuiltInExtensions() {
        registerBuiltInTools()
    }
    
    /// Configure with TerminalController for real tool implementations
    func configure(with controller: TerminalController) {
        self.terminalController = controller
        // Re-register tools with real implementations
        tools.removeAll()
        registerBuiltInTools()
    }
    
    private func registerBuiltInTools() {
        guard let controller = terminalController else {
            // Fallback to mock implementations if not configured
            registerMockTools()
            return
        }
        
        // Terminal command tool - REAL IMPLEMENTATION
        let terminalTool = ToolInfo(
            name: "terminal_execute",
            description: "Execute terminal commands in the focused session",
            parameters: [
                "command": ParameterProperty(type: .string, description: "Command to execute", defaultValue: ""),
                "sessionId": ParameterProperty(type: .string, description: "Session ID", defaultValue: UUID().uuidString)
            ],
            action: { params in
                let command = params["command"] as? String ?? ""
                let sessionIdString = params["sessionId"] as? String ?? ""
                let sessionId = UUID(uuidString: sessionIdString) ?? controller.focusedSessionId
                // Security: sanitize command to prevent injection
                let sanitized = Self.sanitizeCommand(command)
                controller.send(to: sessionId, sanitized + "\n")
                return "Executed: \(sanitized)"
            }
        )
        tools.append(terminalTool)
        
        // File system tool - REAL IMPLEMENTATION
        let fileTool = ToolInfo(
            name: "file_tree",
            description: "Get file tree for a directory",
            parameters: [
                "path": ParameterProperty(type: .string, description: "Directory path", defaultValue: "."),
                "includeHidden": ParameterProperty(type: .boolean, description: "Include hidden files", defaultValue: false)
            ],
            action: { params in
                let path = params["path"] as? String ?? "."
                let includeHidden = params["includeHidden"] as? Bool ?? false
                let url = URL(fileURLWithPath: path)
                do {
                    let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: includeHidden ? [] : [.skipsHiddenFiles])
                    let tree = contents.map { $0.lastPathComponent }.joined(separator: "\n")
                    return tree.isEmpty ? "Empty directory" : tree
                } catch {
                    return "Error reading directory: \(error.localizedDescription)"
                }
            }
        )
        tools.append(fileTool)
        
        // Theme tool - REAL IMPLEMENTATION
        let themeTool = ToolInfo(
            name: "apply_theme",
            description: "Apply a theme to the terminal",
            parameters: [
                "theme": ParameterProperty(type: .string, description: "Theme name (slug)", defaultValue: "onedark"),
                "options": ParameterProperty(type: .object, description: "Options", defaultValue: [:])
            ],
            action: { params in
                let theme = params["theme"] as? String ?? "onedark"
                if AppTheme.bySlug(theme) != nil {
                    controller.themeName = theme
                    return "Theme '\(theme)' applied successfully"
                } else {
                    return "Theme '\(theme)' not found"
                }
            }
        )
        tools.append(themeTool)

        // --- Additional real macterm tools (drive the app directly) ---

        let newTabTool = ToolInfo(
            name: "macterm_new_tab",
            description: "Open a new terminal tab",
            parameters: [
                "cwd": ParameterProperty(type: .string, description: "Initial directory (optional)", defaultValue: "")
            ],
            action: { params in
                let cwd = params["cwd"] as? String
                controller.newTab(cwd: (cwd != nil && !cwd!.isEmpty) ? cwd : nil)
                return "Opened a new tab" + ((cwd != nil && !cwd!.isEmpty) ? " in \(cwd!)" : "")
            }
        )
        tools.append(newTabTool)

        let splitTool = ToolInfo(
            name: "macterm_split_pane",
            description: "Split the focused pane (vertical = side by side, horizontal = stacked)",
            parameters: [
                "vertical": ParameterProperty(type: .boolean, description: "true = side-by-side, false = stacked", defaultValue: true)
            ],
            action: { params in
                let vertical = params["vertical"] as? Bool ?? true
                controller.splitFocused(vertical: vertical)
                return "Split focused pane \(vertical ? "vertically" : "horizontally")"
            }
        )
        tools.append(splitTool)

        let closePaneTool = ToolInfo(
            name: "macterm_close_pane",
            description: "Close the focused terminal pane",
            parameters: [:],
            action: { _ in
                controller.perform("closePane")
                return "Closed focused pane"
            }
        )
        tools.append(closePaneTool)

        let openFileTool = ToolInfo(
            name: "macterm_open_file",
            description: "Open a file path in the in-app editor",
            parameters: [
                "path": ParameterProperty(type: .string, description: "Absolute file path", defaultValue: "")
            ],
            action: { params in
                guard let path = params["path"] as? String, !path.isEmpty else {
                    return "Error: path parameter required"
                }
                controller.openFile(URL(fileURLWithPath: path))
                return "Opened \(path) in editor"
            }
        )
        tools.append(openFileTool)

        let cdTool = ToolInfo(
            name: "macterm_cd",
            description: "Change directory in a terminal session",
            parameters: [
                "path": ParameterProperty(type: .string, description: "Target directory", defaultValue: "~"),
                "sessionId": ParameterProperty(type: .string, description: "Session UUID (defaults to focused)", defaultValue: "")
            ],
            action: { params in
                let path = params["path"] as? String ?? "~"
                let sessionIdString = params["sessionId"] as? String ?? ""
                let id = UUID(uuidString: sessionIdString) ?? controller.focusedSessionId
                controller.send(to: id, "cd \(path)\n")
                return "Sent: cd \(path)"
            }
        )
        tools.append(cdTool)

        let listSessionsTool = ToolInfo(
            name: "macterm_list_sessions",
            description: "List open terminal sessions with title and working directory",
            parameters: [:],
            action: { _ in
                guard !controller.sessions.isEmpty else { return "No open sessions" }
                let lines = controller.sessions.map { s in
                    "\(s.title) — \(s.cwd ?? "n/a")\(s.id == controller.focusedSessionId ? " (focused)" : "")"
                }
                return lines.joined(separator: "\n")
            }
        )
        tools.append(listSessionsTool)

        let getCwdTool = ToolInfo(
            name: "macterm_get_cwd",
            description: "Get the working directory of the focused session",
            parameters: [:],
            action: { _ in
                return controller.activeCwd ?? "unknown"
            }
        )
        tools.append(getCwdTool)

        let clearTool = ToolInfo(
            name: "macterm_clear",
            description: "Clear the focused terminal screen",
            parameters: [:],
            action: { _ in
                controller.clearActive()
                return "Cleared terminal"
            }
        )
        tools.append(clearTool)

        let themeCycleTool = ToolInfo(
            name: "macterm_theme_cycle",
            description: "Cycle to the next terminal theme",
            parameters: [:],
            action: { _ in
                controller.perform("themeCycleNext")
                return "Cycled to next theme: \(controller.themeName)"
            }
        )
        tools.append(themeCycleTool)
    }
    
    private func registerMockTools() {
        // Terminal command tool (mock)
        let terminalTool = ToolInfo(
            name: "terminal_execute",
            description: "Execute terminal commands",
            parameters: [
                "command": ParameterProperty(type: .string, description: "Command to execute", defaultValue: ""),
                "sessionId": ParameterProperty(type: .string, description: "Session ID", defaultValue: UUID().uuidString)
            ],
            action: { params in
                let command = params["command"] as? String ?? ""
                let sessionId = params["sessionId"] as? String ?? UUID().uuidString
                return "Terminal command executed: \(command) (session: \(sessionId))"
            }
        )
        tools.append(terminalTool)
        
        // File system tool (mock)
        let fileTool = ToolInfo(
            name: "file_tree",
            description: "Get file tree",
            parameters: [
                "path": ParameterProperty(type: .string, description: "Directory path", defaultValue: "."),
                "includeHidden": ParameterProperty(type: .boolean, description: "Include hidden files", defaultValue: false)
            ],
            action: { params in
                let path = params["path"] as? String ?? "."
                let includeHidden = params["includeHidden"] as? Bool ?? false
                return "File tree for: \(path), include hidden: \(includeHidden)"
            }
        )
        tools.append(fileTool)
        
        // Theme tool (mock)
        let themeTool = ToolInfo(
            name: "apply_theme",
            description: "Apply theme",
            parameters: [
                "theme": ParameterProperty(type: .string, description: "Theme name", defaultValue: "onedark"),
                "options": ParameterProperty(type: .object, description: "Options", defaultValue: [:])
            ],
            action: { params in
                let theme = params["theme"] as? String ?? "onedark"
                let options = params["options"] as? [String: Any] ?? [:]
                return "Theme \(theme) applied with options: \(options)"
            }
        )
        tools.append(themeTool)
        }
    
    /// Sanitize shell command to prevent command injection.
    /// Allows only safe characters: alphanumeric, spaces, and common CLI punctuation.
    /// Rejects command separators (;, &, |, $, `, >, <) and control characters.
    static func sanitizeCommand(_ input: String) -> String {
        // Allow: alphanumeric, space, dash, underscore, dot, slash, colon, equals, comma, @, %
        // Block: ; & | $ ` > < \n \r \t and other control chars
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: " -_./:=,@%"))
            .union(CharacterSet.whitespaces)
        var result = ""
        for scalar in input.unicodeScalars {
            if allowed.contains(scalar) {
                result.append(String(scalar))
            }
        }
        // Collapse multiple spaces
        return result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }
}

protocol AgentExtension {
    var name: String { get }
    var version: String { get }
    var description: String { get }
    func setup()
}

// MARK: - Context Models

class AgentContext {
    let sessionId: UUID?
    let workingDirectory: String?
    let theme: String?
    let intent: AgentIntent?
    let timestamp: Date
    
    init(
        sessionId: UUID? = nil,
        workingDirectory: String? = nil,
        theme: String? = nil,
        intent: AgentIntent? = nil,
        timestamp: Date = Date()
    ) {
        self.sessionId = sessionId
        self.workingDirectory = workingDirectory
        self.theme = theme
        self.intent = intent
        self.timestamp = timestamp
    }
}
