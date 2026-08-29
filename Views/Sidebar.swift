import SwiftUI
import Combine

/// Which git side panel is currently open (opened from the toolbar pill).
private enum GitPanelKind { case branch, changes, log, sync }
/// Git sync actions surfaced in the sync panel.
private enum GitOp: String { case push, pull, fetch }

/// File sidebar. Header row: hidden-files toggle (search is handled by the app's own search field) — the old "Favorites" label is gone.
///
/// Robustness contract: the view stays mounted across sidebar toggles and
/// tab switches (MainGlassView only collapses width/opacity), so `@State`
/// here — roots, expansions, search text — survives all of it by design.
/// Creation inserts into already-loaded nodes instead of rebuilding roots,
/// so expanded folders never collapse, and deletion removes only the deleted
/// node in place.
struct Sidebar: View {
    @EnvironmentObject private var controller: TerminalController
    @State private var roots: [FileNode] = []
    @State private var showDotFiles = false
    @State private var treeCollapsed = false
    @State private var git = GitStatus.empty
    /// Active git side panel (branch / changes / log / sync), or nil when closed.
    @State private var gitPanel: GitPanelKind? = nil
    @State private var gitSyncAction = ""
    @State private var gitSyncResult = ""
    /// Currently selected/focused tree node — creation targets its directory.
    @State private var selectedNodeURL: URL? = nil
    /// Top inset for the git pill, scales with the user's Dynamic Type size
    /// so the pill stays clear of the sidebar's top edge at any text setting.
    @ScaledMetric private var pillTopInset: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Git command bar — a rounded pill with clean icons. Each icon opens
            // its own side panel (branch / changes / log) or runs a sync action
            // (push / pull / fetch) that surfaces in the sync panel. File-tree
            // collapse/expand lives as the leading pill button (no top header).
            GitToolbarPill(
                status: $git,
                panel: $gitPanel,
                syncAction: $gitSyncAction,
                syncResult: $gitSyncResult,
                treeCollapsed: $treeCollapsed,
                onCreateFolder: { newFolderIn(currentRepo ?? URL(fileURLWithPath: controller.startupDirectory ?? NSHomeDirectory())) },
                onCreateFile: { newFileIn(currentRepo ?? URL(fileURLWithPath: controller.startupDirectory ?? NSHomeDirectory())) },
                onPush: { runGitSync(.push) },
                onPull: { runGitSync(.pull) },
                onFetch: { runGitSync(.fetch) }
            )
.padding(.horizontal, 8)
.padding(.top, pillTopInset)
.padding(.bottom, 6)

            // Git side panel for the active selection.
            if let panel = gitPanel, let repo = currentRepo {
                GitSidePanel(
                    kind: panel,
                    status: git,
                    repo: repo,
                    syncAction: gitSyncAction,
                    syncResult: gitSyncResult,
                    onCommit: { commit(msg: $0) },
                    onPush: { runGitSync(.push) },
                    onPull: { runGitSync(.pull) },
                    onFetch: { runGitSync(.fetch) },
                    onClose: { gitPanel = nil }
                )
                .environmentObject(controller)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }

