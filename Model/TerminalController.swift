import Foundation
import SwiftTerm
import SwiftUI
import AppKit
import Darwin

/// App-wide state: the tab set, the active tab, sidebar visibility, the
/// favorite roots, the full terminal appearance/behavior settings (persisted to
/// `UserDefaults`), and a registry of live `LocalProcessTerminalView`s so the
/// sidebar can drive input (cd / paste path) into the right pty.
/// A user-rebindable keyboard shortcut for an app command.
struct KeyBinding: Codable, Equatable, Identifiable {
    let id: String
    /// Single character, symbol, digit or " " (space / leader key).
    var key: String
    /// SwiftUI `EventModifiers` raw value.
    var modifiers: Int
    /// For user-defined bindings: the built-in command id they trigger.
    var action: String? = nil

    init(id: String, key: String, modifiers: Int, action: String? = nil) {
        self.id = id
        self.key = key
        self.modifiers = modifiers
        self.action = action
    }
}

/// Event-level matcher shared by the view interceptor and the app-global
/// shortcut monitor: same character plus identical cmd/shift/opt/ctrl flags.
extension KeyBinding {
    func matches(event: NSEvent) -> Bool {
        guard !key.isEmpty else { return false }
        // Arrow keys arrive as private-use chars (F700–F703); stored as glyphs.
        let expected = Self.arrowCharByGlyph[key] ?? key
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        guard chars == expected else { return false }
        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let want = EventModifiers(rawValue: modifiers)
        return f.contains(.command) == want.contains(.command)
            && f.contains(.shift) == want.contains(.shift)
            && f.contains(.option) == want.contains(.option)
            && f.contains(.control) == want.contains(.control)
    }
}

extension KeyBinding {
    /// Arrow-key glyph ↔ macOS private-use chars (NSEvent `charactersIgnoringModifiers`).
    /// NvChad-style. Old captures may have stored the private-use chars
    /// directly — `restore()` rewrites them to the readable glyph form so
    /// describe() and SwiftUI's KeyEquivalent map them cleanly.
    static let arrowGlyphByKeyCode: [UInt16: String] =
        [123: "←", 124: "→", 125: "↓", 126: "↑"]
    static let arrowCharByGlyph: [String: String] =
        ["←": "\u{F702}", "→": "\u{F703}", "↓": "\u{F701}", "↑": "\u{F700}"]
    static let arrowGlyphByChar: [String: String] = [
        "\u{F700}": "↑", "\u{F701}": "↓", "\u{F702}": "←", "\u{F703}": "→",
    ]
}
/// One rebindable app command. The catalog below is the SINGLE source of
/// truth: it feeds the default keybindings, the Shortcuts settings pane and
/// the menu bar, so all three always agree.
struct CommandSpec: Identifiable {
    let id: String
    let group: String
    let title: String
    let key: String
    let mods: EventModifiers
}

// MARK: - Split layout (tabs hold recursive split trees, iTerm-style)
enum SplitDirection: String, Codable {
    case vertical   // side-by-side (HSplitView)
    case horizontal // stacked (VSplitView)
}

/// Recursive split tree. A leaf is one terminal pane (a session id); a split
/// node arranges two children vertically (side-by-side) or horizontally
/// (stacked). `Identifiable` so it can back SwiftUI `ForEach` where needed.
indirect enum PaneNode: Identifiable {
    case terminal(Session.ID)
    case split(id: UUID, direction: SplitDirection, a: PaneNode, b: PaneNode)

    var id: UUID {
        switch self {
        case .terminal(let s): return s
        case .split(let id, _, _, _): return id
        }
    }
    var sessionIds: [UUID] {
        switch self {
        case .terminal(let s): return [s]
        case .split(_, _, let a, let b): return a.sessionIds + b.sessionIds
        }
    }
    var firstLeaf: UUID? {
        switch self {
        case .terminal(let s): return s
        case .split(_, _, let a, _): return a.firstLeaf
        }
    }
    func replacing(_ target: UUID, with replacement: PaneNode) -> PaneNode {
        switch self {
        case .terminal(let s): return s == target ? replacement : self
        case .split(let id, let dir, let a, let b):
            return .split(id: id, direction: dir, a: a.replacing(target, with: replacement), b: b.replacing(target, with: replacement))
        }
    }
    /// Remove the leaf `target`; collapses single-child splits. `nil` if the
    /// whole tree would be emptied.
    func removing(_ target: UUID) -> PaneNode? {
        switch self {
        case .terminal(let s): return s == target ? nil : self
        case .split(let id, let dir, let a, let b):
            let na = a.removing(target), nb = b.removing(target)
            switch (na, nb) {
            case (.some(let a), .some(let b)): return .split(id: id, direction: dir, a: a, b: b)
            case (.some(let a), .none): return a
            case (.none, .some(let b)): return b
            case (.none, .none): return nil
            }
        }
    }

    /// The leaf whose session is `id` (for pane zoom rendering).
    func leaf(containing id: UUID) -> PaneNode? {
        switch self {
        case .terminal(let s):
            return s == id ? self : nil
        case .split(_, _, let a, let b):
            return a.leaf(containing: id) ?? b.leaf(containing: id)
        }
    }
}


/// One top-level tab: a self-contained split tree.
struct WorkspaceTab: Identifiable {
    let id = UUID()
    var title: String
    var layout: PaneNode
    /// Optional accent color shown as a dot on the tab pill.
    var color: NSColor? = nil
    /// Zoom: render only the focused pane, full-size (toggle).
    var zoomFocused: Bool = false
}

/// In-memory text buffer backing an in-app editor session. Stored in
/// `TerminalController.editorBuffers` keyed by `Session.id` so each editor tab
/// owns its content (and unsaved edits) independently of the mounted view —
/// fixes the bug where switching tabs reused one view's `@State`.
struct EditorBuffer {
    var content: String
    var original: String
}

extension Notification.Name {
    /// Ask the sidebar to rebuild its roots (Keys → Reload File Tree).
    static let reloadFileTree = Notification.Name("macterm.reloadFileTree")
    /// Toggle dot files visibility in sidebar.
    static let toggleDotFiles = Notification.Name("macterm.toggleDotFiles")
}

@MainActor
final class TerminalController: ObservableObject {

    // MARK: - Sessions / tabs
    @Published var sessions: [Session] =
        [Session(title: "zsh", cwd: nil, profile: "Local")]
    @Published var tabs: [WorkspaceTab] = []
    @Published var activeTabId: UUID = UUID()
    @Published var focusedSessionId: UUID = UUID()
    @Published var sidebarCollapsed: Bool = false { didSet { persist() } }
    @Published var showAgentPanel: Bool = false { didSet { persist() } }

    /// Per-editor-session text buffers, keyed by `Session.id`. Lives in the
    /// model (not the view) so switching tabs preserves each file's content.
    @Published var editorBuffers: [UUID: EditorBuffer] = [:]

    // MARK: - Appearance
    /// Active NvChad/base46 theme slug ("onedark"). All terminal colors, the
    /// editor palette and the app's dark/light appearance derive from it.
    @Published var themeName: String = AppTheme.defaultSlug { didSet { persist() } }
    /// Per-slot base16 hex overrides keyed by theme slug, so users can fine-tune
    /// any ANSI color. Empty for a theme = use the catalog colors.
    @Published var themeColorOverrides: [String: [String: String]] = [:] { didSet { persist() } }
    /// Terminal background opacity (1 = opaque, <1 = frosted glass over the vibrancy).
    @Published var backgroundAlpha: Double = 0.7 { didSet { persist() } }

