import SwiftUI
import AppKit

/// Root of the native Settings scene: a modern single-page layout with a
/// prominent sidebar nav on the left and one scrollable content column on the
/// right. Tapping a sidebar item slides the content to that section; a single
/// top search bar filters/searches every setting. Opened by ⌘, or the gear button.
struct SettingsRoot: View {
    @EnvironmentObject private var controller: TerminalController
    @State private var selection: SettingsSection = .general
    @State private var topSearch: String = ""

    /// Curated keywords per section so the global search can match controls that
    /// live inside a section (the section title alone would be too coarse).
    private let sectionKeywords: [SettingsSection: [String]] = [
        .general:      ["shell", "startup", "directory", "close", "exit", "reset", "default", "restore", "login"],
        .theme:        ["theme", "color", "colour", "appearance", "dark", "light", "opacity", "glass", "liquid", "background", "palette", "accent"],
        .textTerminal: ["font", "cursor", "blink", "bold", "bright", "scrollback", "scroll", "mouse", "meta", "option", "backspace", "ansi", "ssh", "padding", "terminal", "text", "size", "connection"],
        .keys:         ["key", "shortcut", "binding", "command", "hotkey", "rebinding"],
        .window:       ["window", "sidebar", "layout", "glass", "material", "background", "opacity", "width", "chrome"],
        .ai:           ["ai", "provider", "model", "openrouter", "openai", "huggingface", "foundation", "agent", "llm", "anthropic", "tool", "skill"],
    ]

    var body: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                sidebar(proxy: proxy)
                    .frame(width: 224)
                content(proxy: proxy)
            }
            .frame(minWidth: 940, minHeight: 640)
            .background(backgroundView)
            .preferredColorScheme(controller.theme.isDark ? .dark : .light)
            // Tags this window so ⌘W interception skips it (native Close stays).
            .background(SettingsWindowMarker())
        }
    }

    // MARK: - Background (theme-following + genuine Liquid Glass material)

    @ViewBuilder private var backgroundView: some View {
        if controller.liquidGlass {
            // Genuine system vibrancy — NSVisualEffectView on macOS 15,
            // glassEffect on macOS 26 (via VisualEffectView helper).
            VisualEffectView(material: .windowBackground, blendingMode: .withinWindow)
        } else {
            Color(nsColor: controller.theme.background)
        }
    }

    // MARK: - Sidebar (ST3: prominent, modern nav)

    private func sidebar(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preferences")
                .font(.headline)
                .foregroundColor(Color(nsColor: controller.foregroundColor))
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 6)
            ForEach(sectionsFor(topSearch)) { section in
                sidebarRow(section, proxy: proxy)
            }
            Spacer(minLength: 0)
        }
        .background(
            controller.liquidGlass
                ? Color.clear
                : Color(nsColor: controller.theme.background).opacity(0.5)
        )
    }

    private func sidebarRow(_ section: SettingsSection, proxy: ScrollViewProxy) -> some View {
        Button {
            selection = section
            withAnimation(.easeInOut(duration: 0.28)) {
                proxy.scrollTo(section, anchor: .top)
            }
        } label: {
            Label(section.title, systemImage: section.icon)
                .font(.system(size: 13, weight: selection == section ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .padding(.horizontal, 14)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selection == section
                              ? Color(nsColor: controller.accentColor).opacity(0.22)
                              : Color.clear)
                )
                .foregroundColor(selection == section
                                 ? Color(nsColor: controller.accentColor)
                                 : Color(nsColor: controller.foregroundColor).opacity(0.85))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
    }

    // MARK: - Content (ST4: single scrollable page; ST6: top search)

    private func content(proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 0) {
            CapsuleSearchField(text: $topSearch, placeholder: "Search all settings")
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    ForEach(sectionsFor(topSearch)) { section in
                        sectionBlock(section)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
            .background(controller.liquidGlass
                        ? Color.clear
                        : Color(nsColor: controller.theme.background))
            .onChange(of: topSearch) { _, _ in
                if let first = sectionsFor(topSearch).first {
                    selection = first
                    withAnimation(.easeInOut(duration: 0.28)) {
                        proxy.scrollTo(first, anchor: .top)
                    }
                }
            }
        }
    }

    /// Sections visible for the current query. Empty query → all; no match → all
    /// (so the user is never stranded on a blank page); otherwise only the
    /// sections whose title or keywords contain the query (ST6: filter).
    private func sectionsFor(_ q: String) -> [SettingsSection] {
        let q = q.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return SettingsSection.allCases }
        let matched = SettingsSection.allCases.filter { sec in
            sec.title.lowercased().contains(q) ||
            (sectionKeywords[sec]?.contains { $0.contains(q) } ?? false)
        }
        return matched.isEmpty ? SettingsSection.allCases : matched
    }

    @ViewBuilder private func sectionBlock(_ section: SettingsSection) -> some View {
        Group {
            switch section {
            case .general:      GeneralSection(query: topSearch)
            case .theme:        ThemeSection(query: topSearch)
            case .textTerminal: TextTerminalSection(query: topSearch)
            case .keys:         KeysSection(query: topSearch)
            case .window:       WindowSection(query: topSearch)
            case .ai:           AIPane()
            }
        }
        .id(section)
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, theme, textTerminal, keys, window, ai
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general:      "General"
        case .theme:        "Theme"
        case .textTerminal: "Text & Terminal"
        case .keys:         "Keys"
        case .window:       "Window & Layout"
        case .ai:           "AI"
        }
    }
    var icon: String {
        switch self {
        case .general:      "gearshape"
        case .theme:        "paintbrush"
        case .textTerminal: "textformat"
        case .keys:         "keyboard"
        case .window:       "macwindow"
        case .ai:           "brain"
        }
    }
}

