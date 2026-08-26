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
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, appearance, text, terminal, window, shortcuts
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general:    "General"
        case .appearance: "Appearance"
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

// MARK: - Appearance
private struct AppearancePane: View {
    @EnvironmentObject private var controller: TerminalController

    private func colorBinding(_ key: TerminalController.OverrideKey) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: controller.effectiveColor(key)) },
            set: { controller.setOverride(key, NSColor($0)) }
        )
    }

    var body: some View {
        Form {
            Section("Theme") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 10) {
                    ForEach(TerminalController.themes) { theme in
                        ThemeCard(theme: theme, selected: controller.themeName == theme.name)
                            .onTapGesture { controller.themeName = theme.name }
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Colors") {
                LabeledContent("Background") { ColorSwatches(selection: colorBinding(.bg)) }
                LabeledContent("Text") { ColorSwatches(selection: colorBinding(.fg)) }
                LabeledContent("Cursor") { ColorSwatches(selection: colorBinding(.caret)) }
                LabeledContent("Selection") { ColorSwatches(selection: colorBinding(.selection)) }
                Slider(value: $controller.backgroundAlpha, in: 0.25...1, step: 0.05) {
                    Text("Background opacity")
                } minimumValueLabel: {
                    Image(systemName: "circle.lefthalf.filled")
                } maximumValueLabel: {
                    Image(systemName: "circle.fill")
                }
                Button("Reset theme colors") { controller.resetColors() }
                    .controlSize(.small)
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

private struct ThemeCard: View {
    let theme: TerminalController.TerminalTheme
    let selected: Bool
    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(theme.bg))
                .frame(width: 22, height: 22)
                .overlay(Circle().stroke(Color(theme.fg).opacity(0.7), lineWidth: 1.5))
            VStack(alignment: .leading, spacing: 2) {
                Text(theme.name).font(.subheadline.weight(.medium))
                Text("preview").font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color(theme.fg))
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(theme.bg).opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(selected ? Color.primary : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
    }
}

private struct TerminalPreview: View {
    @EnvironmentObject private var controller: TerminalController
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("$ ls -la --color")
                .font(Font.custom(controller.fontName, size: 13))
            Text("drwxr-xr-x  12 user  staff   384 Aug 26 09:14 macterm")
                .font(Font.custom(controller.fontName, size: 13))
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: controller.backgroundColor).opacity(1))
        .foregroundColor(Color(nsColor: controller.foregroundColor))
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

/// Inline color selection — no popover. A scrollable row of preset swatches;
/// the selected one is outlined. Replaces `ColorPicker` so changing theme
/// colors stays inside the Settings UI.
private struct ColorSwatches: View {
    @Binding var selection: Color
    private let presets: [(name: String, color: Color)] = [
        ("Terminal", Color(.sRGB, red: 0.07, green: 0.09, blue: 0.11, opacity: 1)),
        ("Carbon",   Color(.sRGB, red: 0.10, green: 0.10, blue: 0.12, opacity: 1)),
        ("Navy",     Color(.sRGB, red: 0.05, green: 0.07, blue: 0.20, opacity: 1)),
        ("Slate",    Color(.sRGB, white: 0.22, opacity: 1)),
        ("Fox",      Color(.sRGB, red: 0.20, green: 0.13, blue: 0.10, opacity: 1)),
        ("Red",      Color(red: 0.78, green: 0.22, blue: 0.22)),
        ("Orange",   Color(red: 0.85, green: 0.50, blue: 0.18)),
        ("Yellow",   Color(red: 0.88, green: 0.80, blue: 0.22)),
        ("Green",    Color(red: 0.25, green: 0.70, blue: 0.35)),
        ("Blue",     Color(red: 0.30, green: 0.52, blue: 0.92)),
        ("Purple",   Color(red: 0.60, green: 0.35, blue: 0.85)),
        ("White",    Color.white),
        ("Black",    Color.black),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(presets.enumerated()), id: \.offset) { _, p in
                    Button { selection = p.color } label: {
                        Circle()
                            .fill(p.color)
                            .frame(width: 18, height: 18)
                            .overlay(
                                Circle()
                                    .stroke(selection == p.color ? Color.primary : Color.clear,
                                            lineWidth: 2)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(p.name)
                }
            }
            .padding(2)
        }
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
