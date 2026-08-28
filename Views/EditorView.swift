import SwiftUI
import AppKit
import Highlightr

/// In-app text editor for files opened from the sidebar, with live syntax
/// highlighting via Highlightr. The text buffer lives in the model
/// (`TerminalController.editorBuffers`, keyed by session id) so each editor tab
/// keeps its own content and unsaved edits across tab switches. Save writes back
/// to disk, Revert reloads from disk. Non-text files are routed to the system
/// default app instead (see `TerminalController.openFile`). Appearance (background
/// opacity, font, caret, selection) is driven by the same `TerminalController`
/// settings the terminal uses, so styling stays consistent app-wide.
struct EditorView: View {
    let url: URL
    @Binding var buffer: EditorBuffer
    @EnvironmentObject private var controller: TerminalController

    @State private var vimMode = false
    @State private var vimNormal = false
    private var isModified: Bool { buffer.content != buffer.original }

    /// Map a file extension to a Highlightr language id. Unknown → nil (plain text).
    private var language: String? {
        let map: [String: String] = [
            "swift": "swift", "py": "python", "pyw": "python",
            "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascript",
            "ts": "typescript", "tsx": "typescript",
            "json": "json", "yaml": "yaml", "yml": "yaml", "toml": "ini",
            "sh": "bash", "zsh": "bash", "bash": "bash", "fish": "bash",
            "c": "c", "h": "c", "cc": "cpp", "cpp": "cpp", "cxx": "cpp", "hpp": "cpp", "hxx": "cpp",
            "m": "objectivec", "mm": "objectivec",
            "java": "java", "kt": "kotlin", "kts": "kotlin", "go": "go",
            "rs": "rust", "rb": "ruby", "php": "php", "lua": "lua",
            "sql": "sql", "html": "html", "htm": "html", "xml": "xml", "svg": "xml",
            "css": "css", "scss": "scss", "less": "less",
            "md": "markdown", "markdown": "markdown", "mkd": "markdown",
            "vim": "vim", "tex": "latex", "r": "r", "dart": "dart",
            "vue": "vue", "diff": "diff", "patch": "diff", "pl": "perl", "pm": "perl"
        ]
        return map[url.pathExtension.lowercased()]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                Text(url.lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                if isModified {
                    Text("● Unsaved").foregroundStyle(.orange)
                }
                Button("Save") { save() }.disabled(!isModified)
                Button("Revert") { revert() }.disabled(!isModified)
                Divider()
                Toggle("VIM", isOn: $vimMode)
                    .toggleStyle(.button)
                    .controlSize(.small)
                Text(vimNormal ? "-- NORMAL --" : "-- INSERT --")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(vimNormal ? .green : .secondary)
                    .opacity(vimMode ? 1 : 0.4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: controller.backgroundColor).opacity(0.5))
            Divider()
            HighlightingEditor(text: $buffer.content, language: language, vimMode: vimMode, vimNormal: $vimNormal)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.clear)
    }

    private func save() {
        do {
            try buffer.content.write(to: url, atomically: true, encoding: .utf8)
            buffer.original = buffer.content
        } catch {
            // Leave isModified true so the user knows the write failed.
        }
    }

    private func revert() {
        buffer.content = buffer.original
    }
}

/// Editable, syntax-highlighted text view backed by `NSTextView`. Re-highlights
/// the whole buffer on each keystroke (fine for typical source files) and
/// preserves the selection so the caret stays put. Background, font, caret and
/// selection follow `TerminalController` so they match the terminal styling.
struct HighlightingEditor: NSViewRepresentable {
    @Binding var text: String
    let language: String?
    @EnvironmentObject private var controller: TerminalController
    var vimMode: Bool = false
    var vimNormal: Binding<Bool> = .constant(false)

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        let old = scroll.documentView as! NSTextView
        let tv = VimModeTextView()
        tv.textContainer = old.textContainer
        tv.isEditable = true
        tv.isRichText = true
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.textContainerInset = NSSize(width: 6, height: 6)
        scroll.documentView = tv

