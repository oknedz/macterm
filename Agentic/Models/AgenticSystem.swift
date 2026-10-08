// Copyright © 2026 Zdenko. All rights reserved.
import Foundation
import Security
import FoundationModels
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

    /// LLM provider for response generation. Rebuilt from the active ProviderRegistry
    /// config whenever the user changes providers/keys in Settings.
    var provider: AgentProvider = ProviderRegistry.shared.makeActive()
    /// Rebuild `provider` from the active ProviderRegistry config. Call after the
    /// user changes the selected provider, its key, or its model in Settings.
    func reloadProvider() {
        provider = ProviderRegistry.shared.makeActive()
    }
    
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
    
    /// Process user input with multi-step agentic loop (planning + tool execution)
    func processUserInput(_ input: String, context: AgentContext) async {
        workflowState = .analyzing
        if conversationHistory.count > 200 {
            conversationHistory.removeFirst(conversationHistory.count - 200)
        }

        let userMessage = AgentMessage(role: .user, content: input, timestamp: Date(), toolCalls: [])
        conversationHistory.append(userMessage)

        await runAgentLoop(context: context)

        workflowState = .completing
        workflowState = .idle
    }
    
    /// Main agentic loop: plan -> act -> observe -> repeat
    private func runAgentLoop(context: AgentContext) async {
        let allTools = extensionSystem.getTools()
        let maxIterations = 10
        var iteration = 0
        
        // Create initial assistant message placeholder
        let assistant = AgentMessage(
            role: .assistant,
            content: "",
            timestamp: Date(),
            toolCalls: []
        )
        conversationHistory.append(assistant)
        let assistantId = assistant.id
        
        workflowState = .planning
        
        while iteration < maxIterations {
            iteration += 1
            
            // Build messages from conversation history
            let messages = buildMessages(history: conversationHistory, tools: allTools, context: context)
            
            do {
                workflowState = .executing
                
                // Get response from provider (with function calling)
                var fullResponse = ""
                var toolCalls: [LLMToolCall] = []
                
                for try await piece in provider.streamResponse(messages: messages, tools: allTools, context: context) {
                    // Check for tool calls marker from streaming
                    if piece.hasPrefix("__TOOL_CALLS__:") {
                        let jsonStr = piece.dropFirst("__TOOL_CALLS__:".count)
                        if let data = jsonStr.data(using: .utf8),
                           let calls = try? JSONDecoder().decode([LLMToolCall].self, from: data) {
                            toolCalls = calls
                        }
                        continue
                    }
                    
                    // Regular content piece
                    fullResponse += piece
                    
                    // Update conversation history with streaming content
                    if let i = conversationHistory.firstIndex(where: { $0.id == assistantId }) {
                        let cur = conversationHistory[i]
                        conversationHistory[i] = AgentMessage(
                            id: assistantId,
                            role: .assistant,
                            content: cur.content + piece,
                            timestamp: cur.timestamp,
                            toolCalls: cur.toolCalls
                        )
                    }
                }
                
                // If no tool calls in stream, check the final response for tool calls (non-streaming fallback)
                if toolCalls.isEmpty && fullResponse.hasPrefix("[") && fullResponse.contains("\"name\"") {
                    // Try to parse as tool calls array
                    if let data = fullResponse.data(using: .utf8),
                       let calls = try? JSONDecoder().decode([LLMToolCall].self, from: data) {
                        toolCalls = calls
                        fullResponse = ""
                    }
                }
                
                // If we have tool calls, execute them
                if !toolCalls.isEmpty {
                    workflowState = .executing
                    
                    // Update assistant message with tool calls
                    let toolCallRecords = toolCalls.map { tc in
                        ToolCall(id: tc.id, name: tc.name, parameters: parseToolArguments(tc.arguments), result: nil)
                    }
                    if let i = conversationHistory.firstIndex(where: { $0.id == assistantId }) {
                        let cur = conversationHistory[i]
                        conversationHistory[i] = AgentMessage(
                            id: assistantId,
                            role: .assistant,
                            content: cur.content,
                            timestamp: cur.timestamp,
                            toolCalls: toolCallRecords
                        )
                    }
                    
                    // Execute each tool call
                    var toolResults: [LLMToolResult] = []
                    for tc in toolCalls {
                        let result = await executeToolCall(tc, context: context)
                        toolResults.append(result)
                    }
                    
                    // Add tool results to conversation as tool messages
                    for tr in toolResults {
                        conversationHistory.append(
                            AgentMessage(
                                role: .assistant, // Will be rendered as tool result
                                content: tr.result,
                                timestamp: Date(),
                                toolCalls: [ToolCall(id: tr.toolCallId, name: tr.name, parameters: [:], result: tr.result)]
                            )
                        )
                    }
                    
                    // Continue loop - send tool results back to LLM
                    continue
                }
                
                // No tool calls - we have a final response
                workflowState = .completing
                break
                
            } catch {
                if let i = conversationHistory.firstIndex(where: { $0.id == assistantId }) {
                    let cur = conversationHistory[i]
                    let note = "⚠️ \(error.localizedDescription)"
                    conversationHistory[i] = AgentMessage(
                        id: assistantId,
                        role: .assistant,
                        content: cur.content.isEmpty ? note : cur.content + "\n\n" + note,
                        timestamp: cur.timestamp,
                        toolCalls: cur.toolCalls
                    )
                }
                break
            }
        }
        
        if iteration >= maxIterations {
            if let i = conversationHistory.firstIndex(where: { $0.id == assistantId }) {
                let cur = conversationHistory[i]
                conversationHistory[i] = AgentMessage(
                    id: assistantId,
                    role: .assistant,
                    content: cur.content + "\n\n⚠️ Maximum iterations reached. Stopping.",
                    timestamp: cur.timestamp,
                    toolCalls: cur.toolCalls
                )
            }
        }
    }
    
    /// Execute a single tool call and return result
    private func executeToolCall(_ call: LLMToolCall, context: AgentContext) async -> LLMToolResult {
        guard let tool = allTools.first(where: { $0.name == call.name }) else {
            return LLMToolResult(toolCallId: call.id, name: call.name, result: "", error: "Unknown tool: \(call.name)")
        }
        
        let parameters = parseToolArguments(call.arguments)
        
        do {
            let value = try await tool.action(parameters)
            // Handle Any result - optional or concrete value
            let resultStr: String
            if let opt = value as? String? {
                resultStr = opt ?? "Done"
            } else if let str = value as? String {
                resultStr = str
            } else {
                resultStr = String(describing: value)
            }
            return LLMToolResult(toolCallId: call.id, name: call.name, result: resultStr.isEmpty ? "Done" : resultStr, error: nil)
        } catch {
            return LLMToolResult(toolCallId: call.id, name: call.name, result: "", error: error.localizedDescription)
        }
    }
    
    /// Parse JSON arguments string to dictionary
    private func parseToolArguments(_ jsonStr: String) -> [String: Any] {
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Try simple key:value parsing as fallback
            var params: [String: Any] = [:]
            let parts = jsonStr.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            for part in parts {
                let kv = part.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
                if kv.count == 2 {
                    let key = kv[0].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    let val = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    params[key] = val
                }
            }
            return params
        }
        return obj
    }
    
    /// All available tools (computed property for tool execution)
    private var allTools: [ToolInfo] {
        extensionSystem.getTools()
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
    let id: UUID
    let role: MessageRole
    let content: String
    let toolCalls: [ToolCall]
    let timestamp: Date
    
    init(id: UUID = UUID(), role: MessageRole, content: String, timestamp: Date, toolCalls: [ToolCall] = []) {
        self.id = id
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

struct ParameterProperty {
    let type: ParameterType
    let description: String
    let defaultValue: Any?
    let enumValues: [String]?
    let items: ParameterPropertyBox? // for array type
    
    init(type: ParameterType, description: String, defaultValue: Any? = nil, enumValues: [String]? = nil, items: ParameterPropertyBox? = nil) {
        self.type = type
        self.description = description
        self.defaultValue = defaultValue
        self.enumValues = enumValues
        self.items = items
    }
    /// JSON Schema representation for function calling
    var jsonSchema: [String: Any] {
        var schema: [String: Any] = [
            "type": type.schemaType,
            "description": description
        ]
        if let enumValues = enumValues, !enumValues.isEmpty {
            schema["enum"] = enumValues
        }
        if let defaultValue = defaultValue {
            schema["default"] = defaultValue
        }
        if type == .array, let items = items {
            schema["items"] = items.value.jsonSchema
        }
        return schema
    }
}

/// Box to allow recursive ParameterProperty reference
final class ParameterPropertyBox {
    let value: ParameterProperty
    init(_ value: ParameterProperty) { self.value = value }
}

enum ParameterType {
    case string, number, boolean, object, array
    
    var schemaType: String {
        switch self {
        case .string: return "string"
        case .number: return "number"
        case .boolean: return "boolean"
        case .object: return "object"
        case .array: return "array"
        }
    }
}

/// Tool information for function calling with JSON Schema support

/// Tool information for function calling with JSON Schema support
struct ToolInfo {
    let name: String
    let description: String
    let parameters: [String: ParameterProperty]
    let action: ([String: Any]) async throws -> Any
    let supportsIntent: (AgentIntent) -> Bool
    
    init(
        name: String,
        description: String,
        parameters: [String: ParameterProperty] = [:],
        supportsIntent: @escaping (AgentIntent) -> Bool = { _ in true },
        action: @escaping ([String: Any]) async throws -> Any
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.supportsIntent = supportsIntent
        self.action = action
    }
    
    /// OpenAI-compatible function schema for structured function calling
    var jsonSchema: [String: Any] {
        var properties: [String: Any] = [:]
        var required: [String] = []
        
        for (key, prop) in parameters {
            properties[key] = prop.jsonSchema
            // Consider a property required if it has no default value
            if prop.defaultValue == nil {
                required.append(key)
            }
        }
        
        return [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": required,
                    "additionalProperties": false
                ]
            ]
        ]
    }
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
// MARK: - Provider errors (surfaced to the UI instead of silently mocking)

enum AgentProviderError: LocalizedError {
    case missingKey
    case unauthorized
    case rateLimited
    case network(Error)
    case unavailable
    case parseFailed
    case empty
    case unknown(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .missingKey:       return "Missing API key — add it in Settings → AI."
        case .unauthorized:     return "Invalid or unauthorized API key (401)."
        case .rateLimited:      return "Rate limited by the provider (429). Try again shortly."
        case .network(let e):   return "Network error: \(e.localizedDescription)"
        case .unavailable:      return "This model/provider is unavailable on this device."
        case .parseFailed:      return "Could not parse the provider response."
        case .empty:            return "The provider returned an empty response."
        case .unknown(let s, let b): return "Provider error (\(s)): \(String(b.prefix(200)))"
        }
    }
}

