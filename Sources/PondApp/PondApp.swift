import SwiftUI

@main
struct PondApp: App {
    @StateObject private var selectedCollectionPersistence = SelectedCollectionPersistence()
    @StateObject private var settingsModel = TaskAppModel()

    var body: some Scene {
        WindowGroup {
            TaskWindowRoot(initialSelectedCollection: selectedCollectionPersistence.initialSelectedCollection)
                .environmentObject(selectedCollectionPersistence)
        }
        .defaultSize(PondMainWindowState.initialContentSize)
        .commands {
            TaskCommands()
        }

        Settings {
            SettingsView()
                .environmentObject(settingsModel)
        }
    }
}

private struct TaskWindowRoot: View {
    @EnvironmentObject private var selectedCollectionPersistence: SelectedCollectionPersistence
    @StateObject private var model: TaskAppModel

    init(initialSelectedCollection: String) {
        _model = StateObject(wrappedValue: TaskAppModel(initialSelectedCollection: initialSelectedCollection))
    }

    var body: some View {
        ContentView()
            .environmentObject(model)
            .focusedObject(model)
            .background(SelectedCollectionWindowRegistration(model: model, persistence: selectedCollectionPersistence))
    }
}

private struct TaskCommands: Commands {
    @FocusedObject private var model: TaskAppModel?

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