// MARK: - General

private struct GeneralSection: View {
    @EnvironmentObject private var controller: TerminalController
    let query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("General")
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
        }
    }
}

// MARK: - Theme

/// base16 slots that back `AppTheme.hierarchyColors` (the 6 signature colors),
/// in the same order. Lets us both DISPLAY `hierarchyColors` and EDIT each via
/// `themeColorBinding(_:)` — living theme colors stay two-way bound.
private let hierarchySlots: [Int] = [13, 12, 11, 10, 14, 8]

private struct ThemeSection: View {
    @EnvironmentObject private var controller: TerminalController
    let query: String
    @State private var themeFilter = ""
    @State private var showThemes = false

    private var effectiveQuery: String {
        (themeFilter.isEmpty ? query : themeFilter)
            .trimmingCharacters(in: .whitespaces).lowercased()
    }

    private var filteredThemes: [AppTheme] {
        guard !effectiveQuery.isEmpty else { return AppTheme.all }
        return AppTheme.all.filter { $0.name.lowercased().contains(effectiveQuery)
            || $0.slug.contains(effectiveQuery) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Theme")
            Form {
                // Current theme + its 6 signature colors as live-editable swatches
                // (color adjustment is integrated right here — no separate block).
                Section("Current Theme") {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(controller.theme.name)
                                .font(.headline)
                                .foregroundColor(Color(nsColor: controller.foregroundColor))
                            Text(controller.theme.isDark ? "Dark" : "Light")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        HStack(spacing: 6) {
                            ForEach(0..<6, id: \.self) { i in
                                ColorPicker(selection: controller.themeColorBinding(hierarchySlots[i])) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color(nsColor: controller.theme.hierarchyColors[i]))
                                }
                                .labelsHidden()
                                .frame(width: 24, height: 24)
                            }
                        }
                        Button("Reset colors") { controller.resetThemeColors() }
                            .controlSize(.small)
                    }
                    HStack(spacing: 8) {
                        CapsuleSearchField(text: $themeFilter, placeholder: "Search themes")
                        Spacer()
                        Toggle("Show all themes", isOn: $showThemes)
                    }
                    if showThemes || !themeFilter.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 10) {
                            ForEach(filteredThemes) { theme in
                                ThemeCard(theme: theme,
                                          selected: controller.themeName == theme.slug)
                                    .onTapGesture { controller.themeName = theme.slug }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                // Important settings — kept at the BOTTOM and always visible (ST9).
                Section("Terminal Background") {
                    Slider(value: $controller.backgroundAlpha, in: 0.25...1, step: 0.05) {
                        Text("Terminal background opacity")
                    } minimumValueLabel: {
                        Image(systemName: "circle.lefthalf.filled")
                    } maximumValueLabel: {
                        Image(systemName: "circle.fill")
                    }
                    HStack(spacing: 5) {
                        Text("Transparency of the terminal text surface.")
                        InfoDot(text: "Terminal text background transparency. This is separate from the app window chrome opacity in Window & Layout.")
                    }
                }
                Section("Liquid Glass") {
                    Toggle("Enable Liquid Glass", isOn: $controller.liquidGlass)
                    HStack(spacing: 5) {
                        Text("System vibrancy across the app.")
                        InfoDot(text: "Applies macOS 26 Liquid Glass across the app (vibrancy fallback on older macOS). When off, the flat theme is used.")
                    }
                }
                Section("Preview") {
                    TerminalPreview()
                        .frame(height: 92)
                }
            }
            .formStyle(.grouped)
        }
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

// MARK: - Text & Terminal (ST5: Terminal padding moved here from Window)

private struct TextTerminalSection: View {
    @EnvironmentObject private var controller: TerminalController
    let query: String
    @State private var newName = ""
    @State private var newHost = ""
    @State private var newUser = ""
    @State private var newPort = "22"
    @State private var newIdentity = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Text & Terminal")
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
                Section("Terminal padding") {
                    Stepper(value: $controller.terminalPadding, in: 0...24, step: 1) {
                        Text("Padding: \(Int(controller.terminalPadding)) pt")
                    }
                    HStack(spacing: 5) {
                        Text("Space around the terminal that reveals the window vibrancy.")
                        InfoDot(text: "Inner margin of the terminal panel; the window chrome opacity is set in Window & Layout.")
                    }
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
        }
    }
}