// MARK: - Provider model (data-driven, user-managed)

enum ProviderType: String, Codable, CaseIterable, Identifiable {
    case mock, openrouter, openAICompatible, foundation, huggingface, omp
    case deepseek, nvidia, opencodeZen, opencodeGo, localLLM, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .mock: return "Mock (offline)"
        case .openrouter: return "OpenRouter"
        case .openAICompatible: return "OpenAI-compatible (local / custom)"
        case .foundation: return "Apple on-device (FoundationModels)"
        case .huggingface: return "HuggingFace"
        case .omp: return "OMP Agent"
        case .deepseek: return "Deepseek"
        case .nvidia: return "Nvidia (NIM)"
        case .opencodeZen: return "Opencode Zen"
        case .opencodeGo: return "Opencode Go"
        case .localLLM: return "Local LLM (LM Studio / Ollama)"
        case .custom: return "Custom (OpenAI-compatible)"
        }
    }
    var needsBaseURL: Bool { self == .openAICompatible || self == .huggingface || self == .localLLM || self == .custom }
    var needsKey: Bool { self == .openrouter || self == .huggingface || self == .deepseek || self == .nvidia || self == .opencodeZen || self == .opencodeGo || self == .custom }
    var canListModels: Bool { self == .openrouter || self == .openAICompatible || self == .deepseek || self == .nvidia || self == .opencodeZen || self == .opencodeGo || self == .localLLM || self == .custom }
    var supportsStreaming: Bool { self == .openrouter || self == .openAICompatible || self == .foundation || self == .deepseek || self == .nvidia || self == .opencodeZen || self == .opencodeGo || self == .localLLM || self == .custom }
    var requiresmacOS26: Bool { self == .foundation }
}