        let coordinator = context.coordinator
        coordinator.tv = tv
        coordinator.parent = self
        tv.onModeChange = { [weak coordinator] normal in
            coordinator?.parent?.vimNormal.wrappedValue = normal
        }
        tv.vimEnabled = vimMode
        tv.normalMode = vimMode
        tv.wasVimEnabled = vimMode
        _ = context.coordinator.syncTheme()
        coordinator.apply(text)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        let tv = nsView.documentView as! VimModeTextView
        tv.vimEnabled = vimMode
        if vimMode && !tv.wasVimEnabled { tv.normalMode = true }
        tv.wasVimEnabled = vimMode
        if !vimMode { tv.normalMode = false }
        context.coordinator.applyAppearance(tv)
        let themeChanged = context.coordinator.syncTheme()
        if themeChanged || tv.string != text {
            context.coordinator.apply(text)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var tv: NSTextView?
        var parent: HighlightingEditor?
        private let highlighter: Highlightr? = Highlightr()
        /// Slug whose matching Highlightr scheme is currently loaded.
        var appliedThemeSlug: String?

        override init() {
            super.init()
            _ = highlighter?.setTheme(to: AppTheme.bySlug(AppTheme.defaultSlug)?.hljsTheme ?? "onedark")
            appliedThemeSlug = AppTheme.defaultSlug
        }

        /// Load the Highlightr scheme matching the selected base46 theme.
        /// Returns true when the scheme changed and a re-highlight is needed.
        @MainActor func syncTheme() -> Bool {
            guard let p = parent else { return false }
            guard appliedThemeSlug != p.controller.themeName else { return false }
            appliedThemeSlug = p.controller.themeName
            return highlighter?.setTheme(to: p.controller.theme.hljsTheme) != nil
        }

    /// Push terminal appearance (bg, font, caret, selection) onto the view.
    /// @MainActor: touches NSView/NSTextView properties; all callers already
    /// run on the main thread (SwiftUI representable + AppKit delegate).
    @MainActor func applyAppearance(_ tv: NSTextView) {
        guard let c = parent?.controller else { return }
        tv.backgroundColor = c.backgroundColor
        tv.drawsBackground = true
        tv.font = c.font
        tv.insertionPointColor = c.caretColor
        tv.selectedTextAttributes = [.backgroundColor: c.selectionColor]
    }

        /// Re-highlight with the active theme's scheme while forcing the app
        /// font and stripping any per-token background so the terminal's
        /// background/opacity shows through.
        @MainActor func apply(_ text: String) {
            guard let tv = tv else { return }
            let selected = tv.selectedRanges
            if let themed = highlight(text) {
                tv.textStorage?.setAttributedString(themed)
            } else {
                tv.string = text
            }
            tv.selectedRanges = selected
            applyAppearance(tv)
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let newText = tv.string
            let selected = tv.selectedRanges
            if let themed = highlight(newText) {
                tv.textStorage?.setAttributedString(themed)
            }
            tv.selectedRanges = selected
            applyAppearance(tv)
            parent?.text = newText
        }

        /// Highlight `text` in the file's language and post-process it:
        ///  - `fastRender: false` uses Apple's HTML parser — the custom fast
        ///    parser drops attributes from nested spans, which is why strings,
        ///    quotes and brackets lost their colors.
        ///  - highlight.js leaves most punctuation at the base foreground, so
        ///    quotes/brackets get an explicit theme color afterwards.
        @MainActor private func highlight(_ text: String) -> NSAttributedString? {
            guard let lang = parent?.language,
                  let attr = highlighter?.highlight(text, as: lang, fastRender: false)
            else { return nil }
            let themed = NSMutableAttributedString(attributedString: attr)
            let full = NSRange(location: 0, length: themed.length)
            if let f = parent?.controller.font {
                themed.addAttribute(.font, value: f, range: full)
            }
            themed.removeAttribute(.backgroundColor, range: full)

            // Distinct color for structural characters — cyan from the same
            // hierarchy palette that tints folders, so it fits every theme.
            if let punct = parent?.controller.theme.hierarchyColors[1] {
                let delimiters: Set<Character> = ["\"", "'", "`", "{", "}", "[", "]", "(", ")"]
                var i = 0
                for ch in themed.string {
                    if delimiters.contains(ch) {
                        themed.addAttribute(.foregroundColor, value: punct,
                                            range: NSRange(location: i, length: 1))
                    }
                    i += 1
                }
            }
            return themed
        }
    }
}

