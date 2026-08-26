import SwiftUI
import SwiftTerm
import Foundation
import AppKit

/// Bridges SwiftTerm's AppKit `LocalProcessTerminalView` into SwiftUI.
/// One instance is kept mounted per session (toggle visibility with opacity,
/// never unmount) so the pty survives tab switches and keeps a correct size.
struct TerminalViewRepresentable: NSViewRepresentable {
    let sessionId: UUID
    @ObservedObject var controller: TerminalController

    func makeCoordinator() -> Coordinator {
        Coordinator(sessionId: sessionId, controller: controller)
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        // Recycle a retained view for this session (if any) so its pty,
        // scrollback, and cwd survive being unmounted by a tab switch.
        if let existing = controller.liveView(sessionId) as? ResizableTerminalView {
            existing.processDelegate = context.coordinator
            existing.controller = controller
            existing.sessionId = sessionId
            return existing
        }
        // Pass engine options (scrollback, cursor style, ANSI strategy) at creation.
        let tv = ResizableTerminalView(frame: .zero, font: controller.font,
                                           options: controller.terminalOptions())
        tv.wantsLayer = true
        // Keep the terminal transparent: the layer respects backgroundAlpha.
        // Ghosting during live resize is prevented by discarding the backing
        // store and redrawing each resize step (preservesContentDuringLiveResize
        // = false) instead of forcing the layer opaque, which would kill
        // per-pixel alpha and paint a dark band at the view's trailing edge.
        tv.layer?.isOpaque = controller.backgroundAlpha >= 1
        tv.layer?.backgroundColor = controller.backgroundColor.cgColor
        applyAppearance(tv)
        tv.processDelegate = context.coordinator
        tv.controller = controller
        tv.sessionId = sessionId
        let shell = controller.shellPath
        let cwd = controller.sessions.first(where: { $0.id == sessionId })?.cwd
        tv.startProcess(executable: shell, args: ["-l"], environment: nil, execName: nil, currentDirectory: cwd)

        controller.register(sessionId, tv)
        context.coordinator.applied = controller.appearanceSignature
        return tv
    }

    /// Push every live appearance/behavior setting onto the view. Cheap and
    /// idempotent, so it is safe to call on every SwiftUI update.
    private func applyAppearance(_ tv: LocalProcessTerminalView) {
        tv.font = controller.font
        tv.nativeForegroundColor = controller.foregroundColor
        tv.nativeBackgroundColor = controller.backgroundColor
        tv.caretColor = controller.caretColor
        tv.setCursorStyle(controller.cursorStyle)
        tv.selectedTextBackgroundColor = controller.selectionColor
        tv.optionAsMetaKey = controller.optionAsMetaKey
        tv.allowMouseReporting = controller.allowMouseReporting
        tv.backspaceSendsControlH = controller.backspaceSendsControlH
        tv.useBrightColors = controller.useBrightColors
        tv.ansi256PaletteStrategy = controller.ansi256Strategy
        tv.installColors(controller.ansiColors)
        tv.layer?.isOpaque = controller.backgroundAlpha >= 1
        tv.layer?.backgroundColor = controller.backgroundColor.cgColor
    }


    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // Re-apply only when a relevant setting changed (coordinator tracks a
        // signature) to avoid redundant palette installs on unrelated updates.
        let sig = controller.appearanceSignature
        guard context.coordinator.applied != sig else { return }
        applyAppearance(nsView)
        context.coordinator.applied = sig
    }

    @MainActor
    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let sessionId: UUID
        let controller: TerminalController
        /// Signature of the appearance settings last applied to the view.
        var applied: String = ""

        init(sessionId: UUID, controller: TerminalController) {
            self.sessionId = sessionId
            self.controller = controller
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            if !title.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.controller.setTitle(self.sessionId, title)
                }
            }
        }
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.controller.setCwd(self.sessionId, directory)
            }
        }
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.controller.handleProcessExit(self.sessionId)
            }
        }
    }
}

/// Terminal view that (1) debounces resize propagation to the child pty so a
/// live window drag doesn't flood SIGWINCH (~60/s) and make zsh/Powerlevel10k
/// reprint the prompt on every frame, and (2) intercepts the "clear" shortcut
/// at the key level so ⌘K wipes both the screen and the scrollback, like
/// native Terminal/iTerm2.
final class ResizableTerminalView: LocalProcessTerminalView {
    weak var controller: TerminalController?