    // MARK: - Text
    @Published var fontName: String = TerminalController.defaultFontName { didSet { persist() } }
    @Published var fontSize: Double = 13 { didSet { persist() } }
    @Published var cursorShapeRaw: String = "block" { didSet { persist() } }
    @Published var cursorBlink: Bool = true { didSet { persist() } }
    @Published var useBrightColors: Bool = true { didSet { persist() } }

    // MARK: - Terminal engine
    @Published var scrollback: Double = 10000 { didSet { persist() } }
    @Published var optionAsMetaKey: Bool = true { didSet { persist() } }
    @Published var allowMouseReporting: Bool = true { didSet { persist() } }
    @Published var backspaceSendsControlH: Bool = false { didSet { persist() } }
    @Published var ansi256Raw: String = "base16Lab" { didSet { persist() } }

    /// Rebindable keyboard shortcuts for app commands (persisted).
    @Published var keyBindings: [KeyBinding] = TerminalController.defaultKeyBindings() { didSet { persist() } }
    /// Expanded folder paths for the file tree. Persisted, so the tree looks
    /// identical after relaunches, tab switches and sidebar toggles.
    @Published var expandedPaths: Set<String> = [] { didSet { persistExpandedPaths() } }
    /// Directories pinned as projects from the sidebar tree (persisted).
    @Published var projects: [SidebarProject] = [] { didSet { persist() } }
    /// Saved SSH connections (persisted).
    @Published var sshConnections: [SSHConnection] = [] { didSet { persist() } }

    func setExpanded(_ path: String, _ expanded: Bool) {
        if expanded { expandedPaths.insert(path) } else { expandedPaths.remove(path) }
    }
    // MARK: - Projects

    func addProject(_ url: URL) {
        let path = url.path
        guard !projects.contains(where: { $0.path == path }) else { return }
        projects.append(SidebarProject(id: UUID(), path: path,
                                        name: url.lastPathComponent, colorHex: "5AC2E7"))
    }
    func removeProject(_ id: UUID) { projects.removeAll { $0.id == id } }
    func renameProject(_ id: UUID, _ name: String) {
        if let i = projects.firstIndex(where: { $0.id == id }) { projects[i].name = name }
    }
    func setProjectColor(_ id: UUID, _ hex: String) {
        if let i = projects.firstIndex(where: { $0.id == id }) { projects[i].colorHex = hex }
    }
    func isProject(_ url: URL) -> Bool { projects.contains { $0.path == url.path } }
    // MARK: - SSH

    func addSSHConnection(_ c: SSHConnection) { sshConnections.append(c) }
    func removeSSHConnection(_ id: UUID) { sshConnections.removeAll { $0.id == id } }
    func updateSSHConnection(_ c: SSHConnection) {
        if let i = sshConnections.firstIndex(where: { $0.id == c.id }) { sshConnections[i] = c }
    }
    /// Open a new terminal tab that launches `ssh` for the given connection.
    @discardableResult
    func connectSSH(_ c: SSHConnection) -> UUID {
        let s = Session(title: c.name.isEmpty ? c.host : c.name,
                        cwd: nil, profile: "SSH",
                        ssh: SSHLaunch(host: c.host, user: c.user, port: c.port, identityFile: c.identityFile))
        sessions.append(s)
        let tab = WorkspaceTab(title: s.title, layout: .terminal(s.id))
        tabs.append(tab)
        activeTabId = tab.id
        return s.id
    }

    // MARK: - General
    @Published var shellPath: String = { ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh" }() { didSet { persist() } }
    /// Startup directory for new tabs. No hard-coded project paths — new tabs
    /// open in the shell's default (the user's home directory).
    @Published var startupDirRaw: String = "home" { didSet { persist() } }
    /// Close the tab automatically when the shell exits.
    @Published var closeOnExit: Bool = true { didSet { persist() } }

    // MARK: - Window
    @Published var sidebarWidth: Double = 260 { didSet { persist() } }
    @Published var terminalPadding: Double = 4 { didSet { persist() } }
    @Published var windowMaterialRaw: String = String(NSVisualEffectView.Material.sidebar.rawValue) { didSet { persist() } }
    @Published var windowBackgroundOpacity: Double = 0.85 { didSet { persist() } }

    var windowMaterial: NSVisualEffectView.Material {
        NSVisualEffectView.Material(rawValue: Int(windowMaterialRaw) ?? NSVisualEffectView.Material.sidebar.rawValue) ?? .sidebar
    }
    let favorites: [URL] = [
        FileManager.default.homeDirectoryForCurrentUser
    ]
    private var views: [UUID: LocalProcessTerminalView] = [:]
    
    /// Shared agentic system for AI workflows
    let agenticSystem = AgenticSystem()
    /// Liquid Glass appearance toggle (Settings → Appearance). On = macOS 26
    /// Liquid Glass (or NSVisualEffectView vibrancy on macOS 15); off = the
    /// existing theme backgrounds. Persisted; defaults to on so the current
    /// always-glass chrome is preserved until the user opts out.
    @Published var liquidGlass: Bool = (UserDefaults.standard.object(forKey: "liquidGlass") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(liquidGlass, forKey: "liquidGlass") }
    }

    var activeCwd: String? {
        sessions.first(where: { $0.id == focusedSessionId })?.cwd
    }

    // MARK: - Font + theme catalog (Nerd Fonts so shell glyphs render)
    private static let nerdFonts: [String] =
        NSFontManager.shared.availableFontFamilies
            .filter { $0.localizedCaseInsensitiveContains("Nerd") }
            .sorted()

    static let fontChoices: [String] = {
        var f = nerdFonts
        for fb in ["Menlo", "Monaco"] where !f.contains(fb) { f.append(fb) }
        return f.isEmpty ? ["Menlo"] : f
    }()


    static let cursorShapes: [(raw: String, label: String)] = [
        ("block", "Block"), ("bar", "Bar"), ("underline", "Underline")
    ]
    static let ansi256Options: [(raw: String, label: String)] = [
        ("base16Lab", "Base16 Lab"), ("harmonious", "Harmonious")
    ]
    static let startupDirOptions: [(raw: String, label: String)] = [
        ("home", "Home")
    ]

    private static var defaultFontName: String {
        let prefs = ["MesloLGS Nerd Font", "FiraCode Nerd Font Mono",
                     "FiraCode Nerd Font", "JetBrainsMono Nerd Font"]
        for p in prefs where nerdFonts.contains(p) { return p }
        return nerdFonts.first ?? "Menlo"
    }

    // MARK: - Resolved values consumed by the terminal view
    /// The active NvChad/base46 scheme; falls back to the default when the
    /// persisted slug no longer exists (e.g. after a catalog refresh).
    var theme: AppTheme {
        let base = AppTheme.bySlug(themeName) ?? AppTheme.bySlug(AppTheme.defaultSlug)!
        guard let o = themeColorOverrides[themeName], !o.isEmpty else { return base }
        var map: [Int: String] = [:]
        for (k, v) in o { if let i = Int(k) { map[i] = v } }
        return base.applyingOverrides(map)
    }
    var isDarkTheme: Bool { theme.isDark }
    var accentColor: NSColor { theme.accent }

