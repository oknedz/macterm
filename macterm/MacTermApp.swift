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
                commandButton("editorSave")
                commandButton("editorRevert")
            }
            CommandGroup(after: .windowList) {
                commandButton("toggleSidebar")
                commandButton("reloadFileTree")
                commandButton("clearTerminal")
                commandButton("clearScrollbackOnly")
                Divider()
                commandButton("themeCycleNext")
                commandButton("themeCyclePrev")
                Divider()
                commandButton("fontBigger")
                commandButton("fontSmaller")
                commandButton("fontReset")
                Divider()
                commandButton("copyActivePath")
                commandButton("toggleMouseReporting")
                commandButton("toggleOptionAsMeta")
                Divider()
                commandButton("minimizeWindow")
                Divider()
                ForEach(1...9, id: \.self) { n in
                    commandButton("goToTab.\(n)")
                }
            }
            CommandGroup(replacing: .pasteboard) {
                commandButton("undo")
                commandButton("redo")
                commandButton("cut")
                commandButton("copy")
                commandButton("paste")
                commandButton("selectAll")
            }
            // User-defined combos (Settings → Keys → Custom): hidden items so
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
