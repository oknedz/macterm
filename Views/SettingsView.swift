import SwiftUI
import AppKit

/// Root of the native Settings scene — an Xcode-style `NavigationSplitView`
/// with a category sidebar and a detail pane. Opened by ⌘, or the gear button.
struct SettingsRoot: View {
    @EnvironmentObject private var controller: TerminalController
    @State private var selection: SettingsSection = .appearance

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SettingsSection.allCases) { section in
                    Label(section.title, systemImage: section.icon)
                        .tag(section)
                }
            }
            // Fixed-width category list, no collapsible-sidebar chrome —
            // its toggle icon used to collide with the traffic lights.
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 230)
        } detail: {
            Group {
                switch selection {
                case .general:    GeneralPane()
                case .appearance: AppearancePane()
                case .text:       TextPane()
                case .terminal:   TerminalPane()
                case .keys:       ShortcutsPane()
                case .window:     WindowPane()
                case .ai:       AIPane()
                }
            }
            .navigationTitle(selection.title)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationSplitViewStyle(.balanced)
        // Roomy on purpose: the Keys pane lists every command grouped.
        .frame(minWidth: 940, minHeight: 640)
        .background {
            if controller.liquidGlass {
                VisualEffectView(material: .windowBackground, blendingMode: .withinWindow)
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
        }
        // Tags this window so ⌘W interception skips it (native Close stays).
        .background(SettingsWindowMarker())
        // The Settings window follows the app theme too (dark/light materials + controls).
        .preferredColorScheme(controller.theme.isDark ? .dark : .light)
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, appearance, text, terminal, keys, window, ai
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general:    "General"
        case .appearance: "Theme"
        case .text:       "Text"
        case .terminal:   "Terminal"
        case .keys:       "Keys"
        case .window:     "Window"
        case .ai:        "AI"
        }
    }
    var icon: String {
        switch self {
        case .general:    "gearshape"
        case .appearance: "paintbrush"
        case .text:       "textformat"
        case .terminal:   "terminal"
        case .keys:       "keyboard"
        case .window:     "macwindow"
        case .ai:        "brain"
        }
    }
}

// MARK: - General
private struct GeneralPane: View {
    @EnvironmentObject private var controller: TerminalController
    var body: some View {
        Form {
            Section {
                Text("App-wide defaults: which shell runs in new tabs, where tabs open, and a master reset for every setting.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Shell") {
                TextField("Executable path", text: $controller.shellPath)
                    .textFieldStyle(.roundedBorder)
                Text("Default login shell is used if the path is invalid.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Startup") {
                Picker("New tab opens in", selection: $controller.startupDirRaw) {
                    ForEach(TerminalController.startupDirOptions, id: \.raw) { Text($0.label).tag($0.raw) }
                }
                .pickerStyle(.segmented)
                Toggle("Close tab when the shell exits", isOn: $controller.closeOnExit)
            }
            Section("Reset") {
                Button("Restore All Defaults", role: .destructive) {
                    controller.resetAllSettings()
                }
                Text("Restores every setting — theme, text, terminal, keys, window.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

// MARK: - Theme
private struct AppearancePane: View {
    @EnvironmentObject private var controller: TerminalController
    @State private var filter = ""

    private var filtered: [AppTheme] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return AppTheme.all }
        return AppTheme.all.filter { $0.name.lowercased().contains(q) || $0.slug.contains(q) }
    }

    var body: some View {
        Form {
            Section("Current Theme") {
                HStack(spacing: 10) {
                    Text(controller.theme.name)
                        .font(.headline)
                    Spacer()
                    HStack(spacing: 3) {
                        ForEach(0..<16, id: \.self) { slot in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(nsColor: controller.theme.ansiSwatchColors[slot]))
                                .aspectRatio(1, contentMode: .fit)
                        }
                    }
                    .frame(width: 140)
                }
            }
            Section {
                PillSearchField(placeholder: "Search Theme", text: $filter)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 10) {
                    ForEach(filtered) { theme in
                        ThemeCard(theme: theme, selected: controller.themeName == theme.slug)
                            .onTapGesture { controller.themeName = theme.slug }
                    }
                }
                .padding(.vertical, 4)
            }

            // Kept from the old Appearance pane — drives the frosted-glass
            // look of the terminal over the window vibrancy.
            Section("Opacity") {
                Slider(value: $controller.backgroundAlpha, in: 0.25...1, step: 0.05) {
                    Text("Background opacity")
                } minimumValueLabel: {
                    Image(systemName: "circle.lefthalf.filled")
                } maximumValueLabel: {
                    Image(systemName: "circle.fill")
                }
            }
            Section("Liquid Glass") {
                Toggle("Enable Liquid Glass", isOn: $controller.liquidGlass)
                Text("Applies macOS 26 Liquid Glass across the app (vibrancy fallback on older macOS). When off, the flat theme is used.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Preview") {
                TerminalPreview()
                    .frame(height: 92)
            }
            Section("Theme Colors") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84))], spacing: 8) {
                    ForEach(0..<16, id: \.self) { slot in
                        ColorPicker(selection: controller.themeColorBinding(slot)) {
                            Text(verbatim: String(format: "0x%X", slot))
                        }
                        .labelsHidden()
                    }
                }
                Button("Reset theme colors") { controller.resetThemeColors() }
                    .controlSize(.small)
                Text("Tap a swatch to edit that ANSI color — changes apply live across the terminal, tree and preview. Reset restores the theme's defaults.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

/// One theme card: the theme's own background plus a strip of the ANSI colors
/// the terminal will actually use (bright slots carry each theme's identity).
private struct ThemeCard: View {
    let theme: AppTheme
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(theme.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color(nsColor: theme.foreground))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            HStack(spacing: 3) {
                ForEach(8..<14, id: \.self) { slot in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(nsColor: theme.ansiSwatchColors[slot]))
                        .aspectRatio(1, contentMode: .fit)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: theme.background))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(selected ? Color(nsColor: theme.accent) : Color.primary.opacity(0.15),
                        lineWidth: selected ? 2 : 1)
        )
        .contentShape(Rectangle())
    }
}

/// Live sample rendered with the active theme's palette — updates instantly
/// with every theme/font change.
private struct TerminalPreview: View {
    @EnvironmentObject private var controller: TerminalController