struct ProviderConfig: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var type: ProviderType
    var baseURL: String
    var keychainKey: String
    var isBuiltIn: Bool
    var staticModels: [String]
    var selectedModel: String
    var temperature: Double
    var supportsStreaming: Bool

    init(id: String = UUID().uuidString, name: String, type: ProviderType,
         baseURL: String = "", keychainKey: String = "", isBuiltIn: Bool = false,
         staticModels: [String] = [], selectedModel: String = "",
        temperature: Double = 0.3, supportsStreaming: Bool? = nil) {
        self.id = id; self.name = name; self.type = type; self.baseURL = baseURL
        self.keychainKey = keychainKey; self.isBuiltIn = isBuiltIn
        self.staticModels = staticModels; self.selectedModel = selectedModel
        self.temperature = temperature
        self.supportsStreaming = supportsStreaming ?? type.supportsStreaming
    }

    /// Resolved API key from the Keychain (nil for local/none).
    var apiKey: String? { keychainKey.isEmpty ? nil : KeychainStore.get(keychainKey) }

    /// Model id to send when none is selected, per provider type.
    var effectiveModel: String {
        if !selectedModel.isEmpty { return selectedModel }
        switch type {
        case .openrouter: return "openai/gpt-4o-mini"
        case .openAICompatible, .deepseek, .nvidia, .opencodeZen, .opencodeGo, .localLLM, .custom:
            return staticModels.first ?? "local-model"
        case .huggingface: return staticModels.first ?? ""
        case .foundation: return "system"
        default: return ""
        }
    }
}

// MARK: - Async model catalog (used by the Settings model picker)

/// A single model offered by a provider. `isFree` lets the UI filter to
/// free-tier models (e.g. OpenRouter `:free` ids).
struct AIModel: Identifiable {
    let id: String
    let name: String
    let isFree: Bool
}

extension ProviderConfig {
    /// Async model list for this provider.
    /// - For providers exposing OpenAI-compatible `/models`, fetch + map them,
    ///   marking known-free ids (`isFree == true`).
    /// - Otherwise mirror `staticModels`.
    /// Never throws to the caller: on any failure it falls back to `staticModels`
    /// so the UI always has something to render.
    func fetchModels() async -> [AIModel] {
        guard type.canListModels, type != .foundation else {
            return staticModels.map { AIModel(id: $0, name: $0, isFree: false) }
        }
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/models") else {
            return staticModels.map { AIModel(id: $0, name: $0, isFree: false) }
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("macterm", forHTTPHeaderField: "HTTP-Referer")
        if let key = apiKey, !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 30
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return staticModels.map { AIModel(id: $0, name: $0, isFree: false) }
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = json["data"] as? [[String: Any]] else {
                return staticModels.map { AIModel(id: $0, name: $0, isFree: false) }
            }
            let models = list.compactMap { $0["id"] as? String }
                .map { AIModel(id: $0, name: $0, isFree: $0.lowercased().contains("free")) }
            return models.isEmpty
                ? staticModels.map { AIModel(id: $0, name: $0, isFree: false) }
                : models
        } catch {
            return staticModels.map { AIModel(id: $0, name: $0, isFree: false) }
        }
    }
}

// MARK: - Keychain (no third-party deps)

enum KeychainStore {
    static func set(_ value: String, for account: String) {
        let data = Data(value.utf8)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrAccount as String: account,
                                kSecValueData as String: data]
        SecItemDelete(q as CFDictionary)
        SecItemAdd(q as CFDictionary, nil)
    }
    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var ref: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &ref) == errSecSuccess,
              let data = ref as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func delete(_ account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}

// MARK: - Provider registry (persisted, user-editable)

@MainActor
final class ProviderRegistry: ObservableObject {
    static let shared = ProviderRegistry()
    @Published var providers: [ProviderConfig] = []
    @Published var selectedId: String = ""
    private let storeKey = "macterm.providers.v1"

    init() { migrateLegacyKeys(); load() }

    /// Seed built-in providers and migrate the legacy UserDefaults key/model.
    private func migrateLegacyKeys() {
        if let legacy = UserDefaults.standard.string(forKey: "openRouterKey"), !legacy.isEmpty {
            KeychainStore.set(legacy, for: "openrouter")
            UserDefaults.standard.removeObject(forKey: "openRouterKey")
        }
    }

    var active: ProviderConfig {
        providers.first(where: { $0.id == selectedId })
            ?? providers.first
            ?? ProviderConfig.builtIns.first!
    }

    func select(_ id: String) {
        selectedId = id
        UserDefaults.standard.set(id, forKey: "macterm.selectedProvider")
    }
    func add(_ c: ProviderConfig) { providers.append(c); save() }
    func update(_ c: ProviderConfig) {
        if let i = providers.firstIndex(where: { $0.id == c.id }) { providers[i] = c; save() }
    }
    func remove(_ c: ProviderConfig) {
        guard !c.isBuiltIn else { return }
        providers.removeAll { $0.id == c.id }
        save()
    }
    func save() {
        if let d = try? JSONEncoder().encode(providers) {
            UserDefaults.standard.set(d, forKey: storeKey)
        }
    }
    func load() {
        if let d = UserDefaults.standard.data(forKey: storeKey),
           let list = try? JSONDecoder().decode([ProviderConfig].self, from: d), !list.isEmpty {
            providers = list
        } else {
            providers = ProviderConfig.builtIns
        }
        selectedId = UserDefaults.standard.string(forKey: "macterm.selectedProvider")
            ?? providers.first(where: { $0.type != .mock && $0.type != .foundation })?.id
            ?? providers.first!.id
    }

