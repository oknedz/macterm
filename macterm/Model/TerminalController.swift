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

/// One rebindable app command. The catalog below is the SINGLE source of
/// truth: it feeds the default keybindings, the Shortcuts settings pane and
/// the menu bar, so all three always agree.
struct CommandSpec: Identifiable {
    let id: String
    let group: String
    let title: String
    /// The NvChad/neovim mapping this command mirrors (shown as a caption).
    let nvim: String
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
    /// Active NvChad/base46 theme slug ("onedark"). All terminal colors, the
    /// editor palette and the app's dark/light appearance derive from it.
    @Published var themeName: String = AppTheme.defaultSlug { didSet { persist() } }
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
    var theme: AppTheme { AppTheme.bySlug(themeName) ?? AppTheme.bySlug(AppTheme.defaultSlug)! }
    var isDarkTheme: Bool { theme.isDark }
    var accentColor: NSColor { theme.accent }

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
        // Tabs (nvim tabufline)
        CommandSpec(id: "newTab",       group: "Tabs",   title: "New Tab",            nvim: "<leader>b / :enew", key: "t", mods: .command),
        CommandSpec(id: "nextTab",      group: "Tabs",   title: "Next Tab",           nvim: "<Tab>     buf next", key: "]", mods: [.command, .shift]),
        CommandSpec(id: "prevTab",      group: "Tabs",   title: "Previous Tab",       nvim: "<S-Tab>   buf prev", key: "[", mods: [.command, .shift]),
        CommandSpec(id: "closePane",    group: "Tabs",   title: "Close Pane / Tab",   nvim: "<leader>x buf close", key: "w", mods: .command),

        // Panes (nvim <C-w> window family)
        CommandSpec(id: "splitRight",   group: "Panes",  title: "Split Right",        nvim: "<C-w>v", key: "d", mods: .command),
        CommandSpec(id: "splitDown",    group: "Panes",  title: "Split Down",         nvim: "<C-w>s", key: "d", mods: [.command, .shift]),
        CommandSpec(id: "focusLeft",    group: "Panes",  title: "Focus Pane Left",    nvim: "<C-w>h", key: "h", mods: [.control, .option]),
        CommandSpec(id: "focusDown",    group: "Panes",  title: "Focus Pane Below",   nvim: "<C-w>j", key: "j", mods: [.control, .option]),
        CommandSpec(id: "focusUp",      group: "Panes",  title: "Focus Pane Above",   nvim: "<C-w>k", key: "k", mods: [.control, .option]),
        CommandSpec(id: "focusRight",   group: "Panes",  title: "Focus Pane Right",   nvim: "<C-w>l", key: "l", mods: [.control, .option]),

        // View / UI
        CommandSpec(id: "toggleSidebar",group: "View",   title: "Toggle Sidebar",     nvim: "<C-n>   NvimTreeToggle", key: "s", mods: [.command, .shift]),
        CommandSpec(id: "clearTerminal",group: "View",   title: "Clear Terminal",     nvim: "<C-l>   clear", key: "k", mods: .command),
        CommandSpec(id: "fontBigger",   group: "View",   title: "Font Size Up",       nvim: "", key: "=", mods: .command),
        CommandSpec(id: "fontSmaller",  group: "View",   title: "Font Size Down",     nvim: "", key: "-", mods: .command),
        CommandSpec(id: "fontReset",    group: "View",   title: "Reset Font Size",    nvim: "", key: "0", mods: .command),

        // Edit
        CommandSpec(id: "copy",         group: "Edit",   title: "Copy",               nvim: "<C-c>   %y+", key: "c", mods: .command),
        CommandSpec(id: "paste",        group: "Edit",   title: "Paste",              nvim: "p       \"+p", key: "v", mods: .command),

        // Go to tab ({n}gt)
    ] + (1...9).map { n in
        CommandSpec(id: "goToTab.\(n)", group: "Go to Tab",
                    title: "Go to Tab \(n)", nvim: "\(n)gt",
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
        sidebarWidth           = d.object(forKey: "sidebarWidth") as? Double ?? sidebarWidth
        terminalPadding        = d.object(forKey: "terminalPadding2") as? Double ?? terminalPadding
        if let data = d.data(forKey: "keyBindings"),
           let dec = try? JSONDecoder().decode([KeyBinding].self, from: data), !dec.isEmpty {
            // Merge: keep the user's saved bindings, add defaults for catalog
            // entries that didn't exist when they were saved.
            let have = Set(dec.map(\.id))
            keyBindings = dec + Self.commandCatalog
                .filter { !have.contains($0.id) }
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
        case "copy":          NSApp.sendAction(Selector(("copy:")), to: nil, from: nil)
        case "paste":         NSApp.sendAction(Selector(("paste:")), to: nil, from: nil)
        default:
            if id.hasPrefix("goToTab."), let n = Int(id.dropFirst("goToTab.".count)) {
                goToTab(n)
            }
        }
    }

    private func cycleTab(_ step: Int) {
        guard let i = tabs.firstIndex(where: { $0.id == activeTabId }), !tabs.isEmpty else { return }
        let next = tabs[(i + step + tabs.count) % tabs.count]
        activate(next)
    }

    private func goToTab(_ n: Int) {
        guard tabs.indices.contains(n - 1) else { return }
        activate(tabs[n - 1])
    }

    private func activate(_ tab: WorkspaceTab) {
        activeTabId = tab.id
        focusedSessionId = tab.layout.firstLeaf ?? focusedSessionId
    }

    enum FocusDirection { case left, right, up, down }

    /// Move focus across the split tree like nvim's `<C-w>h/j/k/l`: cross the
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
    private func focusExtreme(_ node: PaneNode, toward dir: FocusDirection) {
        var cur = node
        while case .split(_, let d, let a, let b) = cur {
            switch (d, dir) {
            case (.vertical, .left), (.horizontal, .up):
                cur = b                                  // right/bottom-most leaf
            case (.vertical, .right), (.horizontal, .down):
                cur = a                                  // left/top-most leaf
            default:
                cur = a                                  // axis-agnostic: either side spans it
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
