import SwiftUI
import Combine

/// File sidebar. Header row: hidden-files toggle (search is handled by the app's own search field) — the old "Favorites" label is gone.
///
/// Robustness contract: the view stays mounted across sidebar toggles and
/// tab switches (MainGlassView only collapses width/opacity), so `@State`
/// here — roots, expansions, search text — survives all of it by design.
/// Creation inserts into already-loaded nodes instead of rebuilding roots,
/// so expanded folders never collapse.
struct Sidebar: View {
    @EnvironmentObject private var controller: TerminalController
    @State private var roots: [FileNode] = []
    @State private var showDotFiles = false
    @State private var treeCollapsed = false
    @State private var git = GitStatus.empty
    @State private var showGitPopover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top bar: collapse/expand the file tree. Collapsing reveals the
            // Projects cards below.
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button(action: { treeCollapsed.toggle() }) {
                    Image(systemName: treeCollapsed ? "sidebar.right" : "sidebar.left")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(treeCollapsed ? "Show file tree" : "Collapse file tree")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(alignment: .bottom) {
                Rectangle().frame(height: 0.5).foregroundStyle(.separator).opacity(0.5)
            }

            if !treeCollapsed {
                GitPill(status: $git,
                        onCreateFolder: { self.create(.folder) },
                        onCreateFile: { self.create(.file) },
                        onPush: { self.pushGit() },
                        onPull: { self.pullGit() },
                        onTapBranch: { showGitPopover = true })
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                    .popover(isPresented: $showGitPopover) {
                        GitPanel(status: git,
                                 repo: controller.activeCwd.flatMap { GitService.repoRoot(for: URL(fileURLWithPath: $0)) })
                            .environmentObject(controller)
                    }
                treeList
            }

            // Projects — nice cards; always visible, prominent when tree collapsed.
            Divider().padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("Projects")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button(action: { addProjectViaPicker() }) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Add project")
                }
                .padding(.horizontal, 12)
                if controller.projects.isEmpty {
                    Text("No projects yet — add one with +")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                }
                ForEach(controller.projects) { p in
                    ProjectCard(project: p)
                }
            }
            .padding(.bottom, 6)
            Spacer(minLength: 0)
        }
        .onAppear { if roots.isEmpty { reloadRoots() }; refreshGit() }
        .onReceive(NotificationCenter.default.publisher(for: .reloadFileTree)) { _ in
            reloadRoots()
            refreshGit()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleDotFiles)) { _ in
            showDotFiles.toggle()
            reloadRoots()
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common)) { _ in refreshGit() }
    }


    // MARK: - Tree mode

    private var treeList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(roots) { node in
                    FolderRow(node: node)
                }
            }
        }
    }

    /// Flat matches from a bounded recursive walk under every favorite root.



    // MARK: - Creation

    private enum CreateKind { case file, folder }

    /// Create inside the focused terminal's cwd (fallback: first favorite),
    /// then splice the new node into the loaded tree so no folder collapses.
    private func create(_ kind: CreateKind) {
        let fm = FileManager.default
        var dirPath = controller.activeCwd ?? roots.first?.url.path ?? NSHomeDirectory()
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: dirPath, isDirectory: &isDir) || !isDir.boolValue {
            dirPath = roots.first?.url.path ?? NSHomeDirectory()
        }
        let dirURL = URL(fileURLWithPath: dirPath)

        let base = kind == .file ? "untitled" : "New Folder"
        let ext = kind == .file ? ".txt" : ""
        var name = base + ext
        var n = 2
        while fm.fileExists(atPath: dirURL.appendingPathComponent(name).path) {
            name = "\(base)-\(n)\(ext)"
            n += 1
        }
        let target = dirURL.appendingPathComponent(name)
        if kind == .folder {
            try? fm.createDirectory(at: target, withIntermediateDirectories: false)
        } else {
            try? Data().write(to: target)
        }

        // Splice into the loaded tree (keeps every expanded folder expanded).
        if let parent = findLoadedNode(dirURL) {
            parent.loadChildren()
            let child = FileNode(url: target, isDirectory: kind == .folder, depth: parent.depth + 1)
            parent.children?.append(child)
            parent.children?.sort {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        } else {
            reloadRoots()   // target outside loaded favorites — rebuild
        }

        if kind == .file { controller.openFile(target) }
    }

    /// Depth-first search over ALREADY-LOADED nodes only.
    private func findLoadedNode(_ url: URL) -> FileNode? {
        var stack = roots
        while let node = stack.popLast() {
            if node.url.standardizedFileURL.path == url.standardizedFileURL.path { return node }
            stack.append(contentsOf: node.children ?? [])
        }
        return nil
    }

    private func reloadRoots() {
        roots = controller.favorites.map { FileNode(url: $0, isDirectory: true) }
    }
    // MARK: - Git

    private var currentRepo: URL? {
        let cwd = controller.activeCwd.map { URL(fileURLWithPath: $0) } ?? roots.first?.url
        return cwd.flatMap { GitService.repoRoot(for: $0) }
    }

    private func refreshGit() {
        guard let repo = currentRepo else { git = GitStatus.empty; return }
        let binding = $git
        Task.detached {
            let s = GitService.status(in: repo)
            Task { @MainActor in binding.wrappedValue = s }
        }
    }

    private func pushGit() {
        guard let repo = currentRepo else { return }
        Task.detached {
            GitService.push(in: repo)
            Task { @MainActor in
                NotificationCenter.default.post(name: .reloadFileTree, object: nil)
            }
        }
    }

    private func pullGit() {
        guard let repo = currentRepo else { return }
        Task.detached {
            GitService.pull(in: repo)
            Task { @MainActor in
                NotificationCenter.default.post(name: .reloadFileTree, object: nil)
            }
        }
    }
}

