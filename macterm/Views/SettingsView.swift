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
            .navigationTitle("Settings")
            .navigationSplitViewColumnWidth(200)
        } detail: {
            Group {
                switch selection {
                case .general:    GeneralPane()
                case .appearance: AppearancePane()
                case .text:       TextPane()
                case .terminal:   TerminalPane()
                case .window:     WindowPane()
                case .shortcuts:  ShortcutsPane()
                }
            }
            .navigationTitle(selection.title)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationSplitViewStyle(.automatic)
        .frame(minWidth: 780, minHeight: 560)
        .background(VisualEffectView(material: .windowBackground, blendingMode: .withinWindow))
        // The Settings window follows the app theme too (dark/light materials + controls).
        .preferredColorScheme(controller.theme.isDark ? .dark : .light)
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, appearance, text, terminal, window, shortcuts
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general:    "General"
        case .appearance: "Theme"
        case .text:       "Text"
        case .terminal:   "Terminal"
            case .window:     "Window"
            case .shortcuts:  "Shortcuts"
        }
    }
    var icon: String {
        switch self {
        case .general:    "gearshape"
        case .appearance: "paintbrush"
        case .text:       "textformat"
        case .terminal:   "terminal"
            case .window:     "macwindow"
            case .shortcuts:  "command"
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
                Slider(value: $controller.terminalTransparency, in: 0...0.9, step: 0.05) {
                    Text("Terminal transparency")
                }
                Text("Higher = more frosted glass; lower = more solid.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Restore All Defaults", role: .destructive) {
                    controller.resetAllSettings()
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}


// MARK: - Shortcuts
private struct ShortcutsPane: View {
    @EnvironmentObject private var controller: TerminalController

    private let commands: [(id: String, label: String)] = [
        ("newTab", "New Tab"),
        ("closeTab", "Close Tab"),
        ("toggleSidebar", "Toggle Sidebar"),
        ("clear", "Clear"),
    ]

    var body: some View {
        Form {
            Section("Application Shortcuts") {
                ForEach(commands, id: \.id) { cmd in
                    if let index = controller.keyBindings.firstIndex(where: { $0.id == cmd.id }) {
                        ShortcutCaptureRow(label: cmd.label,
                                           binding: $controller.keyBindings[index])
                    }
                }
            }
            Section {
                Button("Reset Shortcuts") { controller.resetKeyBindings() }
                    .controlSize(.small)
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

/// A labeled row that captures the next key combination and writes it to the
/// bound `KeyBinding`. Click to arm; press a combo, or Esc to cancel.
private struct ShortcutCaptureRow: View {
    let label: String
    @Binding var binding: KeyBinding
    @State private var listening = false
    @State private var monitor: Any?
    @State private var display = ""

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Button(action: toggleListening) {
                Text(listening ? "Press shortcut…" : display)
                    .frame(minWidth: 96)
            }
            .buttonStyle(.bordered)
            .help("Click, then press the desired key combination (Esc cancels)")
        }
        .onAppear { display = Self.describe(binding) }
        .onChange(of: binding) { _, newValue in display = Self.describe(newValue) }
        .onDisappear { stopListening() }
    }

    private func toggleListening() {
        if listening { stopListening() } else { startListening() }
    }

    private func startListening() {
        listening = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { self.stopListening(); return nil }      // Esc cancels
            guard let chars = event.charactersIgnoringModifiers,
                  let first = chars.lowercased().first,
                  first.isLetter || first.isNumber else { return event }    // ignore modifier-only
            var b = self.binding
            b.key = String(first)
            b.modifiers = Int(Self.eventModifiers(event).rawValue)
            self.binding = b
            self.display = Self.describe(b)
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

    private static func describe(_ b: KeyBinding) -> String {
        guard !b.key.isEmpty else { return "Unassigned" }
        var s = ""
        let m = EventModifiers(rawValue: b.modifiers)
        if m.contains(.command) { s += "⌘" }
        if m.contains(.shift)   { s += "⇧" }
        if m.contains(.option)  { s += "⌥" }
        if m.contains(.control) { s += "⌃" }
        return s + b.key.uppercased()
    }
}
