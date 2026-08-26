import SwiftUI

/// File sidebar. Header row: search field (left) + new-folder / new-file
/// icon buttons (right) — the old "Favorites" label is gone.
///
/// Robustness contract: the view stays mounted across sidebar toggles and
/// tab switches (MainGlassView only collapses width/opacity), so `@State`
/// here — roots, expansions, search text — survives all of it by design.
/// Creation inserts into already-loaded nodes instead of rebuilding roots,
/// so expanded folders never collapse.
struct Sidebar: View {
    @EnvironmentObject private var controller: TerminalController
    @State private var roots: [FileNode] = []
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Inline header: search on the left, create actions on the right.
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                TextField("Search files…", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .disableAutocorrection(true)
                Spacer(minLength: 2)
                Button {
                    create(.folder)
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("New folder in the active terminal's directory")
                Button {
                    create(.file)
                } label: {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("New file in the active terminal's directory")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)

            if query.isEmpty {
                treeList
            } else {
                searchResults
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
        .onAppear { if roots.isEmpty { reloadRoots() } }
        .onReceive(NotificationCenter.default.publisher(for: .reloadFileTree)) { _ in
            reloadRoots()
        }
    }

    private var query: String {
        search.trimmingCharacters(in: .whitespaces)
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

    // MARK: - Search mode

    /// Flat matches from a bounded recursive walk under every favorite root.
    private var searchResults: some View {
        let q = query.lowercased()
        var hits: [URL] = []
        for root in roots {
            collectMatches(under: root.url, query: q, depth: 0, into: &hits)
        }
        return AnyView(
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(hits, id: \.self) { url in
                        resultRow(url)
                    }
                    if hits.isEmpty {
                        Text("No matches")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                }
            }
        )
    }

    private func resultRow(_ url: URL) -> some View {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let slot = isDir ? nil : fileSlot(for: url)
        let tint: Color = {
            if let slot { return Color(nsColor: controller.theme.hierarchyColors[slot]) }
            return Color(nsColor: controller.theme.hierarchyColor(level: 0))
        }()
        return HStack(spacing: 6) {
            Image(systemName: isDir ? "folder.fill" : iconName(for: url))
                .font(.system(size: 11))
                .foregroundStyle(tint)
                .frame(width: 14)
            Text(url.lastPathComponent)
                .font(.system(size: 12))
                .lineLimit(1)
            Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            if isDir {
                controller.cd(url.path)
            } else {
                controller.openFile(url)
            }
        }
    }

    private func collectMatches(under url: URL, query: String, depth: Int, into hits: inout [URL]) {
        guard depth <= 4, hits.count < 300 else { return }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return }
        for item in items {
            let name = item.lastPathComponent
            if name == ".git" || name == "node_modules" || name == "DerivedData" { continue }
            if name.lowercased().contains(query) { hits.append(item) }
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir { collectMatches(under: item, query: query, depth: depth + 1, into: &hits) }
        }
    }

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
}
