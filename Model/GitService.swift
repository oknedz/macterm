import Foundation

/// Lightweight git status for the sidebar pill: branch, ahead/behind, change
/// counts and recent commits. Runs `git` via `Process` (no third-party deps).
struct GitStatus {
    var branch: String = ""
    var ahead: Int = 0
    var behind: Int = 0
    var modified: Int = 0
    var untracked: Int = 0
    var recentCommits: [String] = []
    var changes: [GitChange] = []
    var isRepo: Bool { !branch.isEmpty }

    static let empty = GitStatus()
}
/// A single working-tree change reported by `git status --porcelain`.
struct GitChange: Identifiable {
    let status: String   // 2-char XY code, e.g. " M", "A ", "??"
    let path: String
    var id: String { path }
}

enum GitService {
    /// Nearest `.git` ancestor of `start`, or nil when not in a repo.
    static func repoRoot(for start: URL) -> URL? {
        var dir = start.path
        while true {
            if FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(".git")) {
                return URL(fileURLWithPath: dir)
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { return nil }
            dir = parent
        }
    }

    static func status(in repo: URL) -> GitStatus {
        var s = GitStatus()

        let out = run(["-C", repo.path, "status", "-sb", "--porcelain=1"])
        for line in out.split(separator: "\n") where !line.isEmpty {
            if line.hasPrefix("## ") {
                let rest = line.dropFirst(3)
                if let up = rest.range(of: "...") {
                    s.branch = String(rest[..<up.lowerBound])
                    let tail = rest[up.upperBound...]
                    if let a = tail.range(of: "ahead ") {
                        s.ahead = Int(String(tail[a.upperBound...].prefix(while: { $0.isNumber }))) ?? 0
                    }
                    if let b = tail.range(of: "behind ") {
                        s.behind = Int(String(tail[b.upperBound...].prefix(while: { $0.isNumber }))) ?? 0
                    }
                } else {
                    s.branch = String(rest)
                }
            } else {
                let code = line.prefix(2)
                let path = String(line.dropFirst(3))
                if code.contains("?") { s.untracked += 1 }
                else if code != "  " { s.modified += 1 }
                s.changes.append(GitChange(status: String(code), path: path))
            }
        }

        s.recentCommits = run(["-C", repo.path, "log", "--oneline", "-5"])
            .split(separator: "\n").map(String.init)
        return s
    }

    @discardableResult
    static func push(in repo: URL) -> String { run(["-C", repo.path, "push"]) }
    @discardableResult
    static func pull(in repo: URL) -> String { run(["-C", repo.path, "pull"]) }
    /// Stage everything and create a commit with the given message.
    @discardableResult
    static func commit(in repo: URL, message: String) -> String {
        run(["-C", repo.path, "add", "-A"])
        return run(["-C", repo.path, "commit", "-m", message])
    }
    /// Fetch from the tracked remote.
    @discardableResult
    static func fetch(in repo: URL) -> String { run(["-C", repo.path, "fetch"]) }

    /// Runs `git` with `args`; returns combined stdout/stderr (empty on failure).
    @discardableResult
    private static func run(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try? p.run()
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