    /// Clear manual color overrides for the active theme.
    func resetThemeColors() {
        themeColorOverrides[themeName] = [:]
    }

    /// Two-way binding for editing one ANSI slot's color in Settings.
    func themeColorBinding(_ slot: Int) -> Binding<SwiftUI.Color> {
        Binding(
            get: {
                let hex = self.themeColorOverrides[self.themeName]?["\(slot)"] ?? self.theme.base16[slot]
                return SwiftUI.Color(nsColor: NSColor(hex: hex) ?? .black)
            },
            set: { c in
                let r = c.resolve(in: EnvironmentValues())
                let hex = String(format: "%02X%02X%02X",
                                 Int((r.red * 255).rounded()),
                                 Int((r.green * 255).rounded()),
                                 Int((r.blue * 255).rounded()))
                var forTheme = self.themeColorOverrides[self.themeName] ?? [:]
                forTheme["\(slot)"] = hex
                self.themeColorOverrides[self.themeName] = forTheme
            }
        )
    }
    var font: NSFont {
        NSFont(name: fontName, size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }
    /// Theme background with the user's opacity applied (drives glass).
    var backgroundColor: NSColor { theme.background.withAlphaComponent(backgroundAlpha) }
    /// Convenience: higher value = more transparent / more frosted terminal.
    var terminalTransparency: Double {
        get { 1.0 - backgroundAlpha }
        set { backgroundAlpha = 1.0 - newValue }
    }
    var foregroundColor: NSColor { theme.foreground }
    var caretColor: NSColor { theme.caret }
    var selectionColor: NSColor { theme.selection.withAlphaComponent(0.45) }
    /// 16 ANSI slots mapped exactly like NvChad/base46's `term.lua`.
    var ansiColors: [SwiftTerm.Color] { theme.ansiColors }
    /// Cheap signature of every *live-applied* setting, so the view can skip
    /// redundant re-application on unrelated `@Published` changes.
    var appearanceSignature: String {
        "\(fontName)|\(fontSize)|\(themeName)|\(backgroundAlpha)|"
            + "\(optionAsMetaKey)|\(allowMouseReporting)|\(backspaceSendsControlH)|\(useBrightColors)|"
            + "\(cursorShapeRaw)|\(cursorBlink)|\(ansi256Raw)"
    }

    var cursorStyle: CursorStyle {
        switch (cursorShapeRaw, cursorBlink) {
        case ("block", true):     return .blinkBlock
        case ("block", false):    return .steadyBlock
        case ("bar", true):       return .blinkBar
        case ("bar", false):      return .steadyBar
        case ("underline", true): return .blinkUnderline
        case ("underline", false):return .steadyUnderline
        default:                  return .blinkBlock
        }
    }
    var ansi256Strategy: Ansi256PaletteStrategy {
        ansi256Raw == "harmonious" ? .base16LabHarmonious : .base16Lab
    }
    /// Options applied at terminal creation (scrollback/cursor/palette strategy).
    func terminalOptions() -> TerminalOptions {
        TerminalOptions(
            cursorStyle: cursorStyle,
            scrollback: Int(scrollback),
            ansi256PaletteStrategy: ansi256Strategy
        )
    }

    var startupDirectory: String? {
        // No hard-coded project paths: new tabs open in the user's home.
        FileManager.default.homeDirectoryForCurrentUser.path
    }
    /// Every app command, grouped NvChad-style. Defaults blend macOS idioms
    /// with the neovim mappings they mirror (`lua/nvchad/mappings.lua`).
    static let commandCatalog: [CommandSpec] = [
        CommandSpec(id: "newTab",       group: "Tabs",   title: "New Tab", key: "t", mods: .command),
        CommandSpec(id: "nextTab",      group: "Tabs",   title: "Next Tab", key: "]", mods: [.command, .shift]),
        CommandSpec(id: "prevTab",      group: "Tabs",   title: "Previous Tab", key: "[", mods: [.command, .shift]),
        CommandSpec(id: "closePane",    group: "Tabs",   title: "Close Pane / Tab", key: "w", mods: .command),

        // Panes — <C-w> family; navigation mirrors <leader>sv/<leader>sh +
        // the <C-h/j/k/l> window-navigation group (⌥⌘ on macOS).
        CommandSpec(id: "splitRight",   group: "Panes",  title: "Split Right", key: "d", mods: .command),
        CommandSpec(id: "splitDown",    group: "Panes",  title: "Split Down", key: "d", mods: [.command, .shift]),
        CommandSpec(id: "focusLeft",    group: "Panes",  title: "Focus Pane Left", key: "h", mods: [.command, .option]),
        CommandSpec(id: "focusDown",    group: "Panes",  title: "Focus Pane Below", key: "j", mods: [.command, .option]),
        CommandSpec(id: "focusUp",      group: "Panes",  title: "Focus Pane Above", key: "k", mods: [.command, .option]),
        CommandSpec(id: "focusRight",   group: "Panes",  title: "Focus Pane Right", key: "l", mods: [.command, .option]),

        // View / UI
        CommandSpec(id: "toggleSidebar",group: "View",   title: "Toggle Sidebar", key: "s", mods: [.command, .shift]),
        CommandSpec(id: "toggleAgentPanel", group: "View", title: "Toggle Agent Panel", key: "a", mods: [.command, .shift]),
        CommandSpec(id: "clearTerminal",group: "View",   title: "Clear Terminal", key: "k", mods: .command),
        CommandSpec(id: "fontBigger",   group: "View",   title: "Font Size Up", key: "=", mods: .command),
        CommandSpec(id: "fontSmaller",  group: "View",   title: "Font Size Down", key: "-", mods: .command),
        CommandSpec(id: "fontReset",    group: "View",   title: "Reset Font Size", key: "0", mods: .command),


        // Layout & focus extras
        CommandSpec(id: "moveTabLeft",   group: "Tabs",  title: "Move Tab Left",  key: "[", mods: [.control, .option]),
        CommandSpec(id: "moveTabRight",  group: "Tabs",  title: "Move Tab Right",  key: "]", mods: [.control, .option]),
        CommandSpec(id: "alternateTab",  group: "Tabs",  title: "Alternate Tab", key: "0", mods: [.command, .option]),
        CommandSpec(id: "newTabInCwd",   group: "Tabs",  title: "New Tab in CWD", key: "n", mods: [.command, .option]),
        CommandSpec(id: "focusNextLeaf", group: "Panes", title: "Cycle Pane Forward", key: "]", mods: [.command, .shift]),
        CommandSpec(id: "focusPrevLeaf", group: "Panes", title: "Cycle Pane Backward", key: "[", mods: [.command, .shift]),
        CommandSpec(id: "zoomPaneToggle",group: "Panes", title: "Zoom Focused Pane", key: "z", mods: [.command, .option]),
        CommandSpec(id: "closeOtherPanes", group: "Panes", title: "Close Other Panes", key: "w", mods: [.command, .option]),

        // Theme / tree / terminal engine
        CommandSpec(id: "themeCycleNext", group: "View", title: "Next Theme", key: "t", mods: [.command, .option]),
        CommandSpec(id: "themeCyclePrev", group: "View", title: "Previous Theme", key: "t", mods: [.command, .option, .shift]),
        CommandSpec(id: "reloadFileTree", group: "View", title: "Reload File Tree", key: "e", mods: [.command, .shift]),
        CommandSpec(id: "toggleMouseReporting", group: "View", title: "Toggle Mouse Reporting", key: "m", mods: [.command, .option]),
        CommandSpec(id: "toggleOptionAsMeta",  group: "View", title: "Toggle Option as Meta", key: "o", mods: [.command, .option]),
        CommandSpec(id: "clearScrollbackOnly",  group: "View", title: "Clear Scrollback Only", key: "k", mods: [.command, .option]),
        CommandSpec(id: "copyActivePath", group: "View",    title: "Copy Active Path", key: "c", mods: [.command, .option]),
        CommandSpec(id: "minimizeWindow", group: "View",    title: "Minimize Window", key: "m", mods: .command),
        CommandSpec(id: "toggleDotFiles", group: "View",    title: "Toggle Dot Files", key: ".", mods: .command),

        // Special Characters
        CommandSpec(id: "insertSpecialChar", group: "Edit", title: "Insert Special Character", key: "s", mods: [.command, .control]),
        CommandSpec(id: "insertMu", group: "Edit", title: "Insert µ (micro)", key: "m", mods: [.command, .control, .option]),
        CommandSpec(id: "insertApprox", group: "Edit", title: "Insert ≈ (approx)", key: "a", mods: [.command, .control, .option]),
        CommandSpec(id: "insertCedilla", group: "Edit", title: "Insert ç (cedilla)", key: "c", mods: [.command, .control, .option]),
        CommandSpec(id: "insertIntegral", group: "Edit", title: "Insert ∫ (integral)", key: "i", mods: [.command, .control, .option]),
        CommandSpec(id: "insertTilde", group: "Edit", title: "Insert ~ (tilde)", key: "`", mods: [.command, .control, .option]),
        CommandSpec(id: "insertLessEqual", group: "Edit", title: "Insert ≤ (less-equal)", key: ",", mods: [.command, .control, .option]),
        CommandSpec(id: "insertPi", group: "Edit", title: "Insert π (pi)", key: "p", mods: [.command, .control, .option]),
        CommandSpec(id: "insertBullet", group: "Edit", title: "Insert • (bullet)", key: "8", mods: [.command, .control, .option]),
        CommandSpec(id: "insertSection", group: "Edit", title: "Insert § (section)", key: "6", mods: [.command, .control, .option]),
        CommandSpec(id: "insertInfinity", group: "Edit", title: "Insert ∞ (infinity)", key: "5", mods: [.command, .control, .option]),
        CommandSpec(id: "insertCent", group: "Edit", title: "Insert ¢ (cent)", key: "4", mods: [.command, .control, .option]),
        CommandSpec(id: "insertPound", group: "Edit", title: "Insert £ (pound)", key: "3", mods: [.command, .control, .option]),

        // Editor
        CommandSpec(id: "editorSave",   group: "Editor", title: "Save File", key: "s", mods: .command),
        CommandSpec(id: "editorRevert", group: "Editor", title: "Revert File",       key: "r", mods: [.command, .option]),

        // More editing
        CommandSpec(id: "cut",          group: "Edit",   title: "Cut", key: "x", mods: .command),
        CommandSpec(id: "selectAll",    group: "Edit",   title: "Select All", key: "a", mods: .command),
        CommandSpec(id: "undo",         group: "Edit",   title: "Undo",     key: "z", mods: .command),
        CommandSpec(id: "redo",         group: "Edit",   title: "Redo", key: "z", mods: [.command, .shift]),

        // Go to tab ({n}gt)
    ] + (1...9).map { n in
        CommandSpec(id: "goToTab.\(n)", group: "Go to Tab",
                    title: "Go to Tab \(n)",
                    key: "\(n)", mods: .command)
    }

    /// Groups in stable display order.
    static let commandGroups: [(group: String, commands: [CommandSpec])] = {
        var order: [String] = []
        var byGroup: [String: [CommandSpec]] = [:]
        for c in commandCatalog {
            if byGroup[c.group] == nil { order.append(c.group) }
            byGroup[c.group, default: []].append(c)
        }
        return order.map { ($0, byGroup[$0]!) }
    }()

    static func defaultKeyBindings() -> [KeyBinding] {
        commandCatalog.map { KeyBinding(id: $0.id, key: $0.key, modifiers: Int($0.mods.rawValue)) }
    }
    /// The catalog default for one command (used by per-row reset).
    static func defaultBinding(for id: String) -> KeyBinding {
        let s = commandCatalog.first { $0.id == id }!
        return KeyBinding(id: s.id, key: s.key, modifiers: Int(s.mods.rawValue))
    }
    init() {
        restore()
        let first = Session(title: "zsh", cwd: startupDirectory, profile: "Local")
        sessions = [first]
        let tab = WorkspaceTab(title: "zsh", layout: .terminal(first.id))
        tabs = [tab]
        activeTabId = tab.id
        focusedSessionId = first.id
        installGlobalShortcuts()
        
        // Configure agentic system with this controller for real tool implementations
        agenticSystem.configureTools(with: self)
    }

    /// App-global key interception for terminal-scoped combos. Local monitors
    /// run BEFORE window dispatch (responder chain AND menu key-equivalent
    /// processing), so a bound combo is routed deterministically even when the
    /// system Window→Close item shares it (⌘W) or focus sits outside the
    /// terminal view. Scope-guarded: only closePane bindings, and only
    /// workspace windows — Settings carries a SettingsMarkerView and keeps
    /// its native ⌘W behavior.
    private var keyMonitor: Any?

    private func installGlobalShortcuts() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // App-level command shortcut: ⌘W closes the focused pane, not the
            // window. Swallowed before the responder chain / menus see it.
            if event.modifierFlags.contains(.command),
               let win = NSApp.keyWindow ?? NSApp.mainWindow,
               !windowContains(win, SettingsMarkerView.self),
               self.keyBindings.contains(where: { self.actionId(for: $0) == "closePane" && $0.matches(event: event) }) {
                self.closeFocusedPane()
                return nil
            }
            // Forward every other keystroke to the focused pty — INCLUDING the
            // OS auto-repeat events (event.isARepeat) emitted while a key is
            // held — so holding h/j/k/l scrolls nvim exactly like a native
            // terminal. Only plain printable keys are intercepted here; modifier
            // and special keys (⌘-combos, arrows, Tab, Enter, Esc…) fall through
            // to SwiftTerm's keyDown for correct translation. We act only when
            // the terminal view is the first responder, so text fields (Settings,
            // sidebar search, in-app editor) keep working normally.
            if let win = NSApp.keyWindow ?? NSApp.mainWindow,
               let tv = win.firstResponder as? LocalProcessTerminalView,
               event.modifierFlags.isDisjoint(with: [.command, .control, .option, .function]),
               let chars = event.characters, chars.count == 1,
               !chars.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
                tv.send(txt: chars)
                return nil
            }
            return event
        }
    }

    private func restore() {
        let d = UserDefaults.standard
        // Validate against the catalog — stale slugs (old themes, renamed
        // entries) fall back to the default instead of a black terminal.
        themeName              = d.string(forKey: "themeName").flatMap(AppTheme.bySlug)?.slug ?? AppTheme.defaultSlug
        backgroundAlpha        = d.object(forKey: "backgroundAlpha") as? Double ?? backgroundAlpha
        fontName               = d.string(forKey: "fontName") ?? fontName
        fontSize               = d.object(forKey: "fontSize") as? Double ?? fontSize
        cursorShapeRaw         = d.string(forKey: "cursorShapeRaw") ?? cursorShapeRaw
        cursorBlink            = d.object(forKey: "cursorBlink") as? Bool ?? cursorBlink
        useBrightColors        = d.object(forKey: "useBrightColors") as? Bool ?? useBrightColors
        scrollback             = d.object(forKey: "scrollback") as? Double ?? scrollback
        optionAsMetaKey        = d.object(forKey: "optionAsMetaKey") as? Bool ?? optionAsMetaKey
        allowMouseReporting     = d.object(forKey: "allowMouseReporting") as? Bool ?? allowMouseReporting
        backspaceSendsControlH  = d.object(forKey: "backspaceSendsControlH") as? Bool ?? backspaceSendsControlH
        ansi256Raw             = d.string(forKey: "ansi256Raw") ?? ansi256Raw
        shellPath              = d.string(forKey: "shellPath") ?? shellPath
        startupDirRaw          = d.string(forKey: "startupDirRaw") ?? startupDirRaw
        closeOnExit            = d.object(forKey: "closeOnExit") as? Bool ?? closeOnExit
        sidebarCollapsed       = d.object(forKey: "sidebarCollapsed") as? Bool ?? sidebarCollapsed
        showAgentPanel         = d.object(forKey: "showAgentPanel") as? Bool ?? showAgentPanel
        liquidGlass            = (d.object(forKey: "liquidGlass") as? Bool) ?? true
        sidebarWidth           = d.object(forKey: "sidebarWidth") as? Double ?? sidebarWidth
        terminalPadding        = d.object(forKey: "terminalPadding2") as? Double ?? terminalPadding
        windowMaterialRaw      = d.string(forKey: "windowMaterialRaw") ?? windowMaterialRaw
        windowBackgroundOpacity = d.object(forKey: "windowBackgroundOpacity") as? Double ?? windowBackgroundOpacity
        themeColorOverrides   = (d.dictionary(forKey: "themeColorOverrides") as? [String: [String: String]]) ?? [:]
        if let data = d.data(forKey: "sidebarProjects"),
           let decoded = try? JSONDecoder().decode([SidebarProject].self, from: data) {
            projects = decoded
        } else {
            projects = []
        }
        if let data = d.data(forKey: "sshConnections"),
           let decoded = try? JSONDecoder().decode([SSHConnection].self, from: data) {
            sshConnections = decoded
        } else {
            sshConnections = []
        }
        if let paths = d.array(forKey: "expandedPaths") as? [String] {
            expandedPaths = Set(paths)
        }
        if let data = d.data(forKey: "keyBindings"),
           let dec = try? JSONDecoder().decode([KeyBinding].self, from: data), !dec.isEmpty {
            // Pre-catalog ids → current ids, then merge with new defaults.
            let legacy: [String: String] = ["clear": "clearTerminal", "closeTab": "closePane"]
            var migrated = dec.map { b in
                let id = legacy[b.id] ?? b.id
                let k  = KeyBinding.arrowGlyphByChar[b.key] ?? b.key
                return KeyBinding(id: id, key: k, modifiers: b.modifiers, action: b.action)
            }
            var seen = Set<String>()
            migrated.removeAll { !seen.insert($0.id).inserted }
            keyBindings = migrated + Self.commandCatalog
                .filter { cmd in !seen.contains(cmd.id) }
                .map { KeyBinding(id: $0.id, key: $0.key, modifiers: Int($0.mods.rawValue)) }
        } else {
            keyBindings = TerminalController.defaultKeyBindings()
        }
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(themeName, forKey: "themeName")
        d.set(backgroundAlpha, forKey: "backgroundAlpha")
        d.set(fontName, forKey: "fontName")
        d.set(fontSize, forKey: "fontSize")
        d.set(cursorShapeRaw, forKey: "cursorShapeRaw")
        d.set(cursorBlink, forKey: "cursorBlink")
        d.set(useBrightColors, forKey: "useBrightColors")
        d.set(scrollback, forKey: "scrollback")
        d.set(optionAsMetaKey, forKey: "optionAsMetaKey")
        d.set(allowMouseReporting, forKey: "allowMouseReporting")
        d.set(backspaceSendsControlH, forKey: "backspaceSendsControlH")
        d.set(ansi256Raw, forKey: "ansi256Raw")
        d.set(shellPath, forKey: "shellPath")
        d.set(startupDirRaw, forKey: "startupDirRaw")
        d.set(closeOnExit, forKey: "closeOnExit")
        d.set(sidebarCollapsed, forKey: "sidebarCollapsed")
        d.set(showAgentPanel, forKey: "showAgentPanel")
        d.set(sidebarWidth, forKey: "sidebarWidth")
        d.set(terminalPadding, forKey: "terminalPadding2")
        d.set(windowMaterialRaw, forKey: "windowMaterialRaw")
        if let data = try? JSONEncoder().encode(projects) { d.set(data, forKey: "sidebarProjects") }
        if let data = try? JSONEncoder().encode(sshConnections) { d.set(data, forKey: "sshConnections") }
        d.set(windowBackgroundOpacity, forKey: "windowBackgroundOpacity")
        d.set(themeColorOverrides, forKey: "themeColorOverrides")
        if let data = try? JSONEncoder().encode(keyBindings) {
            d.set(data, forKey: "keyBindings")
        }
    }

    private func persistExpandedPaths() {
        UserDefaults.standard.set(Array(expandedPaths), forKey: "expandedPaths")
    }

    func resetAllSettings() {
        let d = UserDefaults.standard
        for k in ["themeName","backgroundAlpha","fontName","fontSize","cursorShapeRaw","cursorBlink","themeColorOverrides",
                  "useBrightColors","scrollback","optionAsMetaKey","allowMouseReporting",
                  "backspaceSendsControlH","ansi256Raw","shellPath","startupDirRaw","closeOnExit",
                  "sidebarCollapsed","showAgentPanel","sidebarWidth","terminalPadding2","colorOverrides","keyBindings",
                  "windowMaterialRaw","windowBackgroundOpacity","sidebarProjects","sshConnections",
                  "liquidGlass"] {
            d.removeObject(forKey: k)
        }
        ProviderRegistry.shared.resetToBuiltIns()
        restore()
        agenticSystem.reloadProvider()
        objectWillChange.send()
    }

    // MARK: - Tabs
    func newTab(cwd: String? = nil) {
        let s = Session(title: "zsh", cwd: cwd ?? startupDirectory, profile: "Local")
        sessions.append(s)
        let tab = WorkspaceTab(title: "zsh", layout: .terminal(s.id))
        self.tabs.append(tab)
        activeTabId = tab.id
        focusedSessionId = s.id
    }
    func register(_ id: UUID, _ tv: LocalProcessTerminalView) {
        views[id] = tv
    }

    /// Returns the live terminal view for a session, if one is mounted/retained.
    func liveView(_ id: UUID) -> LocalProcessTerminalView? {
        views[id]
    }

    func send(to id: UUID, _ text: String) {
        // Route through the process as user input. `feed()` would inject the
        // text as terminal *output* (never reaching the shell), so `cd` would
        // render but not execute and the cursor state would corrupt.
        views[id]?.send(txt: text)
    }
    func toggleSidebar() {
        sidebarCollapsed.toggle()
    }

    func closeActive() {
        closeFocusedPane()
    }

    /// Close the focused pane. If it is the only pane in the tab, close the
    /// whole tab (or recreate a fresh one when it is the last tab).
    func closeFocusedPane() {
        guard let idx = tabs.firstIndex(where: { $0.id == activeTabId }) else { return }
        let target = focusedSessionId
        var tab = tabs[idx]
        let oldIds = tab.layout.sessionIds
        guard let newLayout = tab.layout.removing(target) else {
            removeSessions(oldIds)
            if tabs.count > 1 {
                tabs.remove(at: idx)
                activeTabId = tabs.last?.id ?? activeTabId
                focusedSessionId = tabs.first(where: { $0.id == activeTabId })?.layout.firstLeaf ?? focusedSessionId
            } else {
                let s = Session(title: "zsh", cwd: startupDirectory, profile: "Local")
                sessions.append(s)
                tab.layout = .terminal(s.id)
                tab.title = "zsh"
                tabs[idx] = tab
                focusedSessionId = s.id
            }
            return
        }
        let removed = oldIds.filter { !newLayout.sessionIds.contains($0) }
        removeSessions(removed)
        tab.layout = newLayout
        tabs[idx] = tab
        // Always pick a valid session from the new layout to avoid stale UUID
        focusedSessionId = newLayout.firstLeaf ?? newLayout.sessionIds.first ?? focusedSessionId
    }

    func closeTab(_ tabId: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        removeSessions(tabs[idx].layout.sessionIds)
        tabs.remove(at: idx)
        if tabs.isEmpty {
            let s = Session(title: "zsh", cwd: startupDirectory, profile: "Local")
            sessions.append(s)
            let tab = WorkspaceTab(title: "zsh", layout: .terminal(s.id))
            tabs.append(tab)
            activeTabId = tab.id
            focusedSessionId = s.id
        } else {
            activeTabId = tabs.last?.id ?? activeTabId
            focusedSessionId = tabs.first(where: { $0.id == activeTabId })?.layout.firstLeaf
                ?? tabs.first(where: { $0.id == activeTabId })?.layout.sessionIds.first
                ?? focusedSessionId
        }
    }
    func renameTab(_ id: UUID, to title: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard let idx = self.tabs.firstIndex(where: { $0.id == id }) else { return }
            self.tabs[idx].title = title
        }
    }

    func setTabColor(_ id: UUID, _ color: NSColor?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard let idx = self.tabs.firstIndex(where: { $0.id == id }) else { return }
            self.tabs[idx].color = color
        }
    }

    /// Called when a shell exits; honors the "close on exit" preference.
    func handleProcessExit(_ id: UUID) {
        guard closeOnExit else { return }
        for i in tabs.indices {
            let oldIds = tabs[i].layout.sessionIds
            guard oldIds.contains(id) else { continue }
            if let newLayout = tabs[i].layout.removing(id) {
                let removed = oldIds.filter { !newLayout.sessionIds.contains($0) }
                removeSessions(removed)
                tabs[i].layout = newLayout
                if focusedSessionId == id {
                    focusedSessionId = newLayout.firstLeaf ?? focusedSessionId
                }
            } else {
                removeSessions(oldIds)
                tabs.remove(at: i)
                if tabs.isEmpty {
                    let s = Session(title: "zsh", cwd: startupDirectory, profile: "Local")
                    sessions.append(s)
                    let tab = WorkspaceTab(title: "zsh", layout: .terminal(s.id))
                    tabs.append(tab)
                    activeTabId = tab.id
                    focusedSessionId = s.id
                } else {
                    activeTabId = tabs.last?.id ?? activeTabId
                    focusedSessionId = tabs.first(where: { $0.id == activeTabId })?.layout.firstLeaf ?? focusedSessionId
                }
            }
            break
        }
    }

    /// Open a file from the sidebar — ALWAYS inside the app (user request:
    /// never hand files off to external applications). Text/code files get
    /// themed syntax highlighting; unknown extensions open as plain text.
    func openFile(_ url: URL) {
        openInEditor(url)
    }

    private func removeSessions(_ ids: [UUID]) {
        for id in ids {
            sessions.removeAll { $0.id == id }
            views[id] = nil
            editorBuffers[id] = nil
        }
    }

    /// Two-way binding to an editor session's text buffer.
    func editorBufferBinding(for id: UUID) -> Binding<EditorBuffer> {
        Binding(
            get: { self.editorBuffers[id] ?? EditorBuffer(content: "", original: "") },
            set: { self.editorBuffers[id] = $0 }
        )
    }

    /// Split the focused pane: replace it with a split holding a fresh
    /// terminal (first child) and the original pane (second child).
    func splitFocused(vertical: Bool) {
        guard let idx = tabs.firstIndex(where: { $0.id == activeTabId }) else { return }
        let oldId = focusedSessionId
        let newSession = Session(title: "zsh",
            cwd: sessions.first(where: { $0.id == oldId })?.cwd ?? startupDirectory,
            profile: "Local")
        sessions.append(newSession)
        let dir: SplitDirection = vertical ? .vertical : .horizontal
        let node = PaneNode.split(id: UUID(), direction: dir,
                                   a: .terminal(newSession.id), b: .terminal(oldId))
        var tab = tabs[idx]
        tab.layout = tab.layout.replacing(oldId, with: node)
        tabs[idx] = tab
        focusedSessionId = newSession.id
    }

    /// Mark a pane as focused (drives ⌘D target, cd, clear, close).
    func focus(_ id: UUID) {
        focusedSessionId = id
    }

    /// Change directory in the active shell by feeding a quoted `cd` command.
    func cd(_ path: String) {
        let id = focusedSessionId
        // Escape backslashes first, then single quotes for shell safety.
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "'\\''")
        let q = "'\(escaped)'"
        send(to: id, "cd \(q)\n")
    }

    /// Open a file in macterm's built-in editor: create an editor session and a new
    /// tab hosting it. The file text is loaded lazily by `EditorView`.
    private func openInEditor(_ url: URL) {
        // Security: limit file size to prevent DoS via large files (10 MB)
        let maxFileSize: Int64 = 10 * 1024 * 1024
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let fileSize = attrs[.size] as? Int64, fileSize > maxFileSize {
            NSSound.beep()
            return
        }
        // Reuse an existing editor tab for the same file (avoids spawning a new
        // tab every time the row is clicked).
        if let existing = sessions.first(where: {
            if case .editor(let f) = $0.kind { return f.standardizedFileURL == url.standardizedFileURL }
            return false
        }), let tab = tabs.first(where: { $0.layout.sessionIds.contains(existing.id) }) {
            activeTabId = tab.id
            focusedSessionId = existing.id
            return
        }
        let title = url.lastPathComponent
        let session = Session(title: title, cwd: url.deletingLastPathComponent().path,
                              profile: "Local", kind: .editor(fileURL: url))
        let loaded = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        editorBuffers[session.id] = EditorBuffer(content: loaded, original: loaded)
        sessions.append(session)
        let tab = WorkspaceTab(title: title, layout: .terminal(session.id))
        tabs.append(tab)
        activeTabId = tab.id
        focusedSessionId = session.id
    }

    func clearActive() {
        let id = focusedSessionId
        send(to: id, "clear\n")
        views[id]?.clearScrollback()
    }
    /// Build the SwiftUI `KeyboardShortcut` for a command id, or `nil` if
    /// unassigned. Space (" ") maps to SwiftUI's `.space` key (leader key).
    func keyboardShortcut(for id: String) -> KeyboardShortcut? {
        guard let b = keyBindings.first(where: { $0.id == id }), !b.key.isEmpty else { return nil }
        let key: KeyEquivalent
        switch b.key {
        case " ":  key = .space
        case "↑":  key = .upArrow
        case "↓":  key = .downArrow
        case "←":  key = .leftArrow
        case "→":  key = .rightArrow
        default:   key = KeyEquivalent(Character(b.key))
        }
        return KeyboardShortcut(key, modifiers: EventModifiers(rawValue: b.modifiers))
    }

    // MARK: - User-defined keybindings

    /// Extra combos the user added in Settings → Keys, each triggering a
    /// built-in command. Dispatched from the menu bar like built-ins.
    var customBindings: [KeyBinding] {
        keyBindings.filter { $0.id.hasPrefix("custom.") }
    }

    func addCustomBinding(action commandId: String, key: String, modifiers: Int) {
        keyBindings.append(KeyBinding(id: "custom.\(UUID().uuidString)",
                                      key: key, modifiers: modifiers, action: commandId))
    }

    func removeCustomBinding(_ id: String) {
        keyBindings.removeAll { $0.id == id }
    }

    /// Display title for any binding — built-in or user-defined.
    func title(for binding: KeyBinding) -> String {
        let actionId = binding.action ?? binding.id
        return TerminalController.commandCatalog.first { $0.id == actionId }?.title ?? actionId
    }

    /// True when two non-empty bindings share the same combo.
    func isConflicting(_ b: KeyBinding) -> Bool {
        guard !b.key.isEmpty else { return false }
        return keyBindings.contains {
            $0.id != b.id && !$0.key.isEmpty
                && $0.key == b.key && $0.modifiers == b.modifiers
        }
    }

    /// Reset the keyboard shortcuts to their defaults.
    func resetKeyBindings() {
        // Keep the user's own custom bindings across a reset of built-ins.
        let customs = customBindings
        keyBindings = TerminalController.defaultKeyBindings() + customs
    }
    // MARK: - Command dispatch (menu bar + keyboard shortcuts)

    /// Execute a catalog command by id. The `.commands` menu and every
    /// rebindable shortcut funnel through here so behavior lives in one place.
    func perform(_ id: String) {
        switch id {
        case "newTab":        newTab()
        case "closePane":     closeActive()
        case "nextTab":       cycleTab(1)
        case "prevTab":       cycleTab(-1)
        case "toggleSidebar": toggleSidebar()
        case "toggleAgentPanel": showAgentPanel.toggle()
        case "clearTerminal": clearActive()
        case "splitRight":    splitFocused(vertical: true)
        case "splitDown":     splitFocused(vertical: false)
        case "focusLeft":     focusNeighbor(.left)
        case "focusRight":    focusNeighbor(.right)
        case "focusUp":       focusNeighbor(.up)
        case "focusDown":     focusNeighbor(.down)
        case "fontBigger":    fontSize = min(fontSize + 1, 24)
        case "fontSmaller":   fontSize = max(fontSize - 1, 8)
        case "fontReset":     fontSize = 13
        case "copy":          NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
        case "paste":         NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
        case "moveTabLeft":   moveTab(-1)
        case "moveTabRight":  moveTab(1)
        case "alternateTab":
            if let alt = tabs.first(where: { $0.id != activeTabId }) { activate(alt) }
        case "newTabInCwd":   newTab(cwd: activeCwd)
        case "focusNextLeaf": cycleLeaf(1)
        case "focusPrevLeaf": cycleLeaf(-1)
        case "zoomPaneToggle": toggleZoom()
        case "closeOtherPanes": closeOtherPanes()
        case "themeCycleNext": cycleTheme(1)
        case "themeCyclePrev": cycleTheme(-1)
        case "reloadFileTree":
            NotificationCenter.default.post(name: .reloadFileTree, object: nil)
        case "toggleMouseReporting": allowMouseReporting.toggle()
        case "toggleOptionAsMeta":   optionAsMetaKey.toggle()
        case "clearScrollbackOnly":
            views[focusedSessionId]?.clearScrollback()
        case "copyActivePath":
            if let cwd = activeCwd {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cwd, forType: .string)
            }
        case "minimizeWindow":
            NSApp.sendAction(#selector(NSWindow.performMiniaturize(_:)), to: nil, from: nil)
        case "toggleDotFiles":
            NotificationCenter.default.post(name: .toggleDotFiles, object: nil)
        case "insertSpecialChar":
            sendSpecialCharacter("")
        case "insertMu":
            sendSpecialCharacter("µ")
        case "insertApprox":
            sendSpecialCharacter("≈")
        case "insertCedilla":
            sendSpecialCharacter("ç")
        case "insertIntegral":
            sendSpecialCharacter("∫")
        case "insertTilde":
            sendSpecialCharacter("~")
        case "insertLessEqual":
            sendSpecialCharacter("≤")
        case "insertPi":
            sendSpecialCharacter("π")
        case "insertBullet":
            sendSpecialCharacter("•")
        case "insertSection":
            sendSpecialCharacter("§")
        case "insertInfinity":
            sendSpecialCharacter("∞")
        case "insertCent":
            sendSpecialCharacter("¢")
        case "insertPound":
            sendSpecialCharacter("£")
        case "editorSave":   saveActiveEditor()
        case "editorRevert": revertActiveEditor()
        case "cut":          NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
        case "selectAll":    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        case "undo":         NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
        case "redo":         NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
        default:
            if id.hasPrefix("goToTab."), let n = Int(id.dropFirst("goToTab.".count)) {
                goToTab(n)
            }
        }
    }

    /// Send a special character to the focused terminal session.
    private func sendSpecialCharacter(_ char: String) {
        send(to: focusedSessionId, char)
    }

    private func cycleTab(_ step: Int) {
        guard let i = tabs.firstIndex(where: { $0.id == activeTabId }), !tabs.isEmpty else { return }
        let next = tabs[(i + step + tabs.count) % tabs.count]
        activate(next)
    }

    func goToTab(_ n: Int) {
        guard tabs.indices.contains(n - 1) else { return }
        activate(tabs[n - 1])
    }

    /// Focus a tab and its first leaf (shared by cycle/go-to/alternate).
    private func activate(_ tab: WorkspaceTab) {
        activeTabId = tab.id
        focusedSessionId = tab.layout.firstLeaf ?? focusedSessionId
    }

    // MARK: - Command implementations

    /// The action a binding triggers (custom bindings carry their own).
    func actionId(for binding: KeyBinding) -> String { binding.action ?? binding.id }

    private func moveTab(_ step: Int) {
        guard let i = tabs.firstIndex(where: { $0.id == activeTabId }) else { return }
        let j = i + step
        guard tabs.indices.contains(j) else { return }
        tabs.swapAt(i, j)
    }

    /// The previously-active tab (`<leader>bb` alternate-buffer analog).
    private var alternateTab: WorkspaceTab? {
        tabs.first { $0.id != activeTabId } // simplest stable pick: first other tab
    }

    private func cycleLeaf(_ step: Int) {
        guard let tab = tabs.first(where: { $0.id == activeTabId }) else { return }
        let leaves = tab.layout.sessionIds
        guard let i = leaves.firstIndex(of: focusedSessionId), leaves.count > 1 else { return }
        focusedSessionId = leaves[(i + step + leaves.count) % leaves.count]
    }

    private func toggleZoom() {
        guard let i = tabs.firstIndex(where: { $0.id == activeTabId }) else { return }
        tabs[i].zoomFocused.toggle()
    }

    /// `<C-w>o` — keep only the focused pane in the active tab.
    private func closeOtherPanes() {
        guard let ti = tabs.firstIndex(where: { $0.id == activeTabId }),
              focusedSessionId == tabs[ti].layout.firstLeaf else { return }
        let others = tabs[ti].layout.sessionIds.filter { $0 != focusedSessionId }
        guard !others.isEmpty else { return }
        removeSessions(others)
        tabs[ti].layout = .terminal(focusedSessionId)
        tabs[ti].zoomFocused = false
    }

    private func cycleTheme(_ step: Int) {
        let slugs = AppTheme.all.map(\.slug)
        guard let i = slugs.firstIndex(of: themeName) else { return }
        themeName = slugs[(i + step + slugs.count) % slugs.count]
    }

    /// Write the focused editor session's buffer back to disk.
    func saveActiveEditor() {
        guard let s = sessions.first(where: { $0.id == focusedSessionId }),
              case .editor(let url) = s.kind,
              var buf = editorBuffers[s.id] else { return }
        do {
            try buf.content.write(to: url, atomically: true, encoding: .utf8)
            buf.original = buf.content
            editorBuffers[s.id] = buf
        } catch {
            NSSound.beep()
        }
    }

    /// Reload the focused editor file from disk.
    func revertActiveEditor() {
        guard let s = sessions.first(where: { $0.id == focusedSessionId }),
              case .editor(let url) = s.kind else { return }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        editorBuffers[s.id] = EditorBuffer(content: text, original: text)
    }
    enum FocusDirection { case left, right, up, down }

    /// Move focus across the split tree using arrow-style h/j/k/l: cross the
    /// deepest split that separates the focused pane from the target side,
    /// then land on the sibling leaf nearest the shared edge.
    func focusNeighbor(_ dir: FocusDirection) {
        guard let tab = tabs.first(where: { $0.id == activeTabId }) else { return }
        // Path of (split node, entered child a?) from root down to the leaf.
        func walk(_ node: PaneNode, _ acc: [(PaneNode, Bool)]) -> [(PaneNode, Bool)]? {
            switch node {
            case .terminal(let s):
                return s == focusedSessionId ? acc : nil
            case .split(_, _, let a, let b):
                if let p = walk(a, acc + [(node, true)]) { return p }
                return walk(b, acc + [(node, false)])
            }
        }
        guard let path = walk(tab.layout, []) else { return }

        // vertical = side-by-side (separates left/right); horizontal = stacked.
        func separates(_ d: SplitDirection) -> Bool {
            switch (d, dir) {
            case (.vertical, .left), (.vertical, .right),
                 (.horizontal, .up), (.horizontal, .down):
                return true
            default:
                return false
            }
        }
        // Deepest ancestor whose split can move us toward `dir`.
        for (split, enteredA) in path.reversed() {
            guard case .split(_, let d, let a, let b) = split, separates(d) else { continue }
            let back = (dir == .left || dir == .up)
            if enteredA && !back { focusExtreme(b, toward: dir); return }
            if !enteredA && back { focusExtreme(a, toward: dir); return }
        }
    }

    /// Descend into `node` and focus the leaf nearest the edge implied by `dir`
    /// (the pane that shares a border with where we came from).
    /// Note: For complex/uneven split trees, this finds the extreme leaf on the
    /// sibling side, which may not be the visually adjacent pane in all layouts.
    /// A full fix would require tracking visual geometry (frame rectangles).
    private func focusExtreme(_ node: PaneNode, toward dir: FocusDirection) {
        var cur = node
        while case .split(_, let d, let a, let b) = cur {
            switch (d, dir) {
            case (.vertical, .left), (.horizontal, .up):
                cur = b                                  // right/bottom-most leaf
            case (.vertical, .right), (.horizontal, .down):
                cur = a                                  // left/top-most leaf
            default:
                // Split axis doesn't match movement axis (e.g., horizontal split
                // but moving left/right). Pick the child that spans the movement
                // direction visually. For now, pick the first child as fallback.
                cur = a
            }
        }
        if case .terminal(let s) = cur { focusedSessionId = s }
    }

    func setTitle(_ id: UUID, _ title: String) {
        guard !title.isEmpty else { return }
        if let i = sessions.firstIndex(where: { $0.id == id }), sessions[i].title != title {
            sessions[i].title = title
        }
    }

    func setCwd(_ id: UUID, _ cwd: String?) {
        if let i = sessions.firstIndex(where: { $0.id == id }), sessions[i].cwd != cwd {
            sessions[i].cwd = cwd
        }
    }

    /// Rename a tab (custom rename from the tab context menu).
    func rename(_ id: UUID, _ name: String) {
        let t = name.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        if let i = sessions.firstIndex(where: { $0.id == id }) {
            sessions[i].title = t
        }
    }

    /// Set a tab's accent color (nil = default, no accent).
    func setColor(_ id: UUID, _ color: NSColor?) {
        if let i = sessions.firstIndex(where: { $0.id == id }) {
            sessions[i].color = color
        }
    }

    deinit {
    }
}

