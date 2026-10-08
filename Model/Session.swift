import Foundation
import AppKit

/// One terminal tab. The real pty lives in `TerminalViewRepresentable`;
/// this is just the observable metadata (label, working dir, profile, accent).
/// What a session hosts: a live terminal (pty) or macterm's in-app text editor.
enum SessionKind: Equatable {
    case terminal
    case editor(fileURL: URL)
}
/// SSH connection parameters. When a `Session` carries one, the terminal view
/// launches `/usr/bin/ssh` instead of the local login shell.
struct SSHLaunch: Equatable, Codable {
    var host: String
    var user: String
    var port: Int = 22
    var identityFile: String? = nil
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
    /// When set, the terminal launches `ssh` (not the local shell) for this session.
    var ssh: SSHLaunch? = nil

    /// Human-readable tab title: explicit title, else cwd basename, else kind.
    var displayTitle: String {
        if !title.isEmpty { return title }
        if let cwd, let last = cwd.split(separator: "/").last { return String(last) }
        switch kind {
        case .terminal: return "Terminal"
        case .editor(let url): return "Editor: \(url.lastPathComponent)"
        }
    }
}
