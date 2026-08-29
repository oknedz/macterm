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
/// Glass chrome, gated by `glass`. On = macOS 26 Liquid Glass (or
/// `NSVisualEffectView` vibrancy on 15); off = a flat theme surface so the
/// existing non-glass appearance is preserved.
extension View {
    @ViewBuilder
    func glassPanel(glass: Bool, cornerRadius: CGFloat = GlassMetrics.radius) -> some View {
        if glass {
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
        } else {
            self.background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
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
             
            // Content row: terminal + sidebar + AI panel as HStack siblings with
            // mutually exclusive frames (no occlusion). Details below.
            HStack(spacing: GlassMetrics.gap) {
                if !controller.sidebarCollapsed {
                    Sidebar()
                        .frame(width: controller.sidebarWidth)
                        .frame(maxHeight: .infinity)
                        .glassPanel(glass: controller.liquidGlass)
                        .clipped()
                        .layoutPriority(1)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }

                TerminalArea()
                    .glassPanel(glass: controller.liquidGlass)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(0)

                if controller.showAgentPanel {
                    AgentPanelMain()
                        .glassPanel(glass: controller.liquidGlass)
                        .frame(width: 420)
                        .frame(maxHeight: .infinity)
                        .padding(.vertical, GlassMetrics.margin)
                        .layoutPriority(1)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: controller.showAgentPanel)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: controller.sidebarCollapsed)
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

