import SwiftUI

/// Single source of truth for the glass surface + spacing rhythm so every
/// panel (title bar, sidebar, terminal) aligns to the same margins/gaps/radius.
enum GlassMetrics {
    /// Gap between the window edge and any panel.
    static let margin: CGFloat = 5
    /// Gap between the title bar and the content row, and between sidebar/terminal.
    static let gap: CGFloat = 5
    /// Corner radius shared by every glass panel and the terminal view.
    static let radius: CGFloat = 14
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
            TitleBar()
             
            ZStack(alignment: .trailing) {
                // Main content area - sidebar + terminal (terminal never shrinks)
                HStack(spacing: 0) {
                    Sidebar()
                        .frame(width: controller.sidebarCollapsed ? 0 : controller.sidebarWidth)
                        .opacity(controller.sidebarCollapsed ? 0 : 1)
                        .glassPanel()
                        .clipped()
                        .padding(.trailing, controller.sidebarCollapsed ? 0 : GlassMetrics.gap)
                    
                    TerminalArea()
                        .glassPanel()
                        .layoutPriority(1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                // Agent Panel - Full height overlay on the right
                if controller.showAgentPanel {
                    AgentPanelMain()
                        .glassPanel()
                        .frame(width: 420)
                        .frame(maxHeight: .infinity)
                        .padding(.trailing, GlassMetrics.margin)
                        .padding(.top, 6)
                        .padding(.bottom, GlassMetrics.margin)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        .zIndex(1)
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: controller.showAgentPanel)
            .padding(.top, 6)
            .padding(.horizontal, GlassMetrics.margin)
            .padding(.bottom, GlassMetrics.margin)
        }
        .ignoresSafeArea(edges: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WindowConfigurator())
        
        .preferredColorScheme(controller.theme.isDark ? .dark : .light)
    }
}

