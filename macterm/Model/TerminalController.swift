import Foundation
import SwiftTerm
import SwiftUI
import AppKit

/// App-wide state: the tab set, the active tab, sidebar visibility, the
/// favorite roots, the full terminal appearance/behavior settings (persisted to
/// `UserDefaults`), and a registry of live `LocalProcessTerminalView`s so the
/// sidebar can drive input (cd / paste path) into the right pty.
/// A user-rebindable keyboard shortcut for an app command.
struct KeyBinding: Codable, Equatable, Identifiable {
    let id: String
    /// Single lowercase character (e.g. "t"); "" means unassigned.
    var key: String
    /// SwiftUI `EventModifiers` raw value.
    var modifiers: Int

    init(id: String, key: String, modifiers: Int) {
        self.id = id
        self.key = key
        self.modifiers = modifiers
    }
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
}

/// One top-level tab: a self-contained split tree.
struct WorkspaceTab: Identifiable {
    let id = UUID()
    var title: String
    var layout: PaneNode
    /// Optional accent color shown as a dot on the tab pill.
    var color: NSColor? = nil
}

/// In-memory text buffer backing an in-app editor session. Stored in
/// `TerminalController.editorBuffers` keyed by `Session.id` so each editor tab
/// owns its content (and unsaved edits) independently of the mounted view —
/// fixes the bug where switching tabs reused one view's `@State`.
struct EditorBuffer {
    var content: String
    var original: String
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

    /// Per-editor-session text buffers, keyed by `Session.id`. Lives in the
    /// model (not the view) so switching tabs preserves each file's content.
    @Published var editorBuffers: [UUID: EditorBuffer] = [:]

    // MARK: - Appearance
    /// Active base theme name (bg/fg/caret/selection + ANSI palette derive from it,
    /// optionally overridden per theme by the user in Settings).
    @Published var themeName: String = "Midnight" { didSet { persist() } }
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
    /// Rebindable keyboard shortcuts for app commands (persisted).
    @Published var keyBindings: [KeyBinding] = TerminalController.defaultKeyBindings() { didSet { persist() } }


    // MARK: - Per-theme color overrides (user-tuned), persisted as JSON.
    @Published private var overrides: [String: ColorOverride] = [:]

    let favorites: [URL] = [
        FileManager.default.homeDirectoryForCurrentUser
    ]

    private var views: [UUID: LocalProcessTerminalView] = [:]

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

    /// A terminal theme: base bg/fg plus caret + selection accents.
    struct TerminalTheme: Identifiable {
        let id = UUID()
        let name: String
        let bg: NSColor
        let fg: NSColor
        let caret: NSColor
        let selection: NSColor
    }

    static let themes: [TerminalTheme] = [
        TerminalTheme(name: "Midnight",
            bg: NSColor(srgbRed: 0.043, green: 0.055, blue: 0.078, alpha: 1),
            fg: NSColor(srgbRed: 0.773, green: 0.784, blue: 0.776, alpha: 1),
            caret: NSColor(srgbRed: 0.773, green: 0.784, blue: 0.776, alpha: 1),
            selection: NSColor(srgbRed: 0.227, green: 0.290, blue: 0.420, alpha: 1)),
        TerminalTheme(name: "Tokyo Night",
            bg: NSColor(srgbRed: 0.102, green: 0.106, blue: 0.149, alpha: 1),
            fg: NSColor(srgbRed: 0.753, green: 0.792, blue: 0.961, alpha: 1),
            caret: NSColor(srgbRed: 0.796, green: 0.855, blue: 0.969, alpha: 1),
            selection: NSColor(srgbRed: 0.231, green: 0.259, blue: 0.427, alpha: 1)),
        TerminalTheme(name: "One Dark",
            bg: NSColor(srgbRed: 0.157, green: 0.173, blue: 0.204, alpha: 1),
            fg: NSColor(srgbRed: 0.671, green: 0.698, blue: 0.749, alpha: 1),
            caret: NSColor(srgbRed: 0.671, green: 0.698, blue: 0.749, alpha: 1),
            selection: NSColor(srgbRed: 0.243, green: 0.267, blue: 0.322, alpha: 1)),
        TerminalTheme(name: "Carbon",
            bg: NSColor(srgbRed: 0.051, green: 0.051, blue: 0.051, alpha: 1),
            fg: NSColor(srgbRed: 0.839, green: 0.839, blue: 0.839, alpha: 1),
            caret: NSColor(srgbRed: 0.839, green: 0.839, blue: 0.839, alpha: 1),
            selection: NSColor(srgbRed: 0.290, green: 0.290, blue: 0.290, alpha: 1))
    ]
    static let themeNames: [String] = themes.map { $0.name }

