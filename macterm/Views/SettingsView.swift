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
                }
            }
            .navigationTitle(selection.title)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationSplitViewStyle(.balanced)
        // Roomy on purpose: the Keys pane lists every command grouped.
        .frame(minWidth: 940, minHeight: 640)
        .background(VisualEffectView(material: .windowBackground, blendingMode: .withinWindow))
        // The Settings window follows the app theme too (dark/light materials + controls).
        .preferredColorScheme(controller.theme.isDark ? .dark : .light)
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, appearance, text, terminal, keys, window
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general:    "General"
        case .appearance: "Theme"
        case .text:       "Text"
        case .terminal:   "Terminal"
        case .keys:       "Keys"
        case .window:     "Window"
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
        }
    }
}

// MARK: - General
private struct GeneralPane: View {
    @EnvironmentObject private var controller: TerminalController
    var body: some View {
        Form {
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
            Section {
                TextField("Filter \(AppTheme.all.count) themes…", text: $filter)
                    .textFieldStyle(.roundedBorder)
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

            Section("Preview") {
                TerminalPreview()
                    .frame(height: 92)
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
                Circle()
                    .fill(Color(nsColor: theme.background))
                    .frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
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
            tok("~ ", 12) + tok("❯ ", 11) + Text("git status").foregroundColor(fg)
            Text("On branch ").foregroundColor(fg)
                + tok("main", 3)
                + Text(", working tree ").foregroundColor(fg)
                + tok("clean", 2)
            tok("✓ ", 10)
                + Text("themed by ").foregroundColor(fg)
                + tok("NvChad/base46", 4)
                + Text(" — ").foregroundColor(fg)
                + tok(controller.theme.name, 5)
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
                Toggle("Option key acts as Meta (ESC)", isOn: $controller.optionAsMetaKey)
                Toggle("Allow mouse reporting", isOn: $controller.allowMouseReporting)
                Toggle("Backspace sends Ctrl-H", isOn: $controller.backspaceSendsControlH)
            }
            Section("Color mapping") {
                Picker("ANSI 256 strategy", selection: $controller.ansi256Raw) {
                    ForEach(TerminalController.ansi256Options, id: \.raw) { Text($0.label).tag($0.raw) }
                }
                .pickerStyle(.segmented)
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
                // Frosted-glass strength lives in Theme → Opacity (single control).
                Text("Glass transparency is set in Theme → Opacity.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}


// MARK: - Keys

/// Every app command, NvChad-grouped and filterable by name, group or nvim
/// mapping. Each row rebinds live and can be reset to its catalog default.
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
            || cmd.nvim.lowercased().contains(q)
    }

    var body: some View {
        Form {
            Section("Search") {
                TextField("Filter \(TerminalController.commandCatalog.count) commands — name, group or nvim mapping…",
                          text: $search)
                    .textFieldStyle(.roundedBorder)
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
                    Text("No custom bindings yet. Add extra combos for any command — space works as the nvim leader.")
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

/// One command row: title + the neovim mapping it mirrors, a capture cell,
/// duplicate warning, and a one-click reset to the catalog default.
private struct ShortcutRow: View {
    let spec: CommandSpec
    let conflicting: Bool
    @Binding var binding: KeyBinding

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(spec.title)
                Text(spec.nvim.isEmpty ? "—" : spec.nvim)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
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
            // Accept any printable character INCLUDING space (nvim <leader>);
            // ignore pure-modifier presses.
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
        case " ": return s + "␣"                       // space / nvim leader
        default:
            let k = b.key
            return s + (k.count == 1 && k.first!.isLetter ? k.uppercased() : k)
        }
    }
}
