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
        controller.register(sessionId, tv)
        let session = controller.sessions.first(where: { $0.id == sessionId })
        if let ssh = session?.ssh {
            var args = [ssh.user + "@" + ssh.host]
            if ssh.port != 22 { args += ["-p", "\(ssh.port)"] }
            if let idFile = ssh.identityFile, !idFile.isEmpty { args += ["-i", idFile] }
            tv.startProcess(executable: "/usr/bin/ssh", args: args, environment: nil, execName: nil, currentDirectory: nil)
        } else {
            let shell = controller.shellPath
            let cwd = session?.cwd
            tv.startProcess(executable: shell, args: ["-l"], environment: nil, execName: nil, currentDirectory: cwd)
        }
        // TR2/TR3: begin best-effort Neovim-background monitoring for this pty.
        tv.startNvimMonitor()
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
    private static let resizeDebounce: TimeInterval = 0.1
    private var pendingSize: CGSize?
    /// Last size actually delivered to the pty. Resizes are only forwarded
    /// when the size genuinely changes, so a sidebar toggle / window resize
    /// emits at most one SIGWINCH instead of one per spring-overshoot frame
    /// (each redundant SIGWINCH makes the shell's prompt theme reprint).
    private var lastDeliveredSize: CGSize = .zero
    /// True while AppKit is animating a live resize (drag-to-resize).
    /// SwiftTerm's draw path feeds the current screen content into the
    /// NSTextStorage on every redraw; during a drag AppKit issues many
    /// draws, each appending the prompt and stacking visible duplicates
    /// (`~/MacTerm/macterm` printed 4× while dragging). Skipping draw
    /// during the drag freezes the on-screen content; the debounced
    /// `applyPendingSize` then re-flows the (single) prompt on release.
    private var inLiveDrag = false
    // TR2/TR3: best-effort Neovim detection. `nvimShellPid` is captured once on
    // the main thread at monitor start; the polling itself runs on `nvimQueue`
    // so the `ps` spawn + tree walk never blocks terminal I/O on the main
    // thread (TR3). When nvim is detected we pin the layer background to the
    // team-wide color (see pollNvim); otherwise applyAppearance's value stands.
    private var nvimShellPid: pid_t = 0
    private var nvimMonitorTimer: DispatchSourceTimer?
    private let nvimPollInterval: TimeInterval = 1.5
    private var nvimActive = false
    private let nvimQueue = DispatchQueue(label: "com.macterm.nvimdetect", qos: .utility)

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        inLiveDrag = true
    }

    override func viewDidEndLiveResize() {
        inLiveDrag = false
        super.viewDidEndLiveResize()
        // Force one full redraw at the new size so the previously-frozen
        // content re-flows cleanly instead of looking stale.
        if let size = pendingSize { applyPendingSize(size) }
        needsDisplay = true
    }

    private var timer: Timer?

    override func setFrameSize(_ newSize: NSSize) {
        // Ignore changes smaller than half a point — SwiftUI's spring
        // overshoot emits several near-identical frames that would each
        // otherwise schedule a pty resize and trigger a prompt reprint.
        guard abs(newSize.width - lastDeliveredSize.width) > 0.5 ||
              abs(newSize.height - lastDeliveredSize.height) > 0.5 else { return }
        pendingSize = newSize
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.resizeDebounce, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.timer = nil
            // Don't apply size if still in live drag (timer fired after drag ended)
            guard !self.inLiveDrag else { return }
            guard let size = self.pendingSize else { return }
            self.applyPendingSize(size)
        }
    }

    private func applyPendingSize(_ size: CGSize) {
        // Deliver only when the size truly changed; otherwise the pty gets a
        // redundant SIGWINCH and the shell prompt is reprinted.
        guard abs(size.width - lastDeliveredSize.width) > 0.5 ||
              abs(size.height - lastDeliveredSize.height) > 0.5 else { return }
        lastDeliveredSize = size
        super.setFrameSize(size)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // View level runs BEFORE menu processing, so terminal-scoped commands
        // win even when system items share the combo (e.g. ⌘W vs Close Window).
        let hit: KeyBinding? = MainActor.assumeIsolated {
            controller?.keyBindings.first(where: { $0.matches(event: event) })
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
        case _ where binding.id.hasPrefix("goToTab."):
            if let n = Int(binding.id.dropFirst("goToTab.".count)) {
                MainActor.assumeIsolated { controller?.goToTab(n) }
                return true
            }
            return super.performKeyEquivalent(with: event)
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

    // MARK: - TR2/TR3: Neovim background sync + off-main detection

    /// Begin polling for an nvim/vim child of this pty's shell. Called once per
    /// view (from makeNSView for newly created views); guarded so a recycled,
    /// still-monitored view never double-starts. Runs on the main thread.
    func startNvimMonitor() {
        guard nvimMonitorTimer == nil else { return }
        // Capture the shell PID once on the main thread; the background poll
        // reads only this stable value (never touches `process` off-main).
        nvimShellPid = process?.shellPid ?? 0
        let timer = DispatchSource.makeTimerSource(queue: nvimQueue)
        timer.schedule(deadline: .now() + nvimPollInterval, repeating: nvimPollInterval)
        timer.setEventHandler { [weak self] in
            self?.pollNvim()
        }
        timer.resume()
        nvimMonitorTimer = timer
    }

    /// Off-main: detect an nvim/vim descendant of the shell and, on a state
    /// change, hop to the main thread to pin/restore the layer background.
    /// The entire `ps` spawn + parse stays on `nvimQueue` (TR3 latency).
    private func pollNvim() {
        guard nvimShellPid != 0 else { return }
        let detected = Self.descendantCommContains(nvimShellPid, needles: ["nvim", "vim"])
        guard detected != nvimActive else { return }
        nvimActive = detected
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // controller.backgroundColor is the single source of truth. While
            // nvim is active we force the layer to it so the editor does not
            // default to black; otherwise we restore the normal (same) value.
            self.layer?.backgroundColor = self.controller?.backgroundColor.cgColor
        }
    }

    /// True if any process in the descendant tree of `rootPid` has a `comm`
    /// containing one of `needles` (case-insensitive). Spawns `ps` once and
    /// walks the parent→child map on the calling (background) queue.
    private static func descendantCommContains(_ rootPid: pid_t, needles: [String]) -> Bool {
        let pipe = Pipe()
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-eo", "pid=,ppid=,comm="]
        ps.standardOutput = pipe
        try? ps.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return false }

        var parentOf: [pid_t: pid_t] = [:]
        var commOf: [pid_t: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard f.count == 3, let pid = pid_t(f[0]), let ppid = pid_t(f[1]) else { continue }
            parentOf[pid] = ppid
            commOf[pid] = f[2]
        }

        var childrenOf: [pid_t: [pid_t]] = [:]
        for (pid, ppid) in parentOf {
            if childrenOf[ppid] == nil { childrenOf[ppid] = [] }
            childrenOf[ppid]!.append(pid)
        }

        var stack: [pid_t] = [rootPid]
        var seen = Set<pid_t>()
        while let pid = stack.popLast() {
            guard seen.insert(pid).inserted else { continue }
            if let comm = commOf[pid]?.lowercased(),
               needles.contains(where: { comm.contains($0) }) { return true }
            if let kids = childrenOf[pid] { stack.append(contentsOf: kids) }
        }
        return false
    }

    deinit {
        timer?.invalidate()
        nvimMonitorTimer?.cancel()
        nvimMonitorTimer = nil
    }
}