    /// One ANSI-colored token run (slot = xterm color index).
    private func tok(_ text: String, _ slot: Int) -> Text {
        Text(text).foregroundColor(Color(nsColor: controller.theme.ansiSwatchColors[slot]))
    }

    var body: some View {
        let fg = Color(nsColor: controller.foregroundColor)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 0) {
                tok("~ ", 12)
                tok("❯ ", 11)
                Text("git status").foregroundColor(fg)
            }
            HStack(spacing: 0) {
                Text("On branch ").foregroundColor(fg)
                tok("main", 3)
                Text(", working tree ").foregroundColor(fg)
                tok("clean", 2)
            }
            HStack(spacing: 0) {
                tok("✓ ", 10)
                Text("themed by ").foregroundColor(fg)
                tok("NvChad/base46", 4)
                Text(" — ").foregroundColor(fg)
                tok(controller.theme.name, 5)
            }
        }
        .font(Font.custom(controller.fontName, size: 13))
        .lineLimit(1)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: controller.theme.background)))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
    }
}

// MARK: - Text
private struct TextPane: View {
    @EnvironmentObject private var controller: TerminalController
    var body: some View {
        Form {
            Section("Font") {
                Picker("Family", selection: $controller.fontName) {
                    ForEach(TerminalController.fontChoices, id: \.self) { Text($0) }
                }
                .pickerStyle(.menu)
                Stepper(value: $controller.fontSize, in: 10...22, step: 1) {
                    Text("Size: \(Int(controller.fontSize)) pt")
                }
            }
            Section("Cursor") {
                Picker("Shape", selection: $controller.cursorShapeRaw) {
                    ForEach(TerminalController.cursorShapes, id: \.raw) { Text($0.label).tag($0.raw) }
                }
                .pickerStyle(.segmented)
                Toggle("Blink", isOn: $controller.cursorBlink)
            }
            Section("Rendering") {
                Toggle("Use bright colors for bold text", isOn: $controller.useBrightColors)
            }
            Section("Preview") {
                Text("The quick brown fox — 0 O o 1 l I | ` ~")
                    .font(Font.custom(controller.fontName, size: controller.fontSize))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: controller.backgroundColor))
                    .foregroundColor(Color(nsColor: controller.foregroundColor))
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

// MARK: - Terminal
private struct TerminalPane: View {
    @EnvironmentObject private var controller: TerminalController
    @State private var newName = ""
    @State private var newHost = ""
    @State private var newUser = ""
    @State private var newPort = "22"
    @State private var newIdentity = ""
    var body: some View {
        Form {
            Section("Scrollback") {
                Stepper(value: $controller.scrollback, in: 500...200000, step: 500) {
                    Text("\(Int(controller.scrollback)) lines")
                }
                Text("Buffer retained per terminal for scroll-up and search.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Input") {
                Toggle(isOn: $controller.optionAsMetaKey) {
                    HStack(spacing: 5) {
                        Text("Option key acts as Meta (ESC)")
                        InfoDot(text: "Sends ESC + key for ⌥ combos — required by emacs and other TUIs. Off treats ⌥ as a normal character.")
                    }
                }
                Toggle(isOn: $controller.allowMouseReporting) {
                    HStack(spacing: 5) {
                        Text("Allow mouse reporting")
                        InfoDot(text: "Lets TUIs (htop, less) capture clicks, drags and scroll instead of the terminal.")
                    }
                }
                Toggle(isOn: $controller.backspaceSendsControlH) {
                    HStack(spacing: 5) {
                        Text("Backspace sends Ctrl-H")
                        InfoDot(text: "Emulate the historical Backspace = ^H. Needed by some old shells and editors.")
                    }
                }
            }
            Section("Color mapping") {
                Picker("ANSI 256 strategy", selection: $controller.ansi256Raw) {
                    ForEach(TerminalController.ansi256Options, id: \.raw) { Text($0.label).tag($0.raw) }
                }
                .pickerStyle(.segmented)
            }
            Section("SSH Connections") {
                if controller.sshConnections.isEmpty {
                    Text("No saved connections.").foregroundStyle(.secondary)
                } else {
                    ForEach(controller.sshConnections) { c in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.name.isEmpty ? c.host : c.name).font(.headline)
                                Text("\(c.user)@\(c.host):\(c.port)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Connect") { controller.connectSSH(c) }
                            Button(action: { controller.removeSSHConnection(c.id) }) {
                                Image(systemName: "trash").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Add connection").font(.subheadline.weight(.medium))
                    TextField("Name (optional)", text: $newName).textFieldStyle(.roundedBorder)
                    TextField("Host", text: $newHost).textFieldStyle(.roundedBorder)
                    TextField("User", text: $newUser).textFieldStyle(.roundedBorder)
                    TextField("Port", text: $newPort).textFieldStyle(.roundedBorder)
                    TextField("Identity file (optional)", text: $newIdentity).textFieldStyle(.roundedBorder)
                    Button("Save") {
                        guard !newHost.isEmpty, !newUser.isEmpty,
                              let port = Int(newPort), port > 0, port <= 65535 else { return }
                        controller.addSSHConnection(SSHConnection(id: UUID(), name: newName, host: newHost, user: newUser, port: port, identityFile: newIdentity.isEmpty ? nil : newIdentity))
                        newName = ""; newHost = ""; newUser = ""; newPort = "22"; newIdentity = ""
                    }
                    .disabled(newHost.isEmpty || newUser.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

// MARK: - Window
private struct WindowPane: View {
    @EnvironmentObject private var controller: TerminalController

    private var sidebarVisible: Binding<Bool> {
        Binding(get: { !controller.sidebarCollapsed },
                set: { controller.sidebarCollapsed = !$0 })
    }

    var body: some View {
        Form {
            Section("Sidebar") {
                Toggle("Show sidebar on launch", isOn: sidebarVisible)
                Stepper(value: $controller.sidebarWidth, in: 200...360, step: 10) {
                    Text("Width: \(Int(controller.sidebarWidth)) pt")
                }
            }
            Section("Terminal") {
                Stepper(value: $controller.terminalPadding, in: 0...24, step: 1) {
                    Text("Padding: \(Int(controller.terminalPadding)) pt")
                }
                Text("Space around the terminal that reveals the window vibrancy.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Glass transparency is set in Theme → Opacity.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("App Background") {
                Picker("Glass material", selection: $controller.windowMaterialRaw) {
                    Text("Match Sidebar").tag(String(NSVisualEffectView.Material.sidebar.rawValue))
                    Text("Match Titlebar").tag(String(NSVisualEffectView.Material.titlebar.rawValue))
                    Text("Solid Window").tag(String(NSVisualEffectView.Material.windowBackground.rawValue))
                    Text("Floating (Popover)").tag(String(NSVisualEffectView.Material.popover.rawValue))
                    Text("Header Strip").tag(String(NSVisualEffectView.Material.headerView.rawValue))
                    Text("Content Area").tag(String(NSVisualEffectView.Material.contentBackground.rawValue))
                    Text("Translucent (Under Window)").tag(String(NSVisualEffectView.Material.underWindowBackground.rawValue))
                }
                .pickerStyle(.menu)
                Text("Tints the window behind the terminal glass. Match Sidebar blends with the file tree; Under Window is the most translucent over your wallpaper.")
                    .font(.caption).foregroundStyle(.secondary)
                Slider(value: $controller.windowBackgroundOpacity, in: 0...1, step: 0.05) {
                    Text("Window background opacity")
                } minimumValueLabel: {
                    Image(systemName: "circle.lefthalf.filled")
                } maximumValueLabel: {
                    Image(systemName: "circle.fill")
                }
                Text("Higher = more opaque window; lower = more of your desktop shows through.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}


/// AI provider / model / tools surface. Driven entirely by `ProviderRegistry`:
/// built-in and user-added providers, each with its own key (Keychain), base URL,
/// model and parameters. Switching providers rebuilds the live `AgentProvider`.
private struct AIPane: View {
    @EnvironmentObject private var controller: TerminalController
    @ObservedObject private var registry = ProviderRegistry.shared
    @State private var showingAdd = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox("Providers") {
                    VStack(spacing: 4) {
                        ForEach(Array(registry.providers.enumerated()), id: \.element.id) { _, cfg in
                            ProviderCard(registry: registry, config: cfg) {
                                registry.select(cfg.id)
                                controller.agenticSystem.reloadProvider()
                            } onDelete: {
                                registry.remove(cfg)
                                controller.agenticSystem.reloadProvider()
                            }
                        }
                        Button(action: { showingAdd = true }) {
                            Label("Add provider", systemImage: "plus")
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 2)
                    }
                }

                if let idx = registry.providers.firstIndex(where: { $0.id == registry.selectedId }) {
                    ProviderConfigEditor(registry: registry, config: $registry.providers[idx])
                }

                GroupBox("Tools & Skills") {
                    let tools = controller.agenticSystem.availableTools
                    if tools.isEmpty {
                        Text("No tools registered.").foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(tools, id: \.name) { tool in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(tool.name)
                                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        Text(tool.description)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.primary.opacity(0.05))
                                    .cornerRadius(8)
                                }
                            }
                            .padding(4)
                        }
                        .frame(maxHeight: 220)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: registry.providers) { _, _ in registry.save() }
        .sheet(isPresented: $showingAdd) { AddProviderSheet(registry: registry) }
    }
}

private struct ProviderCard: View {
    @ObservedObject var registry: ProviderRegistry
    let config: ProviderConfig
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: registry.selectedId == config.id ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(registry.selectedId == config.id ? .blue : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(config.name).font(.system(size: 13, weight: .medium))
                Text(config.type.label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if config.type.needsKey {
                Image(systemName: (config.apiKey == nil) ? "key.slash" : "key.fill")
                    .foregroundStyle((config.apiKey == nil) ? .secondary : Color.green)
                    .help(config.apiKey == nil ? "No API key" : "API key set")
            }
            if !config.isBuiltIn {
                Button(action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.plain).help("Delete provider")
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

private struct ProviderConfigEditor: View {
    @ObservedObject var registry: ProviderRegistry
    @Binding var config: ProviderConfig
    @State private var keyInput: String = ""

    var body: some View {
        GroupBox("\(config.name) settings") {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Name") {
                    TextField("Name", text: $config.name).textFieldStyle(.roundedBorder).frame(width: 280)
                }
                if config.type.needsBaseURL {
                    LabeledContent("Base URL") {
                        TextField("Base URL", text: $config.baseURL).textFieldStyle(.roundedBorder).frame(width: 380)
                    }
                }
                if config.type.needsKey {
                    LabeledContent("API key") {
                        SecureField("API key", text: $keyInput)
                            .textFieldStyle(.roundedBorder).frame(width: 380)
                            .onChange(of: keyInput) { _, new in KeychainStore.set(new, for: config.keychainKey) }
                    }
                    if config.apiKey == nil {
                        Text("No API key set — provider calls will fail.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("API key is set.").font(.caption).foregroundStyle(Color.green)
                    }
                }
                LabeledContent("Temperature") {
                    Slider(value: $config.temperature, in: 0...2, step: 0.05).frame(width: 240)
                    Text(String(format: "%.2f", config.temperature)).font(.system(size: 11, design: .monospaced))
                }
                LabeledContent("Max tokens") {
                    Stepper("\(config.maxTokens)", value: $config.maxTokens, in: 128...32768, step: 128)
                }
                if config.type != .mock && config.type != .omp {
                    ModelPicker(config: $config)
                }
                statusText
            }
            .padding(4)
        }
        .onAppear { keyInput = config.apiKey ?? "" }
    }

    @ViewBuilder private var statusText: some View {
        switch config.type {
        case .foundation:
            Text("Apple on-device model. Requires macOS 26. Private — no network or key.")
                .font(.caption).foregroundStyle(.secondary)
        case .openAICompatible:
            Text("OpenAI-compatible endpoint (Ollama, LM Studio, vLLM, TGI). For local models leave the key empty.")
                .font(.caption).foregroundStyle(.secondary)
        case .huggingface:
            Text("HuggingFace Inference API. Uses the configured model id.")
                .font(.caption).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }
}

private struct AddProviderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var registry: ProviderRegistry
    @State private var name = ""
    @State private var type: ProviderType = .openAICompatible
    @State private var baseURL = ""
    @State private var model = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add provider").font(.headline)
            LabeledContent("Name") {
                TextField("Name", text: $name).textFieldStyle(.roundedBorder).frame(width: 300)
            }
            Picker("Type", selection: $type) {
                ForEach(ProviderType.allCases.filter { $0 != .mock && $0 != .omp }) { t in
                    Text(t.label).tag(t)
                }
            }
            .pickerStyle(.menu)
            if type.needsBaseURL {
                LabeledContent("Base URL") {
                    TextField("Base URL", text: $baseURL).textFieldStyle(.roundedBorder).frame(width: 400)
                }
            }
            if type == .huggingface {
                LabeledContent("Model") {
                    TextField("e.g. meta-llama/Llama-3.1-8B-Instruct", text: $model)
                        .textFieldStyle(.roundedBorder).frame(width: 400)
                }
            }
            HStack {
                Button("Cancel", action: { dismiss() })
                Spacer()
                Button("Add") { add() }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 470)
    }

    private func add() {
        let id = UUID().uuidString
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty {
            switch type {
            case .openAICompatible: base = "http://localhost:11434/v1"
            case .huggingface: base = "https://api-inference.huggingface.co"
            default: break
            }
        }
        let m = model.trimmingCharacters(in: .whitespaces)
        let cfg = ProviderConfig(
            id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), type: type,
            baseURL: base, keychainKey: type.needsKey ? "provider.\(id)" : "",
            staticModels: type == .huggingface ? [m] : [],
            selectedModel: type == .huggingface ? m : ""
        )
        registry.add(cfg)
        registry.select(id)
        dismiss()
    }
}

private struct ModelPicker: View {
    @ObservedObject private var catalog = ModelCatalog.shared
    @Binding var config: ProviderConfig
    @State private var search = ""
    @State private var providerFilter: String = "All"
    @State private var sort: SortKey = .name

    private enum SortKey: String, CaseIterable, Identifiable {
        case name, context, price
        var id: String { rawValue }
        var label: String {
            switch self {
            case .name: return "Name"
            case .context: return "Context"
            case .price: return "Price"
            }
        }
    }

    private var models: [CatalogModel] { catalog.models(for: config) }

    private var providers: [String] { ["All"] + Set(models.map { $0.provider }).sorted() }

    private var filtered: [CatalogModel] {
        models.filter { m in
            (providerFilter == "All" || m.provider == providerFilter) &&
            (search.isEmpty ||
             m.id.localizedCaseInsensitiveContains(search) ||
             m.name.localizedCaseInsensitiveContains(search))
        }.sorted {
            switch sort {
            case .name: return $0.id < $1.id
            case .context: return $0.contextLength > $1.contextLength
            case .price: return $0.promptPricePer1M < $1.promptPricePer1M
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search models", text: $search).textFieldStyle(.roundedBorder)
                if catalog.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button(action: { Task { await catalog.refresh(for: config) } }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain).help("Refresh model list")
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(providers, id: \.self) { p in
                        FilterChip(title: p, selected: providerFilter == p) { providerFilter = p }
                    }
                }
                .padding(.vertical, 2)
            }
            Picker("Sort", selection: $sort) {
                ForEach(SortKey.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(filtered) { model in
                        Button(action: { config.selectedModel = model.id }) {
                            HStack(spacing: 8) {
                                Image(systemName: config.selectedModel == model.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(config.selectedModel == model.id ? .blue : .secondary)
                                VStack(alignment: .leading) {
                                    HStack {
                                        Text(model.name).font(.system(size: 12, weight: .medium))
                                        if model.supportsVision {
                                            Image(systemName: "eye.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                        Text(model.contextLabel).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                                    }
                                    Text(model.id).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(8)
                            .background(config.selectedModel == model.id ? Color.blue.opacity(0.12) : Color.primary.opacity(0.05))
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
            }
            .frame(maxHeight: 260)
            .background(Color.primary.opacity(0.03))
            .cornerRadius(8)
            Text("Selected: \(config.selectedModel.isEmpty ? "(default)" : config.selectedModel).")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { catalog.loadIfNeeded(for: config) }
    }
}

private struct FilterChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 11))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(selected ? Color.blue.opacity(0.18) : Color.primary.opacity(0.08))
                .foregroundStyle(selected ? .blue : .primary)
                .cornerRadius(20)
        }
        .buttonStyle(.plain)
    }
}
// MARK: - Keys

/// Every app command, NvChad-grouped and filterable by name or group.
/// Each row rebinds live and can be reset to its catalog default.
private struct ShortcutsPane: View {
    @EnvironmentObject private var controller: TerminalController
    @State private var search = ""

    /// Commands whose combo is claimed by another command too.
    private var conflictingIDs: Set<String> {
        var counts: [String: Int] = [:]
        for b in controller.keyBindings where !b.key.isEmpty {
            counts[b.key + "|\(b.modifiers)", default: 0] += 1
        }
        return Set(controller.keyBindings.compactMap { b in
            !b.key.isEmpty && counts[b.key + "|\(b.modifiers)", default: 0] > 1 ? b.id : nil
        })
    }

    private func matches(_ cmd: CommandSpec) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return cmd.title.lowercased().contains(q)
            || cmd.group.lowercased().contains(q)
    }

    var body: some View {
        Form {
            Section("Search") {
                PillSearchField(placeholder: "Search shortcuts", text: $search)
                Text("Click a key cell, press the new combination; Esc cancels. Duplicates are flagged.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(TerminalController.commandGroups, id: \.group) { g in
                let cmds = g.commands.filter(matches)
                if !cmds.isEmpty {
                    Section(g.group) {
                        ForEach(cmds) { cmd in
                            if let i = controller.keyBindings.firstIndex(where: { $0.id == cmd.id }) {
                                ShortcutRow(spec: cmd,
                                            conflicting: conflictingIDs.contains(cmd.id),
                                            binding: $controller.keyBindings[i])
                            }
                        }
                    }
                }
            }
            Section("Custom") {
                if controller.customBindings.isEmpty {
                    Text("No custom bindings yet. Add extra combos for any command — space works as a leader key.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(controller.customBindings) { b in
                    CustomBindingRow(binding: binding(for: b))
                }
                AddCustomBindingRow()
            }
            Section("Reset") {
                Button("Reset All Shortcuts") { controller.resetKeyBindings() }
                    .controlSize(.small)
                Text("Reset restores built-ins; your custom bindings are kept.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }

    private func binding(for b: KeyBinding) -> Binding<KeyBinding> {
        let id = b.id
        return Binding(
            get: { controller.keyBindings.first { $0.id == id } ?? b },
            set: { newValue in
                if let i = controller.keyBindings.firstIndex(where: { $0.id == id }) {
                    controller.keyBindings[i] = newValue
                }
            }
        )
    }

    /// Editable row for one user-defined combo.
    private struct CustomBindingRow: View {
        @EnvironmentObject private var controller: TerminalController
        @Binding var binding: KeyBinding

        var body: some View {
            HStack(spacing: 10) {
                Text(controller.title(for: binding))
                Spacer(minLength: 8)
                if controller.isConflicting(binding) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("Another command uses this combination")
                }
                ShortcutCaptureField(binding: $binding,
                                     conflicting: controller.isConflicting(binding))
                Button(role: .destructive) {
                    controller.removeCustomBinding(binding.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Remove this custom binding")
            }
        }
    }

    /// "+" row that appends a new user-defined combo for any built-in command.
    private struct AddCustomBindingRow: View {
        @EnvironmentObject private var controller: TerminalController
        @State private var actionId = TerminalController.commandCatalog.first?.id ?? ""
        @State private var draft = KeyBinding(id: "custom.draft", key: "", modifiers: 0)

        var body: some View {
            HStack(spacing: 10) {
                Picker("Command", selection: $actionId) {
                    ForEach(TerminalController.commandCatalog) { cmd in
                        Text("\(cmd.group) — \(cmd.title)").tag(cmd.id)
                    }
                }
                .labelsHidden()
                Spacer(minLength: 8)
                ShortcutCaptureField(binding: $draft, conflicting: false)
                Button {
                    guard !draft.key.isEmpty else { return }
                    controller.addCustomBinding(action: actionId,
                                                key: draft.key, modifiers: draft.modifiers)
                    draft.key = ""
                    draft.modifiers = 0
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
                .disabled(draft.key.isEmpty)
                .help("Add this custom binding")
            }
        }
    }

    private var filteredGroupsEmpty: Bool {
        TerminalController.commandGroups.allSatisfy { g in
            g.commands.filter(matches).isEmpty
        }
    }
}

/// One command row: title, a capture cell, duplicate warning, and a
/// one-click reset to the catalog default.
private struct ShortcutRow: View {
    let spec: CommandSpec
    let conflicting: Bool
    @Binding var binding: KeyBinding

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(spec.title)
            }
            Spacer(minLength: 8)
            if conflicting {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Another command uses this combination")
            }
            ShortcutCaptureField(binding: $binding, conflicting: conflicting)
            Button {
                binding = TerminalController.defaultBinding(for: spec.id)
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Reset to default")
        }
        .padding(.vertical, 1)
    }
}

/// Click-to-arm key capture cell. Accepts any printable character with any
/// modifier combination; Esc cancels without changing the binding.
private struct ShortcutCaptureField: View {
    @Binding var binding: KeyBinding
    let conflicting: Bool
    @State private var listening = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: toggleListening) {
            Text(listening ? "Press shortcut…" : Self.describe(binding))
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 110)
                .padding(.vertical, 2)
        }
        .buttonStyle(.bordered)
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(conflicting && !listening ? Color.orange : Color.clear, lineWidth: 1)
        )
        .help("Click, then press the desired key combination (Esc cancels)")
        .onDisappear { stopListening() }
    }

    private func toggleListening() {
        if listening { stopListening() } else { startListening() }
    }

    private func startListening() {
        listening = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { self.stopListening(); return nil }   // Esc cancels
            // Accept any printable character INCLUDING space (leader key);
            // ignore pure-modifier presses.
            // Arrow keys arrive as private-use chars; store readable glyphs.
            if let glyph = KeyBinding.arrowGlyphByKeyCode[event.keyCode] {
                var b = binding
                b.key = glyph
                b.modifiers = Int(Self.eventModifiers(event).rawValue)
                binding = b
                self.stopListening()
                return nil
            }
            guard let chars = event.charactersIgnoringModifiers,
                  let first = chars.first,
                  first == " " || !first.isWhitespace else { return event }
            var b = binding
            b.key = first == " " ? " " : String(first).lowercased()
            b.modifiers = Int(Self.eventModifiers(event).rawValue)
            binding = b
            self.stopListening()
            return nil
        }
    }

    private func stopListening() {
        listening = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    private static func eventModifiers(_ event: NSEvent) -> EventModifiers {
        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var m: EventModifiers = []
        if f.contains(.command) { m.insert(.command) }
        if f.contains(.shift)   { m.insert(.shift) }
        if f.contains(.option)  { m.insert(.option) }
        if f.contains(.control) { m.insert(.control) }
        return m
    }

    static func describe(_ b: KeyBinding) -> String {
        guard !b.key.isEmpty else { return "Unassigned" }
        let m = EventModifiers(rawValue: b.modifiers)
        var s = ""
        if m.contains(.command) { s += "⌘" }
        if m.contains(.shift)   { s += "⇧" }
        if m.contains(.option)  { s += "⌥" }
        if m.contains(.control) { s += "⌃" }
        switch b.key {
        case " ": return s + "␣"                       // space / leader key
        default:
            let k = b.key
            return s + (k.count == 1 && k.first!.isLetter ? k.uppercased() : k)
        }
    }
}
