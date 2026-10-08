import SwiftUI

@main
struct MacTermApp: App {
    @StateObject private var controller = TerminalController()
    
    var body: some Scene {
        WindowGroup {
            MainGlassView()
                .environmentObject(controller)
                .frame(minWidth: 800, minHeight: 500)
        }
        .defaultSize(width: 1000, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {
                commandButton("newTab")
            }
            CommandMenu("Shell") {
                commandButton("closePane")
                Divider()
                commandButton("nextTab")
                commandButton("prevTab")
                commandButton("alternateTab")
                commandButton("newTabInCwd")
                Divider()
                commandButton("moveTabLeft")
                commandButton("moveTabRight")
                Divider()
                commandButton("splitRight")
                commandButton("splitDown")
                Divider()
                commandButton("focusLeft")
                commandButton("focusUp")
                commandButton("focusDown")
                commandButton("focusRight")
                commandButton("focusNextLeaf")
                commandButton("focusPrevLeaf")
                Divider()
                commandButton("zoomPaneToggle")
                commandButton("closeOtherPanes")
            }
            CommandMenu("Editor") {
                commandButton("showEditor")
                Divider()
                commandButton("search")
                commandButton("replace")
                commandButton("jumpToLine")
                Divider()
                commandButton("undo")
                commandButton("redo")
                Divider()
                commandButton("selectAll")
                commandButton("copy")
                commandButton("cut")
                commandButton("paste")
            }
            
            CommandMenu("View") {
                commandButton("toggleSidebar")
                commandButton("toggleDotFiles")
                Divider()
                commandButton("clearTerminal")
                commandButton("fontBigger")
                commandButton("fontSmaller")
                commandButton("fontReset")
                Divider()
                commandButton("themeCycleNext")
                commandButton("themeCyclePrev")
                Divider()
                commandButton("reloadFileTree")
            }
            
            CommandMenu("Edit") {
                commandButton("insertMu")
                commandButton("insertApprox")
                commandButton("insertCedilla")
                commandButton("insertIntegral")
                commandButton("insertTilde")
                commandButton("insertLessEqual")
                commandButton("insertPi")
                commandButton("insertBullet")
                commandButton("insertSection")
                commandButton("insertInfinity")
                commandButton("insertCent")
                commandButton("insertPound")
            }
            
            CommandGroup(after: .windowList) {
                commandButton("fullscreen")
                Divider()
                commandButton("minimize")
                commandButton("close")
            }
            
            CommandGroup(after: .windowList) {
                commandButton("showSettings")
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        
        Settings {
            SettingsRoot()
                .environmentObject(controller)
        }
        
        .windowStyle(.automatic)
    }
    
    private func commandButton(_ id: String) -> some View {
        let spec = TerminalController.commandCatalog.first { $0.id == id }
        return Button(spec?.title ?? id) { controller.perform(id) }
            .keyboardShortcut(controller.keyboardShortcut(for: id))
    }
}