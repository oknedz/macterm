import SwiftUI

struct Sidebar: View {
    @EnvironmentObject private var controller: TerminalController
    @State private var roots: [FileNode] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Favorites")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(roots) { node in
                        FolderRow(node: node)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
        .onAppear { roots = controller.favorites.map { FileNode(url: $0, isDirectory: true) } }
    }
}