    /// Build the live AgentProvider for the active config.
    func makeActive() -> AgentProvider { AgentProviderFactory.make(active) }

    /// Wipe user-added providers and restore the built-in set (used by Reset All Settings).
    func resetToBuiltIns() {
        UserDefaults.standard.removeObject(forKey: storeKey)
        UserDefaults.standard.removeObject(forKey: "macterm.selectedProvider")
        load()
    }
}

extension ProviderConfig {
    static let builtIns: [ProviderConfig] = [
        ProviderConfig(name: "OpenRouter", type: .openrouter,
                       baseURL: "https://openrouter.ai/api/v1", keychainKey: "openrouter",
                       isBuiltIn: true,
                       selectedModel: UserDefaults.standard.string(forKey: "aiModel") ?? "openai/gpt-4o-mini"),
        ProviderConfig(name: "Deepseek", type: .deepseek,
                       baseURL: "https://api.deepseek.com", keychainKey: "deepseek",
                       isBuiltIn: true,
                       staticModels: ["deepseek-chat"], selectedModel: "deepseek-chat"),
        ProviderConfig(name: "Nvidia (NIM)", type: .nvidia,
                       baseURL: "https://integrate.api.nvidia.com/v1", keychainKey: "nvidia",
                       isBuiltIn: true,
                       staticModels: ["meta/llama-3.1-8b-instruct"],
                       selectedModel: "meta/llama-3.1-8b-instruct"),
        ProviderConfig(name: "Opencode Zen", type: .opencodeZen,
                       baseURL: "https://zen.opencode.ai/api/v1", keychainKey: "opencodeZen",
                       isBuiltIn: true,
                       staticModels: ["gpt-4o-mini"], selectedModel: "gpt-4o-mini"),
        ProviderConfig(name: "Opencode Go", type: .opencodeGo,
                       baseURL: "https://go.opencode.ai/api/v1", keychainKey: "opencodeGo",
                       isBuiltIn: true,
                       staticModels: ["gpt-4o-mini"], selectedModel: "gpt-4o-mini"),
        ProviderConfig(name: "Local LLM (LM Studio / Ollama)", type: .localLLM,
                       baseURL: "http://localhost:1234/v1", isBuiltIn: true,
                       staticModels: ["local-model"], selectedModel: "local-model"),
        ProviderConfig(name: "HuggingFace", type: .huggingface,
                       baseURL: "https://api-inference.huggingface.co", keychainKey: "huggingface",
                       isBuiltIn: true,
                       staticModels: ["meta-llama/Llama-3.1-8B-Instruct"],
                       selectedModel: "meta-llama/Llama-3.1-8B-Instruct")
    ]
}

// MARK: - Function Calling Types

/// A tool call requested by the LLM
struct LLMToolCall: Codable, Equatable {
    let id: String
    let name: String
    let arguments: String // JSON string of arguments
}

/// Result of a tool execution to send back to LLM
struct LLMToolResult: Codable, Equatable {
    let toolCallId: String
    let name: String
    let result: String
    let error: String?
}

/// Message in the conversation for function calling
enum ChatMessage: Codable, Equatable {
    case system(String)
    case user(String)
    case assistant(String, toolCalls: [LLMToolCall]?)
    case tool(LLMToolResult)
    
    var role: String {
        switch self {
        case .system: return "system"
        case .user: return "user"
        case .assistant: return "assistant"
        case .tool: return "tool"
        }
    }
    
    var content: String? {
        switch self {
        case .system(let c), .user(let c): return c
        case .assistant(let c, _): return c
        case .tool(let r): return r.result
        }
    }
    
    var toolCalls: [LLMToolCall]? {
        if case .assistant(_, let calls) = self { return calls }
        return nil
    }
    
    var toolCallId: String? {
        if case .tool(let r) = self { return r.toolCallId }
        return nil
    }
    
    func toOpenAIFormat() -> [String: Any] {
        switch self {
        case .system(let c):
            return ["role": "system", "content": c]
        case .user(let c):
            return ["role": "user", "content": c]
        case .assistant(let c, let calls):
            var dict: [String: Any] = ["role": "assistant", "content": c]
            if let calls = calls, !calls.isEmpty {
                dict["tool_calls"] = calls.map { call in
                    [
                        "id": call.id,
                        "type": "function",
                        "function": [
                            "name": call.name,
                            "arguments": call.arguments
                        ]
                    ]
                }
            }
            return dict
        case .tool(let r):
            return [
                "role": "tool",
                "tool_call_id": r.toolCallId,
                "name": r.name,
                "content": r.result
            ]
        }
    }
}

// MARK: - Provider protocol (streaming by default)

protocol AgentProvider {
    var config: ProviderConfig { get }
    func generateResponse(messages: [ChatMessage], tools: [ToolInfo], context: AgentContext) async throws -> AIResponse
    func streamResponse(messages: [ChatMessage], tools: [ToolInfo], context: AgentContext) -> AsyncThrowingStream<String, Error>
}