// MARK: - Keys (ST11: alphanumeric filter, conflict prevention, no custom-tab UI)

private struct KeysSection: View {
    @EnvironmentObject private var controller: TerminalController
    let query: String

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
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return cmd.title.lowercased().contains(q)
            || cmd.group.lowercased().contains(q)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Keys")
            Form {
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
        }
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
                    guard !draft.key.isEmpty, !controller.isConflicting(draft) else { return }
                    controller.addCustomBinding(action: actionId,
                                                key: draft.key, modifiers: draft.modifiers)
                    draft.key = ""
                    draft.modifiers = 0
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
                .disabled(draft.key.isEmpty || controller.isConflicting(draft))
                .help(controller.isConflicting(draft) ? "That combo is already used" : "Add this custom binding")
            }
        }
    }
}

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

/// Click-to-arm key capture cell. Accepts any printable ALPHANUMERIC character
/// (or space as a leader key) with any modifier combination; non-alphanumeric
/// Unicode scalars are rejected (ST11a). Esc cancels. A combo that collides with
/// another command is NOT saved and a warning is shown (ST11b).
private struct ShortcutCaptureField: View {
    @EnvironmentObject private var controller: TerminalController
    @Binding var binding: KeyBinding
    let conflicting: Bool
    @State private var listening = false
    @State private var rejected = false
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Button(action: toggleListening) {
                Text(listening ? "Press shortcut…" : Self.describe(binding))
                    .font(.system(.body, design: .monospaced))
                    .frame(minWidth: 110)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.bordered)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke((conflicting && !listening) || rejected ? Color.orange : Color.clear, lineWidth: 1)
            )
            .help("Click, then press the desired key combination (Esc cancels)")
            .onDisappear { stopListening() }
            if rejected {
                Text("Already used — not saved")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func toggleListening() {
        if listening { stopListening() } else { startListening() }
    }

    private func startListening() {
        listening = true
        rejected = false
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { self.stopListening(); return nil }   // Esc cancels
            // Arrow keys arrive as private-use chars; store readable glyphs.
            if let glyph = KeyBinding.arrowGlyphByKeyCode[event.keyCode] {
                var b = binding
                b.key = glyph
                b.modifiers = Int(Self.eventModifiers(event).rawValue)
                if self.controller.isConflicting(b) { self.rejected = true; self.stopListening(); return nil }
                binding = b
                self.rejected = false
                self.stopListening()
                return nil
            }
            // ST11a: keep only alphanumeric scalars (space allowed as leader key).
            guard let chars = event.charactersIgnoringModifiers,
                  let scalar = chars.unicodeScalars.first,
                  scalar == UnicodeScalar(32) || CharacterSet.alphanumerics.contains(scalar)
            else { return event }
            var b = binding
            b.key = scalar == UnicodeScalar(32) ? " " : String(scalar).lowercased()
            b.modifiers = Int(Self.eventModifiers(event).rawValue)
            // ST11b: refuse to save a combo claimed by another command.
            if self.controller.isConflicting(b) { self.rejected = true; self.stopListening(); return nil }
            binding = b
            self.rejected = false
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

// MARK: - Window & Layout (ST12: clearer name, two opacities clarified)

private struct WindowSection: View {
    @EnvironmentObject private var controller: TerminalController
    let query: String

    private var sidebarVisible: Binding<Bool> {
        Binding(get: { !controller.sidebarCollapsed },
                set: { controller.sidebarCollapsed = !$0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Window & Layout")
            Form {
                Section("Sidebar") {
                    Toggle("Show sidebar on launch", isOn: sidebarVisible)
                    Stepper(value: $controller.sidebarWidth, in: 200...360, step: 10) {
                        Text("Width: \(Int(controller.sidebarWidth)) pt")
                    }
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
                    HStack(spacing: 5) {
                        Text("Tints the window behind the terminal glass.")
                        InfoDot(text: "Match Sidebar blends with the file tree; Under Window is the most translucent over your wallpaper.")
                    }
                    Slider(value: $controller.windowBackgroundOpacity, in: 0...1, step: 0.05) {
                        Text("Window chrome opacity")
                    } minimumValueLabel: {
                        Image(systemName: "circle.lefthalf.filled")
                    } maximumValueLabel: {
                        Image(systemName: "circle.fill")
                    }
                    HStack(spacing: 5) {
                        Text("Higher = more opaque window; lower = more of your desktop shows through.")
                        InfoDot(text: "This is the app window frame opacity — distinct from the terminal's own background transparency (set in Theme).")
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}

// MARK: - AI (ST13)

/// AI provider / model / tools surface. Driven entirely by `ProviderRegistry`:
/// built-in and user-added providers, each with its own key (Keychain), base URL,
/// model and parameters. Switching providers rebuilds the live `AgentProvider`.
private struct AIPane: View {
    @EnvironmentObject private var controller: TerminalController
    @ObservedObject private var registry = ProviderRegistry.shared
    @State private var showingAdd = false

    private var selectionBinding: Binding<String> {
        Binding(get: { registry.selectedId },
                set: { registry.select($0); controller.agenticSystem.reloadProvider() })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("AI")
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GroupBox("Providers") {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("Active provider", selection: selectionBinding) {
                                ForEach(registry.providers) { cfg in
                                    Text(cfg.name).tag(cfg.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 340)
                            Button(action: { showingAdd = true }) {
                                Label("Add provider", systemImage: "plus")
                            }
                            .buttonStyle(.borderedProminent)
                            .help("Add a new AI provider")
                        }
                    }

                    if let idx = registry.providers.firstIndex(where: { $0.id == registry.selectedId }) {
                        ProviderConfigEditor(registry: registry, config: $registry.providers[idx])
                    }

                    GroupBox("All providers") {
                        VStack(spacing: 4) {
                            ForEach(registry.providers) { cfg in
                                ProviderCard(registry: registry, config: cfg) {
                                    registry.remove(cfg)
                                    controller.agenticSystem.reloadProvider()
                                }
                            }
                        }
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
}

private struct ProviderCard: View {
    @ObservedObject var registry: ProviderRegistry
    let config: ProviderConfig
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
                // No separate OpenRouter panel — model selection is consolidated here.
                if config.type != .mock && config.type != .omp && config.type != .foundation {
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
                // ST13: keep Mock, Apple on-device (foundation) and OMP out of the picker.
                ForEach(ProviderType.allCases.filter { $0 != .mock && $0 != .foundation && $0 != .omp }) { t in
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
    @State private var freeOnly = false

    private var models: [CatalogModel] { catalog.models(for: config) }

    private var filtered: [CatalogModel] {
        models.filter { m in
            (search.isEmpty ||
             m.name.localizedCaseInsensitiveContains(search) ||
             m.id.localizedCaseInsensitiveContains(search)) &&
            (!freeOnly || (m.promptPricePer1M == 0 && m.completionPricePer1M == 0))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search models", text: $search).textFieldStyle(.roundedBorder)
                Toggle("Free only", isOn: $freeOnly)
                    .help("Show only models with no per-token price")
            }
            if catalog.isLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading models…").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Button(action: { Task { await catalog.refresh(for: config) } }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain).help("Refresh model list")
            }
            List(selection: $config.selectedModel) {
                ForEach(filtered) { model in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(model.name).font(.system(size: 12, weight: .medium))
                                if model.supportsVision {
                                    Image(systemName: "eye.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                if model.promptPricePer1M == 0 && model.completionPricePer1M == 0 {
                                    Text("Free").font(.caption).foregroundStyle(.green)
                                } else {
                                    Text(model.priceLabel).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                                }
                            }
                            Text(model.id).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .tag(model.id)
                }
            }
            .frame(maxHeight: 260)
            .listStyle(.inset)
            .background(Color.primary.opacity(0.03))
            .cornerRadius(8)
            Text("Selected: \(config.selectedModel.isEmpty ? "(default)" : config.selectedModel).")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { catalog.loadIfNeeded(for: config) }
    }
}

// MARK: - Shared helpers

private func sectionTitle(_ title: String) -> some View {
    Text(title)
        .font(.title2.weight(.semibold))
}
