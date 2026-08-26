import SwiftUI
import AppKit
/// Recursive folder row: a plain tap expands/collapses the tree; a ⌘-tap
/// `cd`s the active terminal into that directory (bidirectional — the shell
/// reports its cwd back and the matching row highlights).
struct FolderRow: View {
    @ObservedObject var node: FileNode
    @EnvironmentObject private var controller: TerminalController
    @State private var expanded = false
    @State private var hover = false

    private var isActive: Bool {
        guard let cwd = controller.activeCwd else { return false }
        return node.url.path == cwd
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9))
                    .frame(width: 10)
                Image(systemName: expanded ? "folder.fill" : "folder")
                    .foregroundStyle(.yellow)
                Text(node.name).lineLimit(1).font(.system(size: 12))
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(rowBackground)
            .contentShape(Rectangle())
            .onTapGesture {
                expanded.toggle()
                if expanded { node.loadChildren() }
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
        if isActive { return Color.primary.opacity(0.14) }
        return hover ? Color.white.opacity(0.06) : Color.clear
    }
}

private struct FileRow: View {
    let node: FileNode
    @State private var hover = false
    @EnvironmentObject private var controller: TerminalController

    private var icon: (name: String, color: Color) {
        fileIcon(for: node.url)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon.name)
                .font(.system(size: 11))
                .foregroundStyle(icon.color)
                .frame(width: 14, alignment: .center)
            Text(node.name).lineLimit(1).font(.system(size: 12))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(hover ? Color.white.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { controller.openFile(node.url) }
    }
}

/// Map a file extension to a modern, language-tinted SF Symbol so the file
/// tree reads like a real editor: distinct glyphs where SF Symbols ships
/// them, brand-tinted otherwise.
private func fileIcon(for url: URL) -> (name: String, color: Color) {
    switch url.pathExtension.lowercased() {
    // Apple / Swift
    case "swift":
        return ("swift", .orange)
    case "xcodeproj", "xcworkspace", "swiftpm", "xcframework":
        return ("hammer", .gray)

    // Web
    case "html", "htm":
        return ("chevron.left.slash.chevron.right", .orange)
    case "css", "scss", "sass", "less":
        return ("paintbrush", .blue)
    case "js", "jsx", "mjs", "cjs":
        return ("curlybraces", .yellow)
    case "ts", "tsx":
        return ("curlybraces", Color(red: 0.20, green: 0.50, blue: 0.95))
    case "json":
        return ("ellipsis.curlybraces", .yellow)

    // Scripting
    case "py":
        return ("text.line.first.and.arrowtriangle.forward", Color(red: 0.27, green: 0.45, blue: 0.85))
    case "rb":
        return ("curlybraces", .red)
    case "php":
        return ("curlybraces", Color(red: 0.55, green: 0.35, blue: 0.70))
    case "lua":
        return ("curlybraces", Color(red: 0.10, green: 0.40, blue: 0.70))
    case "sh", "zsh", "bash", "command", "fish":
        return ("terminal", .green)

    // Systems
    case "rs":
        return ("curlybraces", Color(red: 0.85, green: 0.45, blue: 0.20))
    case "go":
        return ("curlybraces", Color(red: 0.20, green: 0.70, blue: 0.85))
    case "c", "h":
        return ("curlybraces", .blue)
    case "cpp", "hpp", "cc", "hh":
        return ("curlybraces", Color(red: 0.30, green: 0.50, blue: 0.95))
    case "java", "kt":
        return ("curlybraces", Color(red: 0.85, green: 0.30, blue: 0.25))
    case "dart":
        return ("curlybraces", Color(red: 0.10, green: 0.70, blue: 0.85))
    case "sql":
        return ("tablecells", Color(red: 0.30, green: 0.50, blue: 0.80))

    // Data / config
    case "yaml", "yml", "toml":
        return ("ellipsis.curlybraces", .gray)
    case "plist", "xml":
        return ("chevron.left.slash.chevron.right", .gray)
    case "ini", "env", "lock", "conf", "cfg":
        return ("doc.plaintext", .gray)
    case "md", "markdown", "rst", "adoc":
        return ("doc.richtext", Color(red: 0.40, green: 0.60, blue: 0.90))
    case "txt":
        return ("doc.plaintext", .secondary)

    // Media / docs
    case "png", "jpg", "jpeg", "gif", "svg", "webp", "heic", "bmp":
        return ("photo", .pink)
    case "pdf":
        return ("doc.richtext", .red)
    case "zip", "gz", "tgz", "tar", "dmg", "7z", "rar":
        return ("archivebox", .brown)

    // VCS
    case "git", "gitignore", "gitattributes", "gitmodules", "gitconfig":
        return ("git.branch", .orange)

    // Apps / bundles
    case "app":
        return ("app", .blue)

    default:
        return ("doc", .secondary)
    }
}
