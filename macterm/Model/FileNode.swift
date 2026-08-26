import Foundation
import SwiftUI

/// A filesystem node for the sidebar tree. Children are loaded lazily on
/// first expand so the tree stays cheap even over large directories.
final class FileNode: Identifiable, ObservableObject {
    let url: URL
    let name: String
    let isDirectory: Bool

    /// `nil` = not yet loaded; `[]` = loaded and empty.
    @Published var children: [FileNode]?

    var id: URL { url }

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        self.isDirectory = isDirectory
    }

    func loadChildren() {
        guard isDirectory, children == nil else { return }
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        children = urls.compactMap { u in
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            return FileNode(url: u, isDirectory: isDir)
        }
        .sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