extension AgentProvider {
    /// Default streaming: wrap the non-streaming call as a single token.
    func streamResponse(messages: [ChatMessage], tools: [ToolInfo], context: AgentContext) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let r = try await generateResponse(messages: messages, tools: tools, context: context)
                    continuation.yield(r.text)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

// MARK: - Shared prompt/message builders

/// Build the system prompt with available tools
private func buildSystemPrompt(tools: [ToolInfo]) -> String {
    var prompt = "You are \(ProcessInfo.processInfo.processName)'s built-in assistant for terminal, file, theme and session tasks. Be concise and concrete.\n\n"
    if !tools.isEmpty {
        prompt += "You have access to the following tools. Use them when appropriate:\n"
        for tool in tools {
            prompt += "- \(tool.name): \(tool.description)\n"
            if !tool.parameters.isEmpty {
                prompt += "  Parameters: \(tool.parameters.keys.joined(separator: ", "))\n"
            }
        }
        prompt += "\nWhen you need to use a tool, respond with a tool call. The system will execute it and return the result.\n"
    }
    return prompt
}

/// Convert conversation history to ChatMessage array for function calling
private func buildMessages(
    history: [AgentMessage],
    tools: [ToolInfo],
    context: AgentContext
) -> [ChatMessage] {
    var messages: [ChatMessage] = []
    messages.append(.system(buildSystemPrompt(tools: tools)))
    
    for msg in history {
        switch msg.role {
        case .user:
            messages.append(.user(msg.content))
        case .assistant:
            if !msg.toolCalls.isEmpty {
                let llmCalls = msg.toolCalls.map { tc in
                    LLMToolCall(id: tc.id, name: tc.name, arguments: tc.parameters.compactMap { "\($0.key): \($0.value)" }.joined(separator: ", "))
                }
                messages.append(.assistant(msg.content, toolCalls: llmCalls))
            } else {
                messages.append(.assistant(msg.content, toolCalls: nil))
            }
        case .system:
            messages.append(.system(msg.content))
        }
    }
    
    return messages
}

/// Legacy prompt builder for providers that don't support function calling
private func buildPrompt(input: String, intent: AgentIntent, toolResults: [ToolResult], context: AgentContext) -> String {
    var s = "You are a terminal assistant. Be concise and concrete.\n"
    if !toolResults.isEmpty {
        s += "Tool results:\n" + toolResults.map { "\($0.toolName): \($0.result.map { String(describing: $0) } ?? "ok")" }.joined(separator: "\n") + "\n"
    }
    s += "User: \(input)"
    return s
}

// MARK: - Mock

struct MockProvider: AgentProvider {
    let config: ProviderConfig
    init(_ config: ProviderConfig = ProviderConfig(name: "Mock", type: .mock)) { self.config = config }

    func generateResponse(messages: [ChatMessage], tools: [ToolInfo], context: AgentContext) async throws -> AIResponse {
        // Simple mock that responds based on last user message
        let lastUser = messages.last { if case .user = $0 { return true }; return false }
        let input = lastUser?.content ?? ""
        let lowercased = input.lowercased()
        
        var responseText: String
        if lowercased.contains("theme") || lowercased.contains("appearance") {
            responseText = "I'll help you apply the theme. The theme \(extractThemeName(from: input) ?? "onedark") will be applied to your terminal."
        } else if lowercased.contains("file") || lowercased.contains("directory") || lowercased.contains("folder") || lowercased.contains("open") {
            responseText = "I'll help you access the file system. I can show you the directory structure and contents."
        } else if lowercased.contains("terminal") || lowercased.contains("execute") || lowercased.contains("run") || lowercased.contains("command") || lowercased.contains("cd") || lowercased.contains("clear") {
            responseText = "I'll execute your terminal command: \(input)"
        } else {
            responseText = "I'll help you with that request using the available tools."
        }
        return AIResponse(text: responseText, intent: AgentIntent(type: .tool_execution), confidence: 0.85)
    }
}

// MARK: - OpenAI-compatible (OpenRouter, local Ollama/LM Studio, custom TGI)

struct OpenAICompatibleProvider: AgentProvider {
    let config: ProviderConfig
    init(_ config: ProviderConfig) { self.config = config }

    func generateResponse(messages: [ChatMessage], tools: [ToolInfo], context: AgentContext) async throws -> AIResponse {
        do {
            let req = try Self.makeRequest(config: config, messages: messages, tools: tools, stream: false)
            let (data, resp) = try await URLSession.shared.data(for: req)
            try Self.assertOK(resp, data: data)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any] else { throw AgentProviderError.parseFailed }
            
            // Handle tool calls
            if let toolCalls = message["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
                // Return tool calls as JSON for the agent loop to execute
                let toolCallsData = try JSONSerialization.data(withJSONObject: toolCalls)
                let toolCallsJson = String(data: toolCallsData, encoding: .utf8) ?? "[]"
                return AIResponse(text: toolCallsJson, intent: AgentIntent(type: .tool_execution), confidence: 0.95)
            }
            
            let text = message["content"] as? String ?? ""
            return AIResponse(text: text.trimmingCharacters(in: .whitespacesAndNewlines), intent: AgentIntent(type: .tool_execution), confidence: 0.95)
        } catch {
            throw Self.map(error)
        }
    }

    func streamResponse(messages: [ChatMessage], tools: [ToolInfo], context: AgentContext) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let req = try Self.makeRequest(config: config, messages: messages, tools: tools, stream: true)
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    try Self.assertOK(resp, data: nil)
                    var buffer = ""
                    var toolCallsBuffer: [[String: Any]] = []
                    var isToolCall = false
                    
