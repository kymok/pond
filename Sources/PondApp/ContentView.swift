import AppKit
import SwiftUI
import TaskCore

struct ContentView: View {
    @EnvironmentObject private var model: TaskAppModel
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("alwaysOnTop") private var alwaysOnTop = false
    @StateObject private var taskDragState = TaskDragState()
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(
                    min: SidebarLayout.minimumWidth,
                    ideal: SidebarLayout.minimumWidth,
                    max: SidebarLayout.maximumWidth
                )
        } detail: {
            DetailView()
        }
        .environmentObject(taskDragState)
        .frame(minWidth: 480, minHeight: 320)
        .background(WindowLevelController(alwaysOnTop: alwaysOnTop))
        .background(WindowStateController())
        .background(TaskDragEndMonitor(dragState: taskDragState))
        .background(LocalKeyDownHandler(isActive: true, onKeyDown: handleGlobalKeyDown))
        .sheet(item: $model.bulkStatusChangeRequest) { request in
            BulkStatusChangeSheet(
                request: request,
                confirm: model.confirmBulkStatusChange,
                cancel: model.cancelBulkStatusChange
            )
        }
        .sheet(item: $model.collectionPromptEditRequest) { request in
            CollectionPromptSheet(
                request: request,
                save: model.confirmCollectionPromptEdit,
                cancel: model.cancelCollectionPromptEdit
            )
        }
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

    private func handleGlobalKeyDown(_ event: NSEvent) -> Bool {
        guard event.window?.sheetParent == nil else {
            return false
        }

        switch event.keyCode {
        case KeyCode.pageUp:
            guard event.isPlainKey else {
                return false
            }

            selectAdjacentCollection(offset: -1)
            return true
        case KeyCode.pageDown:
            guard event.isPlainKey else {
                return false
            }

            selectAdjacentCollection(offset: 1)
            return true
        case KeyCode.arrowUp:
            guard event.isCommandOptionOnlyKey else {
                return false
            }

            selectAdjacentCollection(offset: -1)
            return true
        case KeyCode.arrowDown:
            guard event.isCommandOptionOnlyKey else {
                return false
            }

            selectAdjacentCollection(offset: 1)
            return true
        default:
            return false
        }
    }

    private func selectAdjacentCollection(offset: Int) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            model.selectAdjacentCollection(offset: offset)
        }
    }
}

private struct CollectionPromptSheet: View {
    let request: TaskCollectionPromptEditRequest
    let save: (TaskCollectionSummary, String) -> Void
    let cancel: () -> Void

    @State private var promptTemplate: String

    init(
        request: TaskCollectionPromptEditRequest,
        save: @escaping (TaskCollectionSummary, String) -> Void,
        cancel: @escaping () -> Void
    ) {
        self.request = request
        self.save = save
        self.cancel = cancel
        _promptTemplate = State(initialValue: request.collection.promptTemplate ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Collection Prompt")
                .font(.headline)

            PromptTemplateEditor(
                text: $promptTemplate,
                height: 180
            )

            HStack {
                Button("Reset to Default") {
                    promptTemplate = inheritedPromptTemplate
                }

                Button("Clear") {
                    promptTemplate = ""
                }
                .disabled(promptTemplate.isEmpty)

                Spacer()

                Button("Cancel") {
                    cancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    save(request.collection, promptTemplate)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var inheritedPromptTemplate: String {
        TaskPromptSettings.effectiveDefaultPromptTemplate
    }
}

private func deleteCollectionMessage(for collection: TaskCollectionSummary) -> String {
    let itemLabel = collection.totalCount == 1 ? "task" : "tasks"
    return "This will delete \"\(collection.displayName)\" and \(collection.totalCount) \(itemLabel)."
}

private enum BulkStatusSelection: Hashable {
    case noChange
    case status(TaskStatus)
}

private struct BulkStatusChangeSheet: View {
    let request: TaskBulkStatusChangeRequest
    let confirm: ([TaskStatus: TaskStatus]) -> Bool
    let cancel: () -> Void

    @State private var selections: [TaskStatus: BulkStatusSelection]

    init(
        request: TaskBulkStatusChangeRequest,
        confirm: @escaping ([TaskStatus: TaskStatus]) -> Bool,
        cancel: @escaping () -> Void
    ) {
        self.request = request
        self.confirm = confirm
        self.cancel = cancel
        _selections = State(
            initialValue: Dictionary(
                uniqueKeysWithValues: TaskStatus.allCases.map { ($0, BulkStatusSelection.noChange) }
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Bulk Change Statuses")
                .font(.headline)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 10) {
                ForEach(TaskStatus.allCases, id: \.self) { status in
                    GridRow {
                        statusLabel(for: status)
                            .frame(width: 128, alignment: .leading)

                        Picker("Change \(status.displayName) to", selection: selection(for: status)) {
                            Text("No Change").tag(BulkStatusSelection.noChange)

                            ForEach(TaskStatus.allCases, id: \.self) { replacement in
                                statusLabel(for: replacement)
                                    .tag(BulkStatusSelection.status(replacement))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 180, alignment: .leading)
                    }
                }
            }

            HStack {
                Spacer()

                Button("Cancel") {
                    cancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("OK") {
                    _ = confirm(replacements)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var replacements: [TaskStatus: TaskStatus] {
        Dictionary(
            uniqueKeysWithValues: selections.compactMap { status, selection in
                guard case .status(let replacement) = selection, replacement != status else {
                    return nil
                }

                return (status, replacement)
            }
        )
    }

    private func selection(for status: TaskStatus) -> Binding<BulkStatusSelection> {
        Binding {
            selections[status, default: .noChange]
        } set: { selection in
            selections[status] = selection
        }
    }

    private func statusLabel(for status: TaskStatus) -> some View {
        TaskStatusLabel(status: status)
    }
}
