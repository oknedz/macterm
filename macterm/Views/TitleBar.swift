import SwiftUI
import AppKit

/// Top bar: session tabs inline with the macOS traffic lights (native title-bar
/// style). Reaches the window's top edge through `.edgesIgnoringSafeArea(.top)`
/// (with the transparent full-size-content window from WindowConfigurator) and
/// clears the semaphore buttons with a leading inset. Settings gear sits
/// top-right, inline with the tabs. The sidebar toggle lives here only — always
/// visible so it works whether the sidebar is open or collapsed.
struct TitleBar: View {
    @EnvironmentObject private var controller: TerminalController

    var body: some View {
        HStack(spacing: 6) {
            // Clears the macOS traffic lights (red/yellow/green) at the top-left.
            Spacer().frame(width: 78)

            // Sidebar toggle — always here (top bar only).
            IconButton(systemName: "sidebar.left") { controller.toggleSidebar() }
                .frame(width: 28, height: 28)

            // Tabs inline with the traffic lights.
            ForEach(controller.tabs) { tab in
                TabPill(tab: tab)
            }
            IconButton(systemName: "plus") { controller.newTab() }
                .frame(width: 26, height: 26)

            Spacer(minLength: 0)

            // Settings gear, top-right, inline with the tabs.
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(Color.clear)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 14)
        }
        .frame(height: 36)
        .padding(.vertical, 2)
        .background {
            // Theme background bleeds through the titlebar vibrancy so the
            // top bar unifies with the rest of the app on every theme.
            ZStack {
                Color(nsColor: controller.theme.background).opacity(0.55)
                VisualEffectView(material: .titlebar, blendingMode: .withinWindow)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .frame(height: 0.5)
                .foregroundStyle(.separator)
                .opacity(0.5)
        }
    }
}

/// Plain icon button with a subtle hover wash — sidebar toggle / settings / +.
struct IconButton: View {
    let systemName: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .frame(width: 30, height: 30)
        .background(hover ? Color.white.opacity(0.16) : Color.clear)
        .cornerRadius(7)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

private let tabAccentPalette: [(name: String, color: NSColor)] = [
    ("Red", .systemRed), ("Orange", .systemOrange), ("Yellow", .systemYellow),
    ("Green", .systemGreen), ("Blue", .systemBlue), ("Purple", .systemPurple),
    ("Pink", .systemPink), ("Gray", .systemGray)
]

/// A single session tab. Small + minimal so the terminal gets maximum space.
/// Right-click for a context menu: rename (inline) or recolor the tab.
private struct TabPill: View {
    let tab: WorkspaceTab
    @EnvironmentObject private var controller: TerminalController
    @State private var hover = false
    @State private var renaming = false
    @State private var draft = ""

    private var active: Bool { tab.id == controller.activeTabId }

    var body: some View {
        HStack(spacing: 5) {
            if let color = tab.color {
                Circle()
                    .fill(Color(nsColor: color))
                    .frame(width: 8, height: 8)
            }
            if renaming {
                RenamingTextField(text: $draft, onCommit: commitRename)
                    .frame(maxWidth: 110)
                    .onAppear { draft = tab.title }
                    .onExitCommand { renaming = false }
            } else {
                Text(tab.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: 110, alignment: .leading)
            }
            Button { controller.closeTab(tab.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(hover || active ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(
            active
                ? Color(nsColor: controller.accentColor).opacity(0.22)
                : (hover ? Color.primary.opacity(0.10) : Color.primary.opacity(0.05))
        )
        // Accent border on the ACTIVE tab — unambiguous location indicator.
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(active ? Color(nsColor: controller.accentColor) : .clear,
                        lineWidth: active ? 1.5 : 0)
        )
        .foregroundStyle(.primary)
        .cornerRadius(11)
        .onHover { hover = $0 }
        .onTapGesture {
            controller.activeTabId = tab.id
            controller.focusedSessionId = tab.layout.firstLeaf ?? controller.focusedSessionId
        }
        .contextMenu {
            Button("Rename") {
                draft = tab.title
                renaming = true
                // Focus the new field and highlight its text so the user
                // can type to replace the whole name immediately.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                    NSApp.sendAction(#selector(NSText.selectAll), to: nil, from: nil)
                }
            }
            Menu("Color") {
                // NSMenu-backed menus only draw Text + Image; SwiftUI Shapes
                // (Circle) are dropped — hence pre-rendered NSImage dots.
                ForEach(tabAccentPalette, id: \.name) { item in
                    Button { controller.setTabColor(tab.id, item.color) } label: {
                        HStack(spacing: 6) {
                            Image(nsImage: Self.menuDot(item.color))
                            Text(item.name)
                        }
                    }
                }
                Divider()
                Button("None") { controller.setTabColor(tab.id, nil) }
            }
        }
    }

    /// Round swatch as an NSImage so it actually renders inside menus.
    private static func menuDot(_ color: NSColor) -> NSImage {
        let img = NSImage(size: NSSize(width: 11, height: 11), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        img.isTemplate = false
        return img
    }
    private func commitRename() {
        let t = draft.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { controller.renameTab(tab.id, to: t) }
        renaming = false
    }
}

/// NSTextField-backed SwiftUI field that auto-focuses and selects all text.
private struct RenamingTextField: NSViewRepresentable {
    @Binding var text: String
    var onCommit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        field.lineBreakMode = .byTruncatingTail
        field.target = context.coordinator
        field.action = #selector(Coordinator.commit)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
        // Become first responder and select all when the view appears or updates in rename mode.
        DispatchQueue.main.async {
            // Prime focus and selection only once to avoid replacing text on every keystroke.
            if context.coordinator.primed == false {
                if nsView.window?.firstResponder != nsView.currentEditor() {
                    nsView.becomeFirstResponder()
                }
                nsView.currentEditor()?.selectAll(nil)
                context.coordinator.primed = true
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: RenamingTextField
        var primed = false
        var canceled = false
        
        init(_ parent: RenamingTextField) { self.parent = parent }

        @objc func commit() {
            DispatchQueue.main.async {
                self.parent.onCommit()
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                // Mark as canceled so we don't commit on end editing.
                canceled = true
                return false // allow default behavior to end editing
            }
            return false
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            // Auto-commit on focus loss unless the user canceled with ESC.
            if !canceled {
                DispatchQueue.main.async {
                    self.parent.onCommit()
                }
            }
            canceled = false
        }
    }
}

/// Small gear glyph used inside SettingsLink in the title bar.
private struct SettingsGear: View {
    @State private var hover = false

    var body: some View {
        Image(systemName: "gearshape")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 30, height: 30)
            .background(hover ? Color.white.opacity(0.16) : Color.clear)
            .cornerRadius(7)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}

