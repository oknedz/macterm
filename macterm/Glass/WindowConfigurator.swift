import SwiftUI
import AppKit

/// Makes the window transparent so `VisualEffectView(blendingMode: .behindWindow)`
/// blurs the real desktop behind the app, and pins content to the top edge
/// (no hidden-title-bar inset). Configured synchronously when the view joins
/// the window so layout settles correctly on first paint.
final class ConfiguredWindowHostingView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let win = window else { return }
        win.isOpaque = false
        win.backgroundColor = .clear
        win.styleMask.insert(.fullSizeContentView)
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
    }
}

struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        ConfiguredWindowHostingView()
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Invisible zero-size view tagging the Settings window so the global
/// shortcut monitor can exempt native windows from terminal-scoped combos.
final class SettingsMarkerView: NSView {}

struct SettingsWindowMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { SettingsMarkerView(frame: .zero) }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Depth-first containment test used by the shortcut monitor.
func windowContains(_ window: NSWindow?, _ type: NSView.Type) -> Bool {
    guard let root = window?.contentView else { return false }
    var stack: [NSView] = [root]
    while let v = stack.popLast() {
        if v.isKind(of: type) { return true }
        stack.append(contentsOf: v.subviews)
    }
    return false
}