    /// Report no intrinsic content size so SwiftUI `HSplitView`/`VSplitView`
    /// treat the pane as fully flexible and divide space equally, instead of
    /// honoring SwiftTerm's content-derived (rows×cols) intrinsic size — which
    /// otherwise shrinks freshly-created panes inside a nested split.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
    /// Don't preserve the view's bitmap during live resize — AppKit redraws
    /// from a clean backing store each step, which prevents SwiftTerm's
    /// throttled redraws from stacking ghosted prompt lines. (Overridden rather
    /// than assigned: SwiftTerm exposes it as a get-only property.)
    override var preservesContentDuringLiveResize: Bool { false }
    var sessionId: UUID?
    private static let resizeDebounce: TimeInterval = 0.06
    private var pendingSize: CGSize?
    private var timer: Timer?

    override func setFrameSize(_ newSize: NSSize) {
        pendingSize = newSize
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.resizeDebounce, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.timer = nil
            guard let size = self.pendingSize else { return }
            self.applyPendingSize(size)
        }
    }

    private func applyPendingSize(_ size: CGSize) {
        super.setFrameSize(size)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // View level runs BEFORE menu processing, so terminal-scoped commands
        // win even when system items share the combo (e.g. ⌘W vs Close Window).
        let hit: KeyBinding? = MainActor.assumeIsolated {
            controller?.keyBindings.first(where: { bindingMatches(event, $0) })
        }
        guard let binding = hit else { return super.performKeyEquivalent(with: event) }
        let actionId: String = MainActor.assumeIsolated {
            controller?.actionId(for: binding) ?? binding.id
        }
        switch actionId {
        case "clearTerminal", "clearScrollbackOnly":
            MainActor.assumeIsolated {
                if actionId == "clearTerminal" { send(txt: "clear\n") }
                clearScrollback()
            }
            return true
        case "closePane":
            MainActor.assumeIsolated { controller?.closeFocusedPane() }
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        // ⌘-click on a name in the OUTPUT (ls results, prompt paths…):
        // resolve it against the session cwd and type the quoted absolute
        // path at the cursor — lands right after a typed `cd `. Consumed so
        // it does not start a selection drag. Plain clicks: focus + normal.
        if event.modifierFlags.contains(.command),
           let hit = hitTestCell(at: event.locationInWindow),
           let word = pathWord(at: hit.col, in: hit.lineText),
           let resolved = resolvedPath(word) {
            send(txt: " '\(resolved)'")
            return
        }
        MainActor.assumeIsolated {
            if let id = sessionId { controller?.focus(id) }
        }
        super.mouseDown(with: event)
    }

    /// Expand the word under `col` over path-ish characters.
    private func pathWord(at col: Int, in line: String) -> String? {
        let allowed: Set<Character> = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-~/")
        let chars = Array(line)
        guard col < chars.count, allowed.contains(chars[col]) else { return nil }
        var start = col, end = col
        while start > 0, allowed.contains(chars[start - 1]) { start -= 1 }
        while end + 1 < chars.count, allowed.contains(chars[end + 1]) { end += 1 }
        let word = String(chars[start...end])
        return word.count > 1 ? word : nil
    }

    /// Resolve a word from the screen to an existing absolute path
    /// (absolute, ~-prefixed, or relative to the session's cwd).
    private func resolvedPath(_ word: String) -> String? {
        let url: URL
        if word.hasPrefix("/") {
            url = URL(fileURLWithPath: word)
        } else if word.hasPrefix("~") {
            url = URL(fileURLWithPath: NSString(string: word).expandingTildeInPath)
        } else {
            let cwd = MainActor.assumeIsolated { controller?.activeCwd } ?? NSHomeDirectory()
            url = URL(fileURLWithPath: cwd).appendingPathComponent(word)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        return url.path
    }

    /// Clears the visible screen and the SwiftTerm scrollback so ⌘K behaves
    /// like native Terminal/iTerm2 (no scroll-back into old output).
    func clearTerminalScreen() {
        send(txt: "clear\n")
        clearScrollback()
    }

    private func bindingMatches(_ event: NSEvent, _ binding: KeyBinding) -> Bool {
        guard !binding.key.isEmpty else { return false }
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        guard chars == binding.key else { return false }
        let f = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let want = EventModifiers(rawValue: binding.modifiers)
        return f.contains(.command) == want.contains(.command)
            && f.contains(.shift) == want.contains(.shift)
            && f.contains(.option) == want.contains(.option)
            && f.contains(.control) == want.contains(.control)
    }

    deinit { timer?.invalidate() }
}
