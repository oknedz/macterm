import Foundation
import AppKit

/// One terminal tab. The real pty lives in `TerminalViewRepresentable`;
/// this is just the observable metadata (label, working dir, profile, accent).
/// What a session hosts: a live terminal (pty) or macterm's in-app text editor.
enum SessionKind {
    case terminal
    case editor(fileURL: URL)
}

struct Session: Identifiable {
    let id = UUID()
    var title: String
    var cwd: String?
    var profile: String
    /// Optional tab accent color.
    var color: NSColor? = nil
    /// Terminal vs in-app editor session.
    var kind: SessionKind = .terminal
}