            if !treeCollapsed {
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
                    FolderRow(
                        node: node,
                        onSelect: { selectedNodeURL = $0 },
                        onNew: { dir, isFolder in create(isFolder ? .folder : .file, in: dir) },
                        onDelete: { deleteNode($0) }
                    )
                }
            }
        }
    }

    // MARK: - Creation

    private enum CreateKind { case file, folder }

    /// Create inside the directory of the selected/focused tree node (fallback:
    /// the focused terminal's cwd, then the first favorite), then splice the new
    /// node into the loaded tree so no folder collapses.
    private func create(_ kind: CreateKind) {
        create(kind, in: defaultCreateDir())
    }

    /// Create `kind` directly inside `dirURL`, then splice it into the loaded
    /// tree at that exact path.
    private func create(_ kind: CreateKind, in dirURL: URL) {
        let fm = FileManager.default
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

    /// Directory a creation should target: the selected node (folder → inside
    /// it; file → its parent), else the focused terminal cwd, else first root.
    private func defaultCreateDir() -> URL {
        if let sel = selectedNodeURL {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: sel.path, isDirectory: &isDir), isDir.boolValue {
                return sel
            }
            return sel.deletingLastPathComponent()
        }
        let cwd = controller.activeCwd ?? roots.first?.url.path ?? NSHomeDirectory()
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue {
            return URL(fileURLWithPath: cwd)
        }
        return roots.first?.url ?? URL(fileURLWithPath: NSHomeDirectory())
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

    /// Remove the deleted node from the already-loaded tree IN PLACE, preserving
    /// `expandedPaths` and `treeCollapsed` (no `reloadRoots()` that would reset
    /// the whole tree).
    private func deleteNode(_ url: URL) {
        let _ = try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        removeNodeFromTree(url)
        refreshGit()
    }

    private func removeNodeFromTree(_ url: URL) {
        let target = url.standardizedFileURL.path
        func recurse(_ parent: FileNode) -> Bool {
            guard let kids = parent.children else { return false }
            if kids.contains(where: { $0.url.standardizedFileURL.path == target }) {
                parent.children?.removeAll { $0.url.standardizedFileURL.path == target }
                return true
            }
            for child in kids where child.isDirectory {
                if recurse(child) { return true }
            }
            return false
        }
        for root in roots where recurse(root) { break }
    }

    private func reloadRoots() {
        roots = controller.favorites.map { FileNode(url: $0, isDirectory: true) }
    }

    // MARK: - Git

    private var currentRepo: URL? {
        let cwd = controller.activeCwd.map { URL(fileURLWithPath: $0) } ?? roots.first?.url
        return cwd.flatMap { GitService.repoRoot(for: $0) }
    }
    /// Create a uniquely-named folder at `base` (the active repo root, else the
    /// user's home) and refresh the tree.
    private func newFolderIn(_ base: URL?) {
        guard let base = base else { return }
        var n = 1
        var url = base.appendingPathComponent("New Folder")
        while FileManager.default.fileExists(atPath: url.path) {
            n += 1
            url = base.appendingPathComponent("New Folder \(n)")
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        reloadRoots()
    }

    /// Create a uniquely-named empty file at `base` and refresh the tree.
    private func newFileIn(_ base: URL?) {
        guard let base = base else { return }
        var n = 1
        var url = base.appendingPathComponent("New File.txt")
        while FileManager.default.fileExists(atPath: url.path) {
            n += 1
            url = base.appendingPathComponent("New File \(n).txt")
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        reloadRoots()
    }

    private func refreshGit() {
        guard let repo = currentRepo else { git = GitStatus.empty; return }
        let binding = $git
        Task.detached {
            let s = GitService.status(in: repo)
            Task { @MainActor in binding.wrappedValue = s }
        }
    }

    /// Run a sync action and surface its output in the sync panel.
    private func runGitSync(_ op: GitOp) {
        guard let repo = currentRepo else { return }
        gitSyncAction = op.rawValue
        gitSyncResult = "Running \(op.rawValue)…"
        gitPanel = .sync
        let r = repo
        Task.detached {
            let out: String
            switch op {
            case .push: out = GitService.push(in: r)
            case .pull: out = GitService.pull(in: r)
            case .fetch: out = GitService.fetch(in: r)
            }
            Task { @MainActor in
                gitSyncResult = out.isEmpty ? "\(op.rawValue) finished." : out
                refreshGit()
            }
        }
    }

    private func commit(msg: String) {
        guard let r = currentRepo, !msg.isEmpty else { return }
        let out = GitService.commit(in: r, message: msg)
        gitSyncAction = "commit"
        gitSyncResult = out.isEmpty ? "Committed." : out
        gitPanel = .sync
        refreshGit()
    }
}

/// Compact icon button with a subtle hover wash — matches the sidebar header
/// size (11pt glyph) and adapts to dark/light themes via `Color.primary`.
private struct HeaderIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hover = false
    @EnvironmentObject private var controller: TerminalController

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11))
                .foregroundStyle(hover ? Color(controller.accentColor) : .secondary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hover ? Color.primary.opacity(0.12) : .clear)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover = $0 }
    }
}

/// Rounded git command pill: create-file/folder plus branch, changes, push,
/// pull, fetch and log icons. Branch/changes/log open their own side panel;
/// push/pull/fetch run the action and open the sync panel.
private struct GitToolbarPill: View {
    @Binding var status: GitStatus
    @Binding var panel: GitPanelKind?
    @Binding var syncAction: String
    @Binding var syncResult: String
    @Binding var treeCollapsed: Bool
    var onCreateFolder: () -> Void
    var onCreateFile: () -> Void
    var onPush: () -> Void
    var onPull: () -> Void
    var onFetch: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            HeaderIconButton(systemName: treeCollapsed ? "sidebar.right" : "sidebar.left", help: "Show/Hide file tree") { treeCollapsed.toggle() }
            Divider().frame(height: 16).padding(.horizontal, 2)
            HeaderIconButton(systemName: "folder.badge.plus", help: "New folder") { onCreateFolder() }
            HeaderIconButton(systemName: "doc.badge.plus", help: "New file") { onCreateFile() }
            Divider().frame(height: 16).padding(.horizontal, 2)
            HeaderIconButton(systemName: "arrow.branch", help: "Branch") { panel = .branch }
            HeaderIconButton(systemName: "checklist", help: "Changes") { panel = .changes }
            HeaderIconButton(systemName: "arrow.up.to.line", help: "Push") { onPush() }
            HeaderIconButton(systemName: "arrow.down.to.line", help: "Pull") { onPull() }
            HeaderIconButton(systemName: "icloud.and.arrow.down", help: "Fetch") { onFetch() }
            HeaderIconButton(systemName: "clock", help: "Log") { panel = .log }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.75))
        )
        .overlay(
            Capsule()
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
    }
}

