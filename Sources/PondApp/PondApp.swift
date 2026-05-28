import SwiftUI

@main
struct PondApp: App {
    @StateObject private var selectedCollectionPersistence = SelectedCollectionPersistence()
    @StateObject private var settingsModel = TodoAppModel()

    var body: some Scene {
        WindowGroup {
            TodoWindowRoot(initialSelectedCollection: selectedCollectionPersistence.initialSelectedCollection)
                .environmentObject(selectedCollectionPersistence)
        }
        .defaultSize(width: 640, height: 360)
        .commands {
            TodoCommands()
        }

        Settings {
            SettingsView()
                .environmentObject(settingsModel)
        }
    }
}

private struct TodoWindowRoot: View {
    @EnvironmentObject private var selectedCollectionPersistence: SelectedCollectionPersistence
    @StateObject private var model: TodoAppModel

    init(initialSelectedCollection: String) {
        _model = StateObject(wrappedValue: TodoAppModel(initialSelectedCollection: initialSelectedCollection))
    }

    var body: some View {
        ContentView()
            .environmentObject(model)
            .focusedObject(model)
            .background(SelectedCollectionWindowRegistration(model: model, persistence: selectedCollectionPersistence))
    }
}

private struct TodoCommands: Commands {
    @FocusedObject private var model: TodoAppModel?

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()

            Button("Delete Collection") {
                model?.requestDeleteSelectedCollection()
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(model?.canDeleteSelectedCollection != true)
        }
    }
}
