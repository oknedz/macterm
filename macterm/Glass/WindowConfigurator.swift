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