/// A git side panel opened from the toolbar pill. Shows the requested surface:
/// branch + ahead/behind plus commit/push/pull/fetch controls, the working-tree
/// change list, recent commits, or the output of a sync action.
private struct GitSidePanel: View {
    let kind: GitPanelKind
    let status: GitStatus
    let repo: URL
    let syncAction: String
    let syncResult: String
    var onCommit: (String) -> Void
    var onPush: () -> Void
    var onPull: () -> Void
    var onFetch: () -> Void
    var onClose: () -> Void
    @EnvironmentObject private var controller: TerminalController
    @State private var commitMsg = ""
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(controller.accentColor))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(controller.foregroundColor))
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            Divider()
            content
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.10))
        )
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .branch:  branchContent
        case .changes: changesContent
        case .log:     logContent
        case .sync:    syncContent
        }
    }

    private var branchContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if status.isRepo {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.branch").foregroundStyle(.secondary)
                    Text(status.branch)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(controller.foregroundColor))
                    Spacer(minLength: 0)
                    if status.ahead > 0 || status.behind > 0 {
                        Text("↑\(status.ahead)  ↓\(status.behind)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 12) {
                    Label("\(status.modified) modified", systemImage: "pencil")
                        .font(.caption).foregroundStyle(.secondary)
                    Label("\(status.untracked) untracked", systemImage: "plus")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Text("Commit")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    TextField("Commit message", text: $commitMsg)
                        .textFieldStyle(.roundedBorder)
                    Button("Commit") {
                        onCommit(commitMsg)
                        commitMsg = ""
                    }
                    .disabled(commitMsg.isEmpty)
                }
                .controlSize(.small)
                HStack(spacing: 8) {
                    Button("Push") { onPush() }
                    Button("Pull") { onPull() }
                    Button("Fetch") { onFetch() }
                    Spacer(minLength: 0)
                }
                .controlSize(.small)
            } else {
                Text("Not a git repository")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var changesContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            CapsuleSearchField(text: $filter, placeholder: "Filter changes")
                .capsuleSearchStyle()
            if filteredChanges.isEmpty {
                Text(status.changes.isEmpty ? "Working tree clean" : "No matches")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(filteredChanges) { c in
                            HStack(spacing: 8) {
                                Text(c.status)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(changeColor(c.status))
                                    .frame(width: 26, alignment: .leading)
                                Text(c.path)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color(controller.foregroundColor))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
    }

    private var filteredChanges: [GitChange] {
        guard !filter.isEmpty else { return status.changes }
        return status.changes.filter { $0.path.localizedCaseInsensitiveContains(filter) }
    }

    private var logContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if status.recentCommits.isEmpty {
                Text("No commits")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(status.recentCommits, id: \.self) { c in
                            Text(c)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
    }

    private var syncContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: iconForSync).foregroundStyle(.secondary)
                Text(syncAction.isEmpty ? "Sync" : syncAction.capitalized)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(controller.foregroundColor))
                Spacer(minLength: 0)
            }
            ScrollView {
                Text(syncResult.isEmpty ? "No output." : syncResult)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
        }
    }

    private var icon: String {
        switch kind {
        case .branch:  return "arrow.branch"
        case .changes: return "checklist"
        case .log:     return "clock"
        case .sync:    return iconForSync
        }
    }

    private var title: String {
        switch kind {
        case .branch:  return "Branch"
        case .changes: return "Changes"
        case .log:     return "Log"
        case .sync:    return syncAction.isEmpty ? "Sync" : syncAction.capitalized
        }
    }

    private var iconForSync: String {
        switch syncAction {
        case "push":  return "arrow.up.to.line"
        case "pull":  return "arrow.down.to.line"
        case "fetch": return "icloud.and.arrow.down"
        default:      return "arrow.triangle.branch"
        }
    }

    private func changeColor(_ s: String) -> Color {
        if s.contains("?") { return .orange }
        if s.contains("U") { return .purple }
        if s.contains("D") { return .red }
        if s.contains("A") { return .green }
        if s.contains("M") { return .yellow }
        return .secondary
    }
}

/// A project shown as a card in the sidebar. Tap to `cd` the terminal into it;
/// the name (alias only — never the real folder) + accent color are editable
/// inline, and the × removes it. Themed with the active accent/foreground.
private struct ProjectCard: View {
    let project: SidebarProject
    @EnvironmentObject private var controller: TerminalController
    @State private var hover = false

    private var isActive: Bool { controller.activeCwd == project.path }
    private var accent: Color { Color(controller.accentColor) }

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(nsColor: NSColor(hex: project.colorHex) ?? controller.accentColor))
                .frame(width: 4, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                TextField("", text: Binding(
                    get: { project.name },
                    set: { controller.renameProject(project.id, $0) }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(controller.foregroundColor))
                Text(project.path)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            ColorPicker("", selection: Binding(
                get: { Color(nsColor: NSColor(hex: project.colorHex) ?? controller.accentColor) },
                set: { controller.setProjectColor(project.id, hex(from: $0)) }
            )).labelsHidden()
                .frame(width: 16)
            Button(action: { controller.removeProject(project.id) }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove project")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isActive ? accent.opacity(0.18)
                       : hover ? Color.primary.opacity(0.07)
                       : Color(nsColor: .controlBackgroundColor).opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isActive ? accent.opacity(0.5) : Color.primary.opacity(0.08), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { controller.cd(project.path) }
        .onHover { hover = $0 }
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