/// Per-theme user color overrides (hex strings, missing = use theme default).
private struct ColorOverride: Codable {
    var bg: String?
    var fg: String?
    var caret: String?
    var selection: String?
    var isEmpty: Bool { bg == nil && fg == nil && caret == nil && selection == nil }
}

extension NSColor {
    /// `#RRGGBB` representation in the sRGB space.
    func hexString() -> String {
        let c = usingColorSpace(.sRGB) ?? self
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: nil)
        return String(format: "%02X%02X%02X",
                      Int(r * 255), Int(g * 255), Int(b * 255))
    }
    convenience init?(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s = String(s.dropFirst()) }
        guard s.count == 6, let v = UInt(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                  green: CGFloat((v >> 8) & 0xff) / 255,
                  blue: CGFloat(v & 0xff) / 255,
                  alpha: 1)
    }
}

/// Directory pinned as a project from the sidebar tree.
struct SidebarProject: Identifiable, Codable {
    let id: UUID
    var path: String
    var name: String
    var colorHex: String
}

/// Saved SSH connection (persisted). Passwords are intentionally NOT stored —
/// `ssh` prompts interactively inside the terminal pty, so auth uses keys or a
/// live password prompt.
struct SSHConnection: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var host: String
    var user: String
    var port: Int
    var identityFile: String?
}