/// Compact icon button with a subtle hover wash — matches the sidebar header
/// size (11pt glyph) and adapts to dark/light themes via `Color.primary`.
private struct HeaderIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11))
                .foregroundStyle(hover ? .primary : .secondary)
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hover ? Color.primary.opacity(0.10) : .clear)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover = $0 }
    }
}

/// Top-of-tree git pill: branch + change counts, create/push/pull actions.
/// Tapping the branch label opens the richer `GitPanel` popover.
private struct GitPill: View {
    @Binding var status: GitStatus
    var onCreateFolder: () -> Void
    var onCreateFile: () -> Void
    var onPush: () -> Void
    var onPull: () -> Void
    var onTapBranch: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("⎇").font(.system(size: 12)).foregroundStyle(.secondary)
                if status.isRepo {
                    Text(status.branch)
                        .font(.system(size: 12, weight: .medium))
                    if status.ahead > 0 || status.behind > 0 {
                        Text("↑\(status.ahead) ↓\(status.behind)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    if status.modified + status.untracked > 0 {
                        Text("\(status.modified)●  \(status.untracked)+")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text("No repository")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .onTapGesture { onTapBranch() }
            .help("Open git panel")
            Spacer(minLength: 0)
            HeaderIconButton(systemName: "folder.badge.plus", help: "New folder") { onCreateFolder() }
            HeaderIconButton(systemName: "doc.badge.plus", help: "New file") { onCreateFile() }
            HeaderIconButton(systemName: "arrow.up.to.line", help: "Push") { onPush() }
            HeaderIconButton(systemName: "arrow.down.to.line", help: "Pull") { onPull() }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
    }
}

/// A project shown as a card in the sidebar. Tap to `cd` the terminal into it;
/// the name + accent color are editable inline, and the × removes it.
private struct ProjectCard: View {
    let project: SidebarProject
    @EnvironmentObject private var controller: TerminalController

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(nsColor: NSColor(hex: project.colorHex) ?? .systemBlue))
                .frame(width: 4, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                TextField("", text: Binding(
                    get: { project.name },
                    set: { controller.renameProject(project.id, $0) }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                Text(project.path)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            ColorPicker("", selection: Binding(
                get: { Color(nsColor: NSColor(hex: project.colorHex) ?? .systemBlue) },
                set: { controller.setProjectColor(project.id, hex(from: $0)) }
            )).labelsHidden()
                .frame(width: 16)
            Button(action: { controller.removeProject(project.id) }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove project")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Color.primary.opacity(0.08)))
        .contentShape(Rectangle())
        .onTapGesture { controller.cd(project.path) }
    }
}

private extension Sidebar {
    /// Open a directory picker and add the chosen folder as a project.
    func addProjectViaPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            controller.addProject(url)
        }
    }
}

/// Convert a SwiftUI `Color` to a `#RRGGBB`-style hex string for storage.
private func hex(from color: Color) -> String {
    let c = color.resolve(in: EnvironmentValues())
    return String(format: "%02X%02X%02X",
                  Int((c.red * 255).rounded()),
                  Int((c.green * 255).rounded()),
                  Int((c.blue * 255).rounded()))
}

/// Richer git surface: branch + ahead/behind, working-tree changes, a commit
/// field, push/pull/fetch actions, and recent commits. Opened from `GitPill`.
private struct GitPanel: View {
    let status: GitStatus
    let repo: URL?
    @EnvironmentObject private var controller: TerminalController
    @State private var commitMsg = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("⎇").font(.system(size: 13)).foregroundStyle(.secondary)
                Text(status.branch.isEmpty ? "no branch" : status.branch)
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
                if status.ahead > 0 || status.behind > 0 {
                    Text("↑\(status.ahead)  ↓\(status.behind)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            Text("Changes").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            if status.changes.isEmpty {
                Text("Working tree clean").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(status.changes) { c in
                            HStack(spacing: 8) {
                                Text(c.status)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(changeColor(c.status))
                                    .frame(width: 26, alignment: .leading)
                                Text(c.path)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                .frame(maxHeight: 150)
            }
            Divider()
            HStack(spacing: 6) {
                TextField("Commit message", text: $commitMsg)
                    .textFieldStyle(.roundedBorder)
                Button("Commit") { commit() }
                    .disabled(commitMsg.isEmpty || repo == nil)
            }
            HStack(spacing: 8) {
                Button("Pull") { gitOp(.pull) }
                Button("Push") { gitOp(.push) }
                Button("Fetch") { gitOp(.fetch) }
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            Divider()
            Text("Recent").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(status.recentCommits, id: \.self) { c in
                        Text(c)
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxHeight: 90)
        }
        .padding(14)
        .frame(width: 340)
    }

    private func changeColor(_ s: String) -> Color {
        if s.contains("?") { return .orange }
        if s.contains("U") { return .purple }
        if s.contains("D") { return .red }
        if s.contains("A") { return .green }
        if s.contains("M") { return .yellow }
        return .secondary
    }
    private enum GitOp: Sendable { case push, pull, fetch }

    private func gitOp(_ kind: GitOp) {
        guard let r = repo else { return }
        Task.detached {
            switch kind {
            case .push: GitService.push(in: r)
            case .pull: GitService.pull(in: r)
            case .fetch: GitService.fetch(in: r)
            }
            Task { @MainActor in
                NotificationCenter.default.post(name: .reloadFileTree, object: nil)
            }
        }
    }

    private func commit() {
        guard let r = repo else { return }
        let msg = commitMsg
        commitMsg = ""
        Task.detached {
            GitService.commit(in: r, message: msg)
            Task { @MainActor in
                NotificationCenter.default.post(name: .reloadFileTree, object: nil)
            }
        }
    }
}
