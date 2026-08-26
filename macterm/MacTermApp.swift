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
                Button("New Tab") { controller.newTab() }
                    .keyboardShortcut(controller.keyboardShortcut(for: "newTab"))
            }
            CommandGroup(after: .windowList) {
                Button("Close Tab") { controller.closeActive() }
                    .keyboardShortcut(controller.keyboardShortcut(for: "closeTab"))
                Button("Toggle Sidebar") { controller.toggleSidebar() }
                    .keyboardShortcut(controller.keyboardShortcut(for: "toggleSidebar"))
                Divider()
                Button("Split Right") { controller.splitFocused(vertical: true) }
                    .keyboardShortcut("d", modifiers: .command)
                Button("Split Down") { controller.splitFocused(vertical: false) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Divider()
                ForEach(Array(controller.tabs.prefix(9).enumerated()), id: \.element.id) { i, t in
                    Button("Tab \(i + 1)") {
                        controller.activeTabId = t.id
                        controller.focusedSessionId = t.layout.firstLeaf ?? controller.focusedSessionId
                    }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
                Divider()
                Button("Clear") { controller.clearActive() }
                    .keyboardShortcut(controller.keyboardShortcut(for: "clear"))
            }
        }
        .windowStyle(.hiddenTitleBar)
        Settings {
            SettingsRoot()
                .environmentObject(controller)
        }
        .windowStyle(.automatic)
    }
}
