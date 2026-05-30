import SwiftUI

private struct TaskAppModelFocusedValueKey: FocusedValueKey {
    typealias Value = TaskAppModel
}

extension FocusedValues {
    var taskAppModel: TaskAppModel? {
        get { self[TaskAppModelFocusedValueKey.self] }
        set { self[TaskAppModelFocusedValueKey.self] = newValue }
    }
}

@main
struct PondApp: App {
    @State private var selectedCollectionPersistence = SelectedCollectionPersistence()
    @State private var settingsModel = TaskAppModel()

    var body: some Scene {
        WindowGroup {
            TaskWindowRoot(initialSelectedCollection: selectedCollectionPersistence.initialSelectedCollection)
                .environment(selectedCollectionPersistence)
        }
        .defaultSize(PondMainWindowState.initialContentSize)
        .commands {
            TaskCommands()
        }

        Settings {
            SettingsView()
                .environment(settingsModel)
        }
    }
}

private struct TaskWindowRoot: View {
    @Environment(SelectedCollectionPersistence.self) private var selectedCollectionPersistence
    @State private var model: TaskAppModel

    init(initialSelectedCollection: String) {
        _model = State(initialValue: TaskAppModel(initialSelectedCollection: initialSelectedCollection))
    }

    var body: some View {
        ContentView()
            .environment(model)
            .focusedValue(\.taskAppModel, model)
            .background(SelectedCollectionWindowRegistration(model: model, persistence: selectedCollectionPersistence))
    }
}

private struct TaskCommands: Commands {
    @FocusedValue(\.taskAppModel) private var model: TaskAppModel?

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