/// NSTextView subclass adding a bounded vim modal layer for the in-app editor.
/// When `vimEnabled` is off it behaves exactly like a plain editable text view.
/// When on and in normal mode, printable keys are interpreted as vim
/// motions/operators instead of inserting text:
///   h j k l  move · w b e  word · 0 $  line edges · gg G  file edges
///   i a A I  enter insert · o  open line below · x  delete char
///   D  delete to EOL · dd  delete line · Esc  return to normal
final class VimModeTextView: NSTextView {
    var vimEnabled = false
    var normalMode = false
    var wasVimEnabled = false
    var pendingD = false
    var pendingG = false
    var onModeChange: ((Bool) -> Void)?

    override func keyDown(with event: NSEvent) {
        // Esc always returns to normal mode while vim is active.
        if vimEnabled && event.keyCode == 53 {
            setNormal(true)
            return
        }
        // Outside vim, in insert mode, or with a system modifier: default behavior.
        if !vimEnabled || !normalMode
           || event.modifierFlags.contains(.command)
           || event.modifierFlags.contains(.control)
           || event.modifierFlags.contains(.option) {
            super.keyDown(with: event)
            return
        }

        let ch = event.charactersIgnoringModifiers ?? ""
        if ch != "d" { pendingD = false }
        if ch != "g" { pendingG = false }

        switch ch {
        case "i": setNormal(false)
        case "a": setNormal(false); moveRight(nil)
        case "A": moveToEndOfLine(nil); setNormal(false)
        case "I": moveToBeginningOfLine(nil); setNormal(false)
        case "o": moveToEndOfLine(nil); insertText("\n", replacementRange: selectedRange()); setNormal(false)
        case "h": moveLeft(nil)
        case "l": moveRight(nil)
        case "j": moveDown(nil)
        case "k": moveUp(nil)
        case "0": moveToBeginningOfLine(nil)
        case "$": moveToEndOfLine(nil)
        case "w": moveWordForward(nil)
        case "b": moveWordBackward(nil)
        case "e": moveToEndOfWord()
        case "x": deleteForward(nil)
        case "D": deleteToEndOfLine()
        case "d":
            if pendingD { pendingD = false; deleteLine() }
            else { pendingD = true }
        case "g":
            if pendingG { pendingG = false; moveToBeginningOfDocument(nil) }
            else { pendingG = true }
        case "G": moveToEndOfDocument(nil)
        default:
            break
        }
    }

    private func setNormal(_ normal: Bool) {
        normalMode = normal
        pendingD = false
        pendingG = false
        onModeChange?(normal)
    }

    private func deleteLine() {
        guard let storage = textStorage else { return }
        let str = storage.string as NSString
        let line = str.lineRange(for: selectedRange())
        let loc = line.location
        storage.replaceCharacters(in: line, with: "")
        setSelectedRange(NSRange(location: min(loc, storage.length), length: 0))
    }

    private func deleteToEndOfLine() {
        guard let storage = textStorage else { return }
        let str = storage.string as NSString
        let sel = selectedRange()
        let line = str.lineRange(for: sel)
        let end = (line.upperBound > 0 && str.character(at: line.upperBound - 1) == 10)
            ? line.upperBound - 1 : line.upperBound
        let from = sel.location
        if end > from {
            storage.replaceCharacters(in: NSRange(location: from, length: end - from), with: "")
        }
        setSelectedRange(NSRange(location: from, length: 0))
    }
    private func moveToEndOfWord() {
        guard let storage = textStorage else { return }
        let str = storage.string as NSString
        let len = str.length
        var loc = selectedRange().location
        if loc >= len { return }
        let word = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        while loc < len && !word.contains(Unicode.Scalar(str.character(at: loc))!) { loc += 1 }
        while loc < len && word.contains(Unicode.Scalar(str.character(at: loc))!) { loc += 1 }
        setSelectedRange(NSRange(location: min(loc, len), length: 0))
    }
}
