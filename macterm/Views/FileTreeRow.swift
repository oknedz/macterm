import SwiftUI
import AppKit
/// Recursive folder row: a plain tap expands/collapses the tree; a ⌘-tap
/// `cd`s the active terminal into that directory (bidirectional — the shell
/// reports its cwd back and the matching row highlights).
struct FolderRow: View {
    @ObservedObject var node: FileNode
    @EnvironmentObject private var controller: TerminalController
    @State private var hover = false

    /// Expansion lives in the PERSISTED controller set (not local state), so
    /// the tree survives sidebar toggles, tab switches and relaunches.
    private var expanded: Bool {
        get { controller.expandedPaths.contains(node.url.standardizedFileURL.path) }
        set { controller.setExpanded(node.url.standardizedFileURL.path, newValue) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9))
                    .frame(width: 10)
                Image(systemName: expanded ? "folder.fill" : "folder")
                    .foregroundStyle(Color(nsColor: controller.theme.hierarchyColor(level: node.depth)))
                Text(node.name).lineLimit(1).font(.system(size: 12))
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(rowBackground)
            .contentShape(Rectangle())
            .onTapGesture {
                // Capture intent BEFORE mutating: the persisted setter flips
                // the published value synchronously, so reading `expanded`
                // afterwards would see the new state and skip loading.
                let willExpand = !expanded
                controller.setExpanded(node.url.standardizedFileURL.path, willExpand)
                if willExpand { node.loadChildren() }
            }
            .highPriorityGesture(
                TapGesture().modifiers(.command).onEnded {
                    controller.cd(node.url.path)
                }
            )
            .onHover { hover = $0 }
            if expanded, let kids = node.children {
                ForEach(kids) { child in
                    if child.isDirectory {
                        FolderRow(node: child).padding(.leading, 14)
                    } else {
                        FileRow(node: child).padding(.leading, 14)
                    }
                }
            }
        }
    }

    private var rowBackground: Color {
        if controller.activeCwd == node.url.path {
            return Color(nsColor: controller.accentColor).opacity(0.18)
        }
        // primary-based washes adapt to dark/light themes automatically
        return hover ? Color.primary.opacity(0.06) : Color.clear
    }
}

private struct FileRow: View {
    let node: FileNode
    @State private var hover = false
    @EnvironmentObject private var controller: TerminalController

    private var iconColor: Color {
        guard let slot = fileSlot(for: node.url) else { return Color.secondary }
        return Color(nsColor: controller.theme.hierarchyColors[slot])
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName(for: node.url))
                .font(.system(size: 11))
                .foregroundStyle(iconColor)
                .frame(width: 14, alignment: .center)
            Text(node.name).lineLimit(1).font(.system(size: 12))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(hover ? Color.primary.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { controller.openFile(node.url) }
    }
}
/// Map a file extension to an SF Symbol glyph plus a slot into the active
/// theme's hierarchy palette (nil = neutral secondary tint). Glyphs keep
/// their editor-style shapes; ALL colors now come from the theme.
func iconName(for url: URL) -> String {
    switch url.pathExtension.lowercased() {
    case "swift":                       return "swift"
    case "xcodeproj", "xcworkspace", "swiftpm", "xcframework": return "hammer"
    case "html", "htm":                 return "chevron.left.slash.chevron.right"
    case "css", "scss", "sass", "less": return "paintbrush"
    case "js", "jsx", "mjs", "cjs", "ts", "tsx": return "curlybraces"
    case "json":                        return "ellipsis.curlybraces"
    case "py":                          return "text.line.first.and.arrowtriangle.forward"
    case "rb", "php", "lua":            return "curlybraces"
    case "sh", "zsh", "bash", "command", "fish": return "terminal"
    case "rs", "go", "c", "h", "cpp", "hpp", "cc", "hh": return "curlybraces"
    case "java", "kt", "dart":          return "curlybraces"
    case "sql":                         return "tablecells"
    case "yaml", "yml", "toml":         return "ellipsis.curlybraces"
    case "plist", "xml":                return "chevron.left.slash.chevron.right"
    case "ini", "env", "lock", "conf", "cfg":  return "doc.plaintext"
    case "md", "markdown", "rst", "adoc":      return "doc.richtext"
    case "txt":                         return "doc.plaintext"
    case "png", "jpg", "jpeg", "gif", "svg", "webp", "heic", "bmp": return "photo"
    case "pdf":                         return "doc.richtext"
    case "zip", "gz", "tgz", "tar", "dmg", "7z", "rar": return "archivebox"
    case "git", "gitignore", "gitattributes", "gitmodules", "gitconfig": return "git.branch"
    case "app":                         return "app"
    default:                            return "doc"
    }
}

/// Slot into `AppTheme.hierarchyColors` (0=blue 1=cyan 2=green 3=yellow
/// 4=magenta 5=red) — nil renders as neutral secondary text.
func fileSlot(for url: URL) -> Int? {
    switch url.pathExtension.lowercased() {
    // Code — blue
    case "swift", "js", "jsx", "mjs", "cjs", "ts", "tsx", "py", "rb", "php",
         "lua", "rs", "go", "c", "h", "cpp", "hpp", "cc", "hh",
         "java", "kt", "dart", "sql", "app":
        return 0
    // Web / markup — cyan
    case "html", "htm", "css", "scss", "sass", "less", "xml", "plist":
        return 1
    // Scripts & shell — green
    case "sh", "zsh", "bash", "command", "fish":
        return 2
    // Data & config — yellow
    case "json", "yaml", "yml", "toml", "ini", "env", "lock", "conf", "cfg",
         "gitignore", "gitattributes", "gitmodules", "gitconfig":
        return 3
    // Docs & media — magenta
    case "md", "markdown", "rst", "adoc", "png", "jpg", "jpeg", "gif",
         "svg", "webp", "heic", "bmp":
        return 4
    // Archives, PDFs, VCS internals — red
    case "zip", "gz", "tgz", "tar", "dmg", "7z", "rar", "pdf", "git":
        return 5
    default:
        return nil
    }
}
