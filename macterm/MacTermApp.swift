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
                // Owns ⌘W here — placing it after the system Window menu let
                // the built-in Close Window shortcut win and minimize/close
                // the whole window instead of closing the focused pane.
                commandButton("closePane")
                Divider()
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
            // User-defined combos (Settings → Keys → Custom): hidden items so
            // their shortcuts fire globally like built-ins.
            CommandGroup(after: .windowList) {
                ForEach(controller.customBindings) { b in
                    Button(controller.title(for: b)) { controller.perform(b.action ?? b.id) }
                        .keyboardShortcut(controller.keyboardShortcut(for: b.id))
                }
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
