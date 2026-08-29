import SwiftUI
import AppKit

/// App-wide capsule search field.
///
/// Globally applied styling policy (coding guidelines): capsule geometry,
/// neutral gray focus accent (no orange tint), 0.5pt gray border. Use this for
/// every search input in the app — sidebar, settings, theme picker.
struct CapsuleSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onCommit: (() -> Void)? = nil

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: 12)
        style(field)
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
        nsView.placeholderString = placeholder
        style(nsView)
    }

    private func style(_ field: NSSearchField) {
        field.wantsLayer = true
        field.layer?.cornerRadius = 11          // height/2 of the ~22pt field
        field.layer?.borderWidth = 0.5
        field.layer?.borderColor = NSColor.systemGray.withAlphaComponent(0.4).cgColor
        field.backgroundColor = NSColor.systemGray.withAlphaComponent(0.12)
        field.textColor = .labelColor
        // Suppress the default focus accent (orange) — neutral gray instead.
        field.appearance = NSAppearance(named: .aqua)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let parent: CapsuleSearchField
        init(_ p: CapsuleSearchField) { parent = p }
        func controlTextDidChange(_ obj: Notification) {
            if let f = obj.object as? NSSearchField { parent.text = f.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onCommit?()
                return true
            }
            return false
        }
    }
}

/// View modifier form for inline text fields that should share the capsule
/// search look (neutral gray focus, 0.5pt border).
struct CapsuleSearchStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.gray.opacity(0.4), lineWidth: 0.5))
            .accentColor(Color.gray.opacity(0.4))
    }
}

extension View {
    /// Apply the global capsule search styling.
    func capsuleSearchStyle() -> some View { modifier(CapsuleSearchStyle()) }
}
