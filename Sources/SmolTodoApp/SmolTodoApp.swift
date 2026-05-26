import SwiftUI

@main
struct SmolTodoApp: App {
    @StateObject private var model = TodoAppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
        .defaultSize(width: 640, height: 360)
        .commands {
            CommandGroup(after: .pasteboard) {
                Divider()

                Button("Delete Collection") {
                    model.requestDeleteSelectedCollection()
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!model.canDeleteSelectedCollection)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}
