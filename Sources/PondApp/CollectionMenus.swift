import SwiftUI
import TaskCore

struct CollectionColorMenu: View {
    @Environment(TaskAppModel.self) private var model

    let collection: TaskCollectionSummary

    var body: some View {
        Menu {
            Picker("", selection: colorSelection) {
                ForEach(TaskCollectionColor.allCases) { color in
                    Label {
                        Text(color.displayName)
                    } icon: {
                        CollectionColorSwatch(color: color, size: 12)
                    }
                    .tag(color)
                }
            }
            .labelsHidden()
            .pickerStyle(.inline)
        } label: {
            Label {
                Text("Color")
            } icon: {
                CollectionColorSwatch(color: collection.color, size: 10)
            }
        }
    }

    var colorSelection: Binding<TaskCollectionColor> {
        Binding {
            collection.color
        } set: { color in
            model.setCollectionColor(collection, color: color)
        }
    }
}


enum CollectionBulkStatusScope {
    case collection
    case visibleItems
}

struct CollectionActionMenuItems: View {
    @Environment(TaskAppModel.self) private var model

    let collection: TaskCollectionSummary
    var showsCLICommand = false
    var showsExport = false
    var groupsCollectionActionsAtBottom = false
    var bulkStatusScope: CollectionBulkStatusScope = .collection

    var body: some View {
        Button("Copy Prompt") {
            copyToPasteboard(examplePrompt)
        }

        Button("Edit Prompt…") {
            model.requestCollectionPromptEdit(collection)
        }

        if showsCLICommand {
            Button("Copy CLI Command") {
                copyToPasteboard(cliCommand)
            }
        }

        if !groupsCollectionActionsAtBottom {
            exportButton
        }

        Divider()

        CollectionColorMenu(collection: collection)

        groupMenu
            .disabled(model.isDefaultCollection(collection))

        Divider()

        if !groupsCollectionActionsAtBottom {
            archiveButton

            Divider()
        }

        Button("Clear All", role: .destructive) {
            model.clearItems(in: collection)
        }
        .disabled(!model.canClearItems(in: collection))

        Button("Clear Completed", role: .destructive) {
            model.clearItems(in: collection, completedOnly: true)
        }
        .disabled(!model.canClearCompletedItems(in: collection))

        Button("Bulk Change Statuses…") {
            requestBulkStatusChange()
        }
        .disabled(!canBulkChangeStatuses)

        Divider()

        if groupsCollectionActionsAtBottom {
            exportButton

            archiveButton

            deleteButton
        } else {
            deleteButton
        }
    }

    @ViewBuilder
    var exportButton: some View {
        if showsExport {
            Button("Export Collection…") {
                model.exportCollection(collection)
            }
        }
    }

    var archiveButton: some View {
        Button(collection.isArchived ? "Unarchive Collection" : "Archive Collection") {
            model.setCollectionArchived(collection, isArchived: !collection.isArchived)
        }
    }

    var groupMenu: some View {
        Menu("Group") {
            Picker("", selection: groupSelection) {
                ForEach(model.collectionGroupSummaries) { group in
                    Text(model.collectionGroupDisplayName(group.name))
                        .tag(group.name)
                }
            }
            .labelsHidden()
            .pickerStyle(.inline)

            Divider()

            Button("Add to a New Group") {
                withAnimation(.easeInOut(duration: 0.18)) {
                    _ = model.createCollectionGroupAndMoveCollectionForEditing(collection)
                }
            }
        }
    }

    var deleteButton: some View {
        Button("Delete Collection", role: .destructive) {
            model.requestDeleteCollection(collection)
        }
        .disabled(model.isDefaultCollection(collection))
    }

    var cliCommand: String {
        "taskpond item get --collection \(collection.name.shellEscaped)"
    }

    var examplePrompt: String {
        taskExamplePrompt(
            template: effectivePromptTemplate,
            cliCommand: cliCommand,
            collectionName: collection.name
        )
    }

    var effectivePromptTemplate: String {
        guard let promptTemplate = collection.promptTemplate,
              !promptTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return TaskPromptSettings.effectiveDefaultPromptTemplate
        }

        return promptTemplate
    }

    var canBulkChangeStatuses: Bool {
        switch bulkStatusScope {
        case .collection:
            model.canBulkChangeStatuses(in: collection)
        case .visibleItems:
            model.canBulkChangeVisibleStatuses
        }
    }

    var currentGroupName: String? {
        collection.groupName
    }

    var groupSelection: Binding<String> {
        Binding {
            currentGroupName ?? TaskStore.defaultCollectionGroup
        } set: { group in
            guard group != currentGroupName else {
                return
            }

            withAnimation(.easeInOut(duration: 0.18)) {
                model.moveCollection(collection, toGroup: group)
            }
        }
    }

    func requestBulkStatusChange() {
        switch bulkStatusScope {
        case .collection:
            model.requestBulkStatusChange(for: collection)
        case .visibleItems:
            model.requestBulkStatusChangeForVisibleItems()
        }
    }
}

