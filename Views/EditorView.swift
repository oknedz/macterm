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
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: controller.backgroundColor).opacity(0.5))
            Divider()
            HighlightingEditor(text: $buffer.content, language: language)
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

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        // Configure the scrollable text view's own document view directly
        // (reusing the scroll view's laid-out text container) instead of
        // swapping in a bare NSTextView, which had no resizing flags and
        // rendered into a zero-height frame — the blank-editor bug.
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.isEditable = true
        tv.isRichText = true
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.heightTracksTextView = false

        let coordinator = context.coordinator
        coordinator.tv = tv
        coordinator.parent = self
        _ = context.coordinator.syncTheme()
        coordinator.apply(text)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        let tv = nsView.documentView as! NSTextView
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

