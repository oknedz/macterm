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
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = true
        tv.isRichText = true
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.textContainerInset = NSSize(width: 6, height: 6)
        let coordinator = context.coordinator
        coordinator.tv = tv
        coordinator.parent = self
        coordinator.apply(text)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        let tv = nsView.documentView as! NSTextView
        // Re-apply appearance on every update so live setting changes (bg, font,
        // selection, caret) take effect without recreating the text view.
        context.coordinator.applyAppearance(tv)
        if tv.string != text {
            context.coordinator.apply(text)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var tv: NSTextView?
        var parent: HighlightingEditor?
        private let highlighter: Highlightr? = Highlightr()

        override init() {
            super.init()
            _ = highlighter?.setTheme(to: "oceanic-next")
        }

        /// Push terminal appearance (bg/opacity, font, caret, selection) onto the view.
        func applyAppearance(_ tv: NSTextView) {
            guard let c = parent?.controller else { return }
            tv.backgroundColor = c.backgroundColor
            tv.isOpaque = c.backgroundAlpha >= 1
            tv.drawsBackground = true
            tv.font = c.font
            tv.insertionPointColor = c.caretColor
            tv.selectedTextAttributes = [.backgroundColor: c.selectionColor]
        }

        /// Re-highlight `text` (oceanic-next token colors) while forcing the
        /// app font and stripping any per-token background so the terminal's
        /// background/opacity shows through.
        func apply(_ text: String) {
            guard let tv = tv else { return }
            let selected = tv.selectedRanges
            if let lang = parent?.language,
               let attr = highlighter?.highlight(text, as: lang) {
                let themed = NSMutableAttributedString(attributedString: attr)
                let full = NSRange(location: 0, length: themed.length)
                if let f = parent?.controller?.font {
                    themed.addAttribute(.font, value: f, range: full)
                }
                themed.removeAttribute(.backgroundColor, range: full)
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
            if let lang = parent?.language,
               let attr = highlighter?.highlight(newText, as: lang) {
                let themed = NSMutableAttributedString(attributedString: attr)
                let full = NSRange(location: 0, length: themed.length)
                if let f = parent?.controller?.font {
                    themed.addAttribute(.font, value: f, range: full)
                }
                themed.removeAttribute(.backgroundColor, range: full)
                tv.textStorage?.setAttributedString(themed)
            }
            tv.selectedRanges = selected
            applyAppearance(tv)
            parent?.text = newText
        }
    }
}