                    for try await line in bytes.lines {
                        let l = line.trimmingCharacters(in: .whitespaces)
                        guard l.hasPrefix("data:") else { continue }
                        let payload = l.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        if let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                           let choices = json["choices"] as? [[String: Any]],
                           let delta = choices.first?["delta"] as? [String: Any] {
                            
                            // Handle tool calls in streaming
                            if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                                isToolCall = true
                                for tc in toolCalls {
                                    let index = (tc["index"] as? Int) ?? 0
                                    while toolCallsBuffer.count <= index {
                                        toolCallsBuffer.append([:])
                                    }
                                    // Merge tool call chunks
                                    if let id = tc["id"] as? String { toolCallsBuffer[index]["id"] = id }
                                    if let type = tc["type"] as? String { toolCallsBuffer[index]["type"] = type }
                                    if let function = tc["function"] as? [String: Any] {
                                        var fn = toolCallsBuffer[index]["function"] as? [String: Any] ?? [:]
                                        if let name = function["name"] as? String { fn["name"] = name }
                                        if let args = function["arguments"] as? String {
                                            fn["arguments"] = (fn["arguments"] as? String ?? "") + args
                                        }
                                        toolCallsBuffer[index]["function"] = fn
                                    }
                                }
                            }
                            
                            // Handle content
                            if let piece = delta["content"] as? String, !piece.isEmpty {
                                if !isToolCall {
                                    continuation.yield(piece)
                                }
                                buffer += piece
                            }
                        }
                    }
                    
                    // If we got tool calls, send them as a special marker
                    if !toolCallsBuffer.isEmpty {
                        let toolCallsData = try JSONSerialization.data(withJSONObject: toolCallsBuffer)
                        let toolCallsJson = String(data: toolCallsData, encoding: .utf8) ?? "[]"
                        continuation.yield("__TOOL_CALLS__:" + toolCallsJson)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.map(error))
                }
            }
        }
    }

    static func makeRequest(config: ProviderConfig, messages: [ChatMessage], tools: [ToolInfo], stream: Bool) throws -> URLRequest {
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/chat/completions") else { throw AgentProviderError.parseFailed }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("macterm", forHTTPHeaderField: "HTTP-Referer")
        if let key = config.apiKey, !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 60
        
        let openAIMessages = messages.map { $0.toOpenAIFormat() }
        
        var body: [String: Any] = [
            "model": config.effectiveModel,
            "messages": openAIMessages,
            "temperature": config.temperature
        ]
        
        if !tools.isEmpty {
            body["tools"] = tools.map { $0.jsonSchema }
            body["tool_choice"] = "auto"
        }
        
        if stream { body["stream"] = true }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    static func assertOK(_ resp: URLResponse?, data: Data?) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200...299: return
        case 401: throw AgentProviderError.unauthorized
        case 429: throw AgentProviderError.rateLimited
        default:
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = json["error"] as? [String: Any],
               let msg = err["message"] as? String {
                throw AgentProviderError.unknown(status: http.statusCode, body: msg)
            }
            throw AgentProviderError.unknown(status: http.statusCode,
                                             body: String(data: data ?? Data(), encoding: .utf8) ?? "")
        }
    }

    static func map(_ error: Error) -> Error {
        if error is AgentProviderError { return error }
        if (error as NSError).domain == NSURLErrorDomain { return AgentProviderError.network(error) }
        return error
    }
}

// MARK: - HuggingFace Inference API (legacy, no function calling)

struct HuggingFaceProvider: AgentProvider {
    let config: ProviderConfig
    init(_ config: ProviderConfig) { self.config = config }

    func generateResponse(messages: [ChatMessage], tools: [ToolInfo], context: AgentContext) async throws -> AIResponse {
        do {
            let t = try await Self.generate(config: config, messages: messages)
            return AIResponse(text: t, intent: AgentIntent(type: .tool_execution), confidence: 0.9)
        } catch {
            throw Self.map(error)
        }
    }

    static func generate(config: ProviderConfig, messages: [ChatMessage]) async throws -> String {
        guard let key = config.apiKey, !key.isEmpty else { throw AgentProviderError.missingKey }
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/models/\(config.effectiveModel)") else { throw AgentProviderError.parseFailed }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60
        
        // Convert messages to single prompt for HF
        let prompt = messages.map { msg in
            switch msg {
            case .system(let c): return "System: \(c)"
            case .user(let c): return "User: \(c)"
            case .assistant(let c, _): return "Assistant: \(c)"
            case .tool(let r): return "Tool \(r.name): \(r.result)"
            }
        }.joined(separator: "\n")
        
        let body: [String: Any] = ["inputs": prompt,
                                   "parameters": ["return_full_text": false,
                                                  "temperature": config.temperature]]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 401 { throw AgentProviderError.unauthorized }
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           let t = arr.first?["generated_text"] as? String { return t }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let t = obj["generated_text"] as? String { return t }
        if let s = String(data: data, encoding: .utf8), !s.isEmpty {
            throw AgentProviderError.unknown(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, body: s)
        }
        throw AgentProviderError.parseFailed
    }

    static func map(_ error: Error) -> Error {
        error is AgentProviderError ? error : AgentProviderError.unknown(status: 0, body: error.localizedDescription)
    }
}

// MARK: - Apple on-device FoundationModels (macOS 26)

@available(macOS 26, *)
struct FoundationProvider: AgentProvider {
    let config: ProviderConfig
    init(_ config: ProviderConfig) { self.config = config }

    func generateResponse(messages: [ChatMessage], tools: [ToolInfo], context: AgentContext) async throws -> AIResponse {
        var full = ""
        for try await piece in streamResponse(messages: messages, tools: tools, context: context) {
            full += piece
        }
        return AIResponse(text: full, intent: AgentIntent(type: .tool_execution), confidence: 0.95)
    }

    func streamResponse(messages: [ChatMessage], tools: [ToolInfo], context: AgentContext) -> AsyncThrowingStream<String, Error> {
        // FoundationModels doesn't support function calling yet, convert to prompt
        let prompt = messages.map { msg in
            switch msg {
            case .system(let c): return "System: \(c)"
            case .user(let c): return "User: \(c)"
            case .assistant(let c, _): return "Assistant: \(c)"
            case .tool(let r): return "Tool \(r.name): \(r.result)"
            }
        }.joined(separator: "\n")
        return AsyncThrowingStream { continuation in
            Task { @MainActor in
                do {
                    guard SystemLanguageModel.default.isAvailable else { throw AgentProviderError.unavailable }
                    let session = LanguageModelSession()
                    var full = ""
                    for try await partial in session.streamResponse(to: prompt) {
                        let delta = String(partial.content.dropFirst(full.count))
                        full += delta
                        continuation.yield(delta)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.map(error))
                }
            }
        }
    }