    /// Coordinated 16-color ANSI palette (Dracula) — drives `installColors`.
    static let ansiPalette: [SwiftTerm.Color] = [
        SwiftTerm.Color(red8: 33, green8: 34, blue8: 44),
        SwiftTerm.Color(red8: 255, green8: 85, blue8: 85),
        SwiftTerm.Color(red8: 80, green8: 250, blue8: 123),
        SwiftTerm.Color(red8: 241, green8: 250, blue8: 140),
        SwiftTerm.Color(red8: 189, green8: 147, blue8: 249),
        SwiftTerm.Color(red8: 255, green8: 121, blue8: 198),
        SwiftTerm.Color(red8: 139, green8: 233, blue8: 253),
        SwiftTerm.Color(red8: 248, green8: 248, blue8: 242),
        SwiftTerm.Color(red8: 98, green8: 114, blue8: 164),
        SwiftTerm.Color(red8: 255, green8: 110, blue8: 110),
        SwiftTerm.Color(red8: 105, green8: 255, blue8: 148),
        SwiftTerm.Color(red8: 255, green8: 255, blue8: 165),
        SwiftTerm.Color(red8: 214, green8: 172, blue8: 255),
        SwiftTerm.Color(red8: 255, green8: 146, blue8: 223),
        SwiftTerm.Color(red8: 164, green8: 255, blue8: 255),
        SwiftTerm.Color(red8: 255, green8: 255, blue8: 255)
    ]

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
    var font: NSFont {
        NSFont(name: fontName, size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }
    /// Background with the user's opacity applied (drives glass).
    var backgroundColor: NSColor { effectiveColor(.bg).withAlphaComponent(backgroundAlpha) }
    /// Convenience: higher value = more transparent / more frosted terminal.
    var terminalTransparency: Double {
        get { 1.0 - backgroundAlpha }
        set { backgroundAlpha = 1.0 - newValue }
    }
    var foregroundColor: NSColor { effectiveColor(.fg) }
    var caretColor: NSColor { effectiveColor(.caret) }
    var selectionColor: NSColor { effectiveColor(.selection).withAlphaComponent(0.45) }
    var ansiColors: [SwiftTerm.Color] { Self.ansiPalette }
    /// Cheap signature of every *live-applied* setting, so the view can skip
    /// redundant re-application on unrelated `@Published` changes.
    var appearanceSignature: String {
        let ov = overrides[themeName].map { "\($0.bg ?? "")\($0.fg ?? "")\($0.caret ?? "")\($0.selection ?? "")" } ?? ""
        return "\(fontName)|\(fontSize)|\(themeName)|\(backgroundAlpha)|"
            + "\(optionAsMetaKey)|\(allowMouseReporting)|\(backspaceSendsControlH)|\(useBrightColors)|"
            + "\(cursorShapeRaw)|\(cursorBlink)|\(ansi256Raw)|\(ov)"
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

    // MARK: - Color overrides (per theme)
    enum OverrideKey { case bg, fg, caret, selection }

    func effectiveColor(_ key: OverrideKey) -> NSColor {
        let theme = Self.themes.first(where: { $0.name == themeName }) ?? Self.themes[0]
        guard let ov = overrides[themeName] else { return themeColor(theme, key) }
        let hex: String?
        switch key {
        case .bg:        hex = ov.bg
        case .fg:        hex = ov.fg
        case .caret:     hex = ov.caret
        case .selection: hex = ov.selection
        }
        return NSColor(hex: hex ?? "") ?? themeColor(theme, key)
    }

    private func themeColor(_ t: TerminalTheme, _ key: OverrideKey) -> NSColor {
        switch key {
        case .bg:        return t.bg
        case .fg:        return t.fg
        case .caret:     return t.caret
        case .selection: return t.selection
        }
    }

    func setOverride(_ key: OverrideKey, _ color: NSColor?) {
        var set = overrides[themeName] ?? ColorOverride()
        switch key {
        case .bg:        set.bg = color?.hexString()
        case .fg:        set.fg = color?.hexString()
        case .caret:     set.caret = color?.hexString()
        case .selection: set.selection = color?.hexString()
        }
        if set.isEmpty { overrides.removeValue(forKey: themeName) }
        else { overrides[themeName] = set }
        saveOverrides()
        objectWillChange.send()
    }

    func resetColors() {
        overrides.removeValue(forKey: themeName)
        saveOverrides()
        objectWillChange.send()
    }

    private func saveOverrides() {
        if let data = try? JSONEncoder().encode(overrides) {
            UserDefaults.standard.set(data, forKey: "colorOverrides")
        }
    }

    // MARK: - Init / persistence
    init() {
        restore()
        let first = Session(title: "zsh", cwd: startupDirectory, profile: "Local")
        sessions = [first]
        let tab = WorkspaceTab(title: "zsh", layout: .terminal(first.id))
        tabs = [tab]
        activeTabId = tab.id
        focusedSessionId = first.id
    }
    static func defaultKeyBindings() -> [KeyBinding] {
        [
            KeyBinding(id: "newTab",       key: "t", modifiers: Int(EventModifiers.command.rawValue)),
            KeyBinding(id: "closeTab",      key: "w", modifiers: Int(EventModifiers.command.rawValue)),
            KeyBinding(id: "toggleSidebar", key: "s", modifiers: Int(EventModifiers([.command, .shift]).rawValue)),
            KeyBinding(id: "clear",         key: "k", modifiers: Int(EventModifiers.command.rawValue)),
        ]
    }


    private func restore() {
        let d = UserDefaults.standard
        themeName              = d.string(forKey: "themeName") ?? themeName
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
        sidebarWidth           = d.object(forKey: "sidebarWidth") as? Double ?? sidebarWidth
        terminalPadding        = d.object(forKey: "terminalPadding2") as? Double ?? terminalPadding
        if let data = d.data(forKey: "colorOverrides"),
           let dec = try? JSONDecoder().decode([String: ColorOverride].self, from: data) {
            overrides = dec
        }
        if let data = d.data(forKey: "keyBindings"),
           let dec = try? JSONDecoder().decode([KeyBinding].self, from: data), !dec.isEmpty {
            keyBindings = dec
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
        d.set(sidebarWidth, forKey: "sidebarWidth")
        d.set(terminalPadding, forKey: "terminalPadding2")
        if let data = try? JSONEncoder().encode(keyBindings) {
            d.set(data, forKey: "keyBindings")
        }
    }

    func resetAllSettings() {
        let d = UserDefaults.standard
        for k in ["themeName","backgroundAlpha","fontName","fontSize","cursorShapeRaw","cursorBlink",
                  "useBrightColors","scrollback","optionAsMetaKey","allowMouseReporting",
                  "backspaceSendsControlH","ansi256Raw","shellPath","startupDirRaw","closeOnExit",
                  "sidebarCollapsed","sidebarWidth","terminalPadding2","colorOverrides","keyBindings"] {
            d.removeObject(forKey: k)
        }
        overrides = [:]
        restore()
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
        focusedSessionId = newLayout.firstLeaf ?? focusedSessionId
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
            focusedSessionId = tabs.first(where: { $0.id == activeTabId })?.layout.firstLeaf ?? focusedSessionId
        }
    }
    func renameTab(_ id: UUID, to title: String) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[idx].title = title
    }

    func setTabColor(_ id: UUID, _ color: NSColor?) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[idx].color = color
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
        let q = "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
        send(to: id, "cd \(q)\n")
    }
    /// Open a file from the sidebar. Text/source files open in macterm's built-in
    /// editor (a new tab). Non-text files (images, PDFs, binaries, …) open in their
    /// system default app instead — never forced through a terminal editor.
    func openFile(_ url: URL) {
        if Self.isEditable(url) {
            openInEditor(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Files we can reasonably edit in the built-in text editor (text/code).
    private static let editableExtensions: Set<String> = [
        "txt","text","md","markdown","mkd","swift","py","pyw","js","mjs","cjs","ts","tsx","jsx",
        "json","yaml","yml","toml","ini","cfg","conf","editorconfig","gitignore","gitattributes",
        "sh","zsh","bash","fish","c","h","cc","cpp","cxx","hpp","hxx","m","mm","java","kt","kts",
        "go","rs","rb","php","pl","pm","lua","sql","html","htm","xhtml","css","scss","sass","less",
        "xml","svg","csv","tsv","log","env","properties","gradle","plist","strings","r","dart",
        "vue","svelte","tf","tfvars","lock","diff","patch","rst","adoc","asciidoc","tex"
    ]

    private static func isEditable(_ url: URL) -> Bool {
        editableExtensions.contains(url.pathExtension.lowercased())
    }

    /// Open a file in macterm's built-in editor: create an editor session and a new
    /// tab hosting it. The file text is loaded lazily by `EditorView`.
    private func openInEditor(_ url: URL) {
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
    /// unassigned. Used by the app's `.commands` so shortcuts honor user rebinds.
    func keyboardShortcut(for id: String) -> KeyboardShortcut? {
        guard let b = keyBindings.first(where: { $0.id == id }), !b.key.isEmpty else { return nil }
        return KeyboardShortcut(KeyEquivalent(Character(b.key)),
                               modifiers: EventModifiers(rawValue: b.modifiers))
    }

    /// Reset the keyboard shortcuts to their defaults.
    func resetKeyBindings() {
        keyBindings = TerminalController.defaultKeyBindings()
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
