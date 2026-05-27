import AppKit
import SwiftUI
import TodoCore

struct ContentView: View {
    @EnvironmentObject private var model: TodoAppModel
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("alwaysOnTop") private var alwaysOnTop = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(SidebarLayout.width)
        } detail: {
            DetailView()
        }
        .frame(minWidth: 480, minHeight: 320)
        .background(WindowLevelController(alwaysOnTop: alwaysOnTop))
        .background(TitlebarDescriptionController(description: model.titlebarDescription))
        .background(
            LocalKeyDownHandler(isActive: model.collectionDeletionRequest != nil) { event in
                confirmDeleteDialogOnDefaultKey(event)
            }
        )
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.reload()
                model.refreshCLIStatus()
            }
        }
        .alert(
            "Delete Collection?",
            isPresented: Binding(
                get: { model.collectionDeletionRequest != nil },
                set: { isPresented in
                    if !isPresented {
                        model.cancelDeleteCollection()
                    }
                }
            ),
            presenting: model.collectionDeletionRequest,
            actions: { _ in
                Button("Delete", role: .destructive) {
                    model.confirmDeleteRequestedCollection()
                }
                .keyboardShortcut(.defaultAction)

                Button("Cancel", role: .cancel) {
                    model.cancelDeleteCollection()
                }
            },
            message: { collection in
                Text(verbatim: deleteCollectionMessage(for: collection))
            }
        )
        .alert(
            "Error",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        model.errorMessage = nil
                    }
                }
            ),
            actions: {
                Button("OK") {
                    model.errorMessage = nil
                }
            },
            message: {
                Text(model.errorMessage ?? "")
            }
        )
    }

    private func confirmDeleteDialogOnDefaultKey(_ event: NSEvent) -> Bool {
        guard model.collectionDeletionRequest != nil, event.isPlainKey else {
            return false
        }

        switch event.keyCode {
        case KeyCode.returnKey, KeyCode.keypadEnter:
            model.confirmDeleteRequestedCollection()
            return true
        default:
            return false
        }
    }
}

private func deleteCollectionMessage(for collection: TodoCollectionSummary) -> String {
    let itemLabel = collection.totalCount == 1 ? "todo" : "todos"
    return "This will delete \"\(collection.name)\" and \(collection.totalCount) \(itemLabel)."
}
