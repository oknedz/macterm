import SwiftUI

struct TerminalArea: View {
    @EnvironmentObject private var controller: TerminalController

    var body: some View {
        if let tab = controller.tabs.first(where: { $0.id == controller.activeTabId }) {
            render(tab.layout)
        } else {
            EmptyView()
        }
    }

    private func render(_ node: PaneNode) -> AnyView {
        switch node {
        case .terminal(let id):
            guard let session = controller.sessions.first(where: { $0.id == id }) else {
                return AnyView(EmptyView())
            }
            if case .editor(let fileURL) = session.kind {
                return AnyView(
                    EditorView(url: fileURL, buffer: controller.editorBufferBinding(for: session.id))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(controller.terminalPadding)
                )
            }
            return AnyView(
                TerminalViewRepresentable(sessionId: id, controller: controller)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: GlassMetrics.radius, style: .continuous))
                    .padding(controller.terminalPadding)
                .overlay(
                    RoundedRectangle(cornerRadius: GlassMetrics.radius, style: .continuous)
                        .stroke(controller.focusedSessionId == id ? Color(nsColor: .separatorColor) : Color.clear,
                                lineWidth: 1)
                )
            )
        case .split(_, let dir, let a, let b):
            if dir == .vertical {
                return AnyView(HSplitView { render(a); render(b) })
            } else {
                return AnyView(VSplitView { render(a); render(b) })
            }
        }
    }
}
