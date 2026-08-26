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
            // Every item routes through `controller.perform` and takes its
            // shortcut from the same catalog the Shortcuts settings pane edits,
            // so rebinding in Settings updates the menu automatically.
            CommandGroup(replacing: .newItem) {
                commandButton("newTab")
            }
            CommandMenu("Shell") {
                commandButton("nextTab")
                commandButton("prevTab")
                Divider()
                commandButton("splitRight")
                commandButton("splitDown")
                Divider()
                commandButton("focusLeft")
                commandButton("focusUp")
                commandButton("focusDown")
                commandButton("focusRight")
            }
            CommandGroup(after: .windowList) {
                commandButton("closePane")
                commandButton("toggleSidebar")
                commandButton("clearTerminal")
                Divider()
                commandButton("fontBigger")
                commandButton("fontSmaller")
                commandButton("fontReset")
                Divider()
                ForEach(1...9, id: \.self) { n in
                    commandButton("goToTab.\(n)")
                }
            }
            CommandGroup(replacing: .pasteboard) {
                commandButton("copy")
                commandButton("paste")
            }
        }
        .windowStyle(.hiddenTitleBar)
        Settings {
            SettingsRoot()
                .environmentObject(controller)
        }
        .windowStyle(.automatic)
    }

    /// One menu item backed by the shared command catalog.
    @ViewBuilder
    private func commandButton(_ id: String) -> some View {
        let spec = TerminalController.commandCatalog.first { $0.id == id }
        Button(spec?.title ?? id) { controller.perform(id) }
            .keyboardShortcut(controller.keyboardShortcut(for: id))
    }
}
