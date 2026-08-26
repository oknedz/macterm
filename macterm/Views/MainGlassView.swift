import SwiftUI

/// Single source of truth for the glass surface + spacing rhythm so every
/// panel (title bar, sidebar, terminal) aligns to the same margins/gaps/radius.
enum GlassMetrics {
    /// Gap between the window edge and any panel.
    static let margin: CGFloat = 5
    /// Gap between the title bar and the content row, and between sidebar/terminal.
    static let gap: CGFloat = 5
    /// Corner radius shared by every glass panel and the terminal view.
    static let radius: CGFloat = 8
    /// Height of the tab strip inside the title bar.
    static let barHeight: CGFloat = 25
}

/// Liquid-glass surface (macOS 26 native) with an NSVisualEffectView fallback
/// for the 15.0 deployment target.
extension View {
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat = GlassMetrics.radius) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(
                VisualEffectView(
                    material: NSVisualEffectView.Material.sidebar,
                    blendingMode: NSVisualEffectView.BlendingMode.withinWindow
                )
                .cornerRadius(cornerRadius)
            )
            .cornerRadius(cornerRadius)
        }
    }
}

struct MainGlassView: View {
    @EnvironmentObject private var controller: TerminalController

    var body: some View {
        VStack(spacing: 0) {
            // Top bar: tabs inline with the traffic lights
            // (Removed .edgesIgnoringSafeArea from here)
            TitleBar()
            
            HStack(spacing: 0) {
                Sidebar()
                    .frame(width: controller.sidebarCollapsed ? 0 : controller.sidebarWidth)
                    .opacity(controller.sidebarCollapsed ? 0 : 1)
                    .glassPanel()
                    .clipped()
                    .padding(.trailing, controller.sidebarCollapsed ? 0 : GlassMetrics.gap)
                TerminalArea()
                    .glassPanel()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 6)
            .padding(.horizontal, GlassMetrics.margin)
            .padding(.bottom, GlassMetrics.margin)
            // Removed the .padding(.top, 2) entirely
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: controller.sidebarCollapsed)
        }
        // 1. Tell the ENTIRE container to ignore the safe area so nothing gets pushed down
        .ignoresSafeArea(edges: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        
        // 2. Hide WindowConfigurator in the background so it takes ZERO layout space
        .background(WindowConfigurator())
        
        .background(
            VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()
        )
    }
}