    static func map(_ error: Error) -> Error {
        error is AgentProviderError ? error : AgentProviderError.unknown(status: 0, body: error.localizedDescription)
    }
}

// MARK: - OMP (local CLI bridge)

struct OMPAgentProvider: AgentProvider {
    let config: ProviderConfig
    init(_ config: ProviderConfig = ProviderConfig(name: "OMP", type: .omp)) { self.config = config }

    func generateResponse(messages: [ChatMessage], tools: [ToolInfo], context: AgentContext) async throws -> AIResponse {
        // Convert messages to prompt for OMP CLI
        let prompt = messages.map { msg in
            switch msg {
            case .system(let c): return "System: \(c)"
            case .user(let c): return "User: \(c)"
            case .assistant(let c, _): return "Assistant: \(c)"
            case .tool(let r): return "Tool \(r.name): \(r.result)"
            }
        }.joined(separator: "\n")
        
        if let text = await Self.run(prompt: prompt) {
            return AIResponse(text: text, intent: AgentIntent(type: .tool_execution), confidence: 0.9)
        }
        return try await MockProvider(config).generateResponse(messages: messages, tools: tools, context: context)
    }

    static func run(prompt: String) async -> String? {
        await Task.detached(priority: .userInitiated) {
            let which = Process()
            which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            which.arguments = ["omp"]
            let wp = Pipe()
            which.standardOutput = wp
            try? which.run(); which.waitUntilExit()
            guard let path = String(data: wp.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }

            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["ask"]
            let inPipe = Pipe()
            let outPipe = Pipe()
            p.standardInput = inPipe
            p.standardOutput = outPipe
            try? p.run()
            if let data = prompt.data(using: .utf8) { inPipe.fileHandleForWriting.write(data) }
            try? inPipe.fileHandleForWriting.close()
            p.waitUntilExit()
            let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return out?.isEmpty == false ? out : nil
        }.value
    }
}

// MARK: - Factory

@MainActor
enum AgentProviderFactory {
    static func make(_ config: ProviderConfig) -> AgentProvider {
        switch config.type {
        case .mock:           return MockProvider(config)
        case .openrouter, .openAICompatible, .deepseek, .nvidia, .opencodeZen, .opencodeGo, .localLLM, .custom:
            return OpenAICompatibleProvider(config)
        case .huggingface:    return HuggingFaceProvider(config)
        case .omp:            return OMPAgentProvider(config)
        case .foundation:
            if #available(macOS 26, *) { return FoundationProvider(config) }
            return MockProvider(config)
        }
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

// MARK: - Model Catalog (OpenRouter)

/// One entry from the OpenRouter model catalog. `provider` is derived from the
/// `id` prefix (e.g. `"anthropic/claude-3.5-sonnet"` → `"anthropic"`).
struct CatalogModel: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let provider: String
    let description: String
    let contextLength: Int
    let promptPricePer1M: Double
    let completionPricePer1M: Double
    let modalities: Set<String>

    var supportsVision: Bool { modalities.contains("image") }

    var contextLabel: String {
        contextLength >= 1000
            ? String(format: "%.0fk", Double(contextLength) / 1000)
            : "\(contextLength)"
    }
    var priceLabel: String {
        String(format: "$%.2f / $%.2f per 1M", promptPricePer1M, completionPricePer1M)
    }
}

/// Per-provider model catalog. OpenAI-compatible providers fetch `/v1/models`;
/// FoundationModels exposes the on-device model; HuggingFace uses the configured
/// static model list; others have no selectable model. Results are cached per
/// provider id and fall back to a bundled OpenRouter snapshot offline.
@MainActor
final class ModelCatalog: ObservableObject {
    static let shared = ModelCatalog()

    @Published private(set) var models: [CatalogModel] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?

    private var cache: [String: [CatalogModel]] = [:]
    private let cacheDir: URL? = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("macterm")
    }()

    /// Models for a provider (cached, or bundled fallback).
    func models(for config: ProviderConfig) -> [CatalogModel] {
        if let cached = cache[config.id], !cached.isEmpty { return cached }
        return bundledModels(for: config)
    }

    func loadIfNeeded(for config: ProviderConfig) {
        if let cached = loadCache(config) { cache[config.id] = cached }
        Task { await refresh(for: config) }
    }

    func refresh(for config: ProviderConfig) async {
        isLoading = true
        defer { isLoading = false }
        switch config.type {
        case .openrouter, .openAICompatible, .deepseek, .nvidia, .opencodeZen, .opencodeGo, .localLLM, .custom:
            await fetchOpenAICompatible(config)
        case .foundation:
            let list = [CatalogModel(id: "system", name: "Apple on-device Foundation Model",
                                     provider: "apple", description: "On-device model via FoundationModels (private, no network).",
                                     contextLength: 0, promptPricePer1M: 0, completionPricePer1M: 0, modalities: ["text"])]
            cache[config.id] = list
            models = list
        case .huggingface:
            let list = config.staticModels.map {
                CatalogModel(id: $0, name: $0, provider: "huggingface", description: "HuggingFace model.",
                             contextLength: 0, promptPricePer1M: 0, completionPricePer1M: 0, modalities: ["text"])
            }
            cache[config.id] = list
            models = list
        default:
            cache[config.id] = []
            models = []
        }
    }

