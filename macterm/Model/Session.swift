import Foundation
import AppKit

/// One terminal tab. The real pty lives in `TerminalViewRepresentable`;
/// this is just the observable metadata (label, working dir, profile, accent).
struct Session: Identifiable {
    let id = UUID()
    var title: String
    var cwd: String?
    var profile: String
    /// Optional tab accent color.
    var color: NSColor? = nil
}
