import SwiftUI

struct TerminalArea: View {
    @EnvironmentObject private var controller: TerminalController

    var body: some View {
        if let tab = controller.tabs.first(where: { $0.id == controller.activeTabId }) {
            // Zoomed tab: render ONLY the focused pane, full-size (<C-w>o analog).
            if tab.zoomFocused,
               let leaf = tab.layout.leaf(containing: controller.focusedSessionId) {
                AnyView(render(leaf))
            } else {
                AnyView(render(tab.layout))
            }
        } else {
            EmptyView()
        }
    }
    private func render(_ node: PaneNode) -> AnyView {
        switch node {
        case .terminal(let id):
            if let session = controller.sessions.first(where: { $0.id == id }) {
                if case .editor(let fileURL) = session.kind {
                    return AnyView(
                        EditorView(url: fileURL, buffer: controller.editorBufferBinding(for: session.id))
                            .id(session.id)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(controller.terminalPadding)
                    )
                } else {
                    return AnyView(
                        VStack(spacing: 0) {
                            TerminalViewRepresentable(sessionId: id, controller: controller)
                                .id(id)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: GlassMetrics.radius, style: .continuous))
                        .padding(controller.terminalPadding)
                        .overlay(
                            RoundedRectangle(cornerRadius: GlassMetrics.radius, style: .continuous)
                                .stroke(controller.focusedSessionId == id ? Color(nsColor: .separatorColor) : Color.clear,
                                        lineWidth: 1)
                        )
                    )
                }
            } else {
                return AnyView(EmptyView())
            }
        case .split(_, let dir, let a, let b):
            if dir == .vertical {
                return AnyView(HSplitView { render(a); render(b) })
            } else {
                return AnyView(VSplitView { render(a); render(b) })
            }
        }
    }
}