    private func fetchOpenAICompatible(_ config: ProviderConfig) async {
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/models") else { return }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 20
            req.setValue("macterm", forHTTPHeaderField: "HTTP-Referer")
            if let key = config.apiKey, !key.isEmpty {
                req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            let (data, _) = try await URLSession.shared.data(for: req)
            let parsed = try Self.parse(data)
            guard !parsed.isEmpty else { return }
            cache[config.id] = parsed
            saveCache(parsed, config)
            models = parsed
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: parsing

    private static func parse(_ data: Data) throws -> [CatalogModel] {
        let resp = try JSONDecoder().decode(ORResponse.self, from: data)
        return resp.data.compactMap { m in
            let provider = m.id.contains("/")
                ? String(m.id.split(separator: "/", maxSplits: 1)[0])
                : "other"
            let inputs = m.architecture?.input_modalities ?? []
            let modalities: Set<String> = inputs.isEmpty
                ? Set((m.architecture?.modality ?? "text")
                    .components(separatedBy: "+")
                    .flatMap { $0.components(separatedBy: "->") }
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
                : Set(inputs.map { $0.lowercased() })
            let prompt = (m.pricing?.prompt).flatMap(Double.init) ?? 0
            let completion = (m.pricing?.completion).flatMap(Double.init) ?? 0
            return CatalogModel(
                id: m.id, name: m.name ?? m.id, provider: provider, description: m.description ?? "",
                contextLength: m.context_length ?? 0,
                promptPricePer1M: prompt * 1_000_000, completionPricePer1M: completion * 1_000_000,
                modalities: modalities
            )
        }.sorted { $0.id < $1.id }
    }

    private struct ORResponse: Decodable { let data: [ORModel] }
    private struct ORModel: Decodable {
        let id: String
        let name: String?
        let description: String?
        let context_length: Int?
        let pricing: ORPricing?
        let architecture: ORArchitecture?
    }
    private struct ORPricing: Decodable { let prompt: String?; let completion: String? }
    private struct ORArchitecture: Decodable { let modality: String?; let input_modalities: [String]? }

    // MARK: cache

    private func loadCache(_ config: ProviderConfig) -> [CatalogModel]? {
        guard let url = cacheFile(config),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([CatalogModel].self, from: data),
              !list.isEmpty else { return nil }
        return list
    }
    private func saveCache(_ models: [CatalogModel], _ config: ProviderConfig) {
        guard let url = cacheFile(config) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(models) { try? data.write(to: url) }
    }
    private func cacheFile(_ config: ProviderConfig) -> URL? {
        cacheDir?.appendingPathComponent("models-\(config.id).json")
    }

    private func bundledModels(for config: ProviderConfig) -> [CatalogModel] {
        if config.type == .huggingface {
            return config.staticModels.map {
                CatalogModel(id: $0, name: $0, provider: "huggingface", description: "HuggingFace model.",
                             contextLength: 0, promptPricePer1M: 0, completionPricePer1M: 0, modalities: ["text"])
            }
        }
        return bundled
    }

    /// Small offline snapshot (OpenRouter) so the picker is usable without a network.
    private let bundled: [CatalogModel] = [
        CatalogModel(id: "openai/gpt-4o", name: "OpenAI: GPT-4o", provider: "openai", description: "Flagship multimodal model.", contextLength: 128000, promptPricePer1M: 2.5, completionPricePer1M: 10, modalities: ["text", "image"]),
        CatalogModel(id: "openai/gpt-4o-mini", name: "OpenAI: GPT-4o mini", provider: "openai", description: "Fast, cheap multimodal.", contextLength: 128000, promptPricePer1M: 0.15, completionPricePer1M: 0.6, modalities: ["text", "image"]),
        CatalogModel(id: "anthropic/claude-3.5-sonnet", name: "Anthropic: Claude 3.5 Sonnet", provider: "anthropic", description: "Strong general model.", contextLength: 200000, promptPricePer1M: 3, completionPricePer1M: 15, modalities: ["text", "image"]),
        CatalogModel(id: "anthropic/claude-3.5-haiku", name: "Anthropic: Claude 3.5 Haiku", provider: "anthropic", description: "Fast, inexpensive.", contextLength: 200000, promptPricePer1M: 0.8, completionPricePer1M: 4, modalities: ["text"]),
        CatalogModel(id: "google/gemini-pro-1.5", name: "Google: Gemini Pro 1.5", provider: "google", description: "Long-context multimodal.", contextLength: 1_000_000, promptPricePer1M: 1.25, completionPricePer1M: 5, modalities: ["text", "image"]),
        CatalogModel(id: "meta-llama/llama-3.1-70b-instruct", name: "Meta: Llama 3.1 70B", provider: "meta-llama", description: "Open-weights instruct model.", contextLength: 131072, promptPricePer1M: 0.35, completionPricePer1M: 0.4, modalities: ["text"]),
        CatalogModel(id: "deepseek/deepseek-chat", name: "DeepSeek: Chat", provider: "deepseek", description: "Cost-effective reasoning.", contextLength: 64000, promptPricePer1M: 0.14, completionPricePer1M: 0.28, modalities: ["text"]),
        CatalogModel(id: "mistralai/mistral-large", name: "Mistral: Large", provider: "mistralai", description: "Mistral flagship.", contextLength: 128000, promptPricePer1M: 2, completionPricePer1M: 6, modalities: ["text"]),
        CatalogModel(id: "qwen/qwen-2.5-72b-instruct", name: "Qwen: 2.5 72B", provider: "qwen", description: "Alibaba instruct model.", contextLength: 131072, promptPricePer1M: 0.35, completionPricePer1M: 0.4, modalities: ["text"]),
        CatalogModel(id: "x-ai/grok-2", name: "xAI: Grok-2", provider: "x-ai", description: "Grok-2 chat.", contextLength: 131072, promptPricePer1M: 2, completionPricePer1M: 10, modalities: ["text"]),
        CatalogModel(id: "perplexity/sonar", name: "Perplexity: Sonar", provider: "perplexity", description: "Search-augmented chat.", contextLength: 127072, promptPricePer1M: 1, completionPricePer1M: 1, modalities: ["text"]),
        CatalogModel(id: "openrouter/auto", name: "OpenRouter: Auto", provider: "openrouter", description: "Router picks the best model.", contextLength: 0, promptPricePer1M: 0, completionPricePer1M: 0, modalities: ["text"])
    ]
}
