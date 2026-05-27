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
                .navigationSplitViewColumnWidth(
                    min: SidebarLayout.minimumWidth,
                    ideal: SidebarLayout.minimumWidth,
                    max: SidebarLayout.maximumWidth
                )
        } detail: {
            DetailView()
        }
        .frame(minWidth: 480, minHeight: 320)
        .background(WindowLevelController(alwaysOnTop: alwaysOnTop))
        .background(
            LocalKeyDownHandler(isActive: model.collectionDeletionRequest != nil) { event in
                confirmDeleteDialogOnDefaultKey(event)
            }
        )
        .sheet(item: $model.bulkStatusChangeRequest) { request in
            BulkStatusChangeSheet(
                request: request,
                confirm: model.confirmBulkStatusChange,
                cancel: model.cancelBulkStatusChange
            )
        }
        .sheet(item: $model.assigneeEditRequest) { request in
            AssigneeEditSheet(
                request: request,
                save: model.confirmAssigneeEdit,
                cancel: model.cancelAssigneeEdit
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

private enum BulkStatusSelection: Hashable {
    case noChange
    case status(TodoStatus)
}

private struct AssigneeEditSheet: View {
    let request: TodoAssigneeEditRequest
    let save: (TodoItem, [String]) -> Void
    let cancel: () -> Void

    @State private var assignees: [String]

    init(
        request: TodoAssigneeEditRequest,
        save: @escaping (TodoItem, [String]) -> Void,
        cancel: @escaping () -> Void
    ) {
        self.request = request
        self.save = save
        self.cancel = cancel
        _assignees = State(initialValue: request.item.assignees)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Assignees")
                .font(.headline)

            AssigneeTokenField(tokens: $assignees)
                .frame(height: AssigneeTokenField.height)

            HStack {
                Button("Clear") {
                    save(request.item, [])
                }
                .disabled(cleanAssignees.isEmpty)

                Spacer()

                Button("Cancel") {
                    cancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    saveAssignees()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private var cleanAssignees: [String] {
        Self.cleanAssignees(assignees)
    }

    private static func cleanAssignees(_ assignees: [String]) -> [String] {
        var seen: Set<String> = []
        return assignees.compactMap { assignee in
            let clean = assignee.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, seen.insert(clean).inserted else {
                return nil
            }

            return clean
        }
    }

    private func saveAssignees() {
        save(request.item, cleanAssignees)
    }
}

private struct AssigneeTokenField: NSViewRepresentable {
    static let height: CGFloat = 84

    @Binding var tokens: [String]

    func makeCoordinator() -> Coordinator {
        Coordinator(tokens: $tokens)
    }

    func makeNSView(context: Context) -> NSTokenField {
        let tokenField = MultilineTokenField()
        tokenField.delegate = context.coordinator
        tokenField.tokenizingCharacterSet = CharacterSet(charactersIn: ",\n")
        tokenField.placeholderString = "Assignees"
        tokenField.objectValue = tokens
        tokenField.usesSingleLineMode = false
        tokenField.lineBreakMode = .byWordWrapping
        tokenField.cell?.usesSingleLineMode = false
        tokenField.cell?.wraps = true
        tokenField.cell?.isScrollable = false
        return tokenField
    }

    func updateNSView(_ tokenField: NSTokenField, context: Context) {
        context.coordinator.tokens = $tokens
        let currentTokens = Coordinator.cleanTokens(from: tokenField.objectValue)
        let cleanTokens = Coordinator.cleanTokens(tokens)
        if currentTokens != cleanTokens {
            tokenField.objectValue = cleanTokens
        }
    }

    final class Coordinator: NSObject, NSTokenFieldDelegate {
        var tokens: Binding<[String]>

        init(tokens: Binding<[String]>) {
            self.tokens = tokens
        }

        func controlTextDidChange(_ notification: Notification) {
            updateTokens(from: notification)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            updateTokens(from: notification)
        }

        @MainActor
        private func updateTokens(from notification: Notification) {
            guard let tokenField = notification.object as? NSTokenField else {
                return
            }

            tokens.wrappedValue = Self.cleanTokens(from: tokenField.objectValue)
        }

        static func cleanTokens(from objectValue: Any?) -> [String] {
            if let tokens = objectValue as? [String] {
                return cleanTokens(tokens)
            }

            if let values = objectValue as? [Any] {
                return cleanTokens(values.map { String(describing: $0) })
            }

            if let string = objectValue as? String {
                return cleanTokens(string.split { $0 == "," || $0.isNewline }.map(String.init))
            }

            return []
        }

        static func cleanTokens(_ tokens: [String]) -> [String] {
            var seen: Set<String> = []
            return tokens.compactMap { token in
                let clean = token.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty, seen.insert(clean).inserted else {
                    return nil
                }

                return clean
            }
        }
    }

    final class MultilineTokenField: NSTokenField {
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: AssigneeTokenField.height)
        }
    }
}

private struct BulkStatusChangeSheet: View {
    let request: TodoBulkStatusChangeRequest
    let confirm: ([TodoStatus: TodoStatus]) -> Bool
    let cancel: () -> Void

    @State private var selections: [TodoStatus: BulkStatusSelection]

    init(
        request: TodoBulkStatusChangeRequest,
        confirm: @escaping ([TodoStatus: TodoStatus]) -> Bool,
        cancel: @escaping () -> Void
    ) {
        self.request = request
        self.confirm = confirm
        self.cancel = cancel
        _selections = State(
            initialValue: Dictionary(
                uniqueKeysWithValues: TodoStatus.allCases.map { ($0, BulkStatusSelection.noChange) }
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Bulk Change Status")
                .font(.headline)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 10) {
                ForEach(TodoStatus.allCases, id: \.self) { status in
                    GridRow {
                        statusLabel(for: status)
                            .frame(width: 128, alignment: .leading)

                        Picker("Change \(status.displayName) to", selection: selection(for: status)) {
                            Text("No change").tag(BulkStatusSelection.noChange)

                            ForEach(TodoStatus.allCases, id: \.self) { replacement in
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

    private var replacements: [TodoStatus: TodoStatus] {
        Dictionary(
            uniqueKeysWithValues: selections.compactMap { status, selection in
                guard case .status(let replacement) = selection, replacement != status else {
                    return nil
                }

                return (status, replacement)
            }
        )
    }

    private func selection(for status: TodoStatus) -> Binding<BulkStatusSelection> {
        Binding {
            selections[status, default: .noChange]
        } set: { selection in
            selections[status] = selection
        }
    }

    private func statusLabel(for status: TodoStatus) -> some View {
        TodoStatusLabel(status: status)
    }
}
