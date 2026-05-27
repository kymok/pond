import SwiftUI

import TodoCore

struct SidebarView: View {
    @EnvironmentObject private var model: TodoAppModel
    @FocusState private var focusedCollection: String?
    @State private var editingCollection: String?
    @State private var editingName = ""
    @State private var newCollectionBeingEdited: String?

    var body: some View {
        List(selection: $model.selectedCollection) {
            Section("Collections") {
                Label("All", systemImage: "tray.full")
                    .badge(model.totalUndoneCount)
                    .tag(TodoAppModel.allCollectionID)

                ForEach(model.collectionSummaries) { collection in
                    collectionRow(collection)
                        .tag(collection.name)
                }

                Button {
                    createCollection()
                } label: {
                    Label("Create new", systemImage: "plus")
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func collectionRow(_ collection: TodoCollectionSummary) -> some View {
        if editingCollection == collection.name {
            TextField("Collection", text: $editingName)
                .textFieldStyle(.plain)
                .focused($focusedCollection, equals: collection.name)
                .onSubmit {
                    finishEditingCollection(collection.name)
                }
                .onChange(of: focusedCollection) { oldFocus, newFocus in
                    if oldFocus == collection.name, newFocus != collection.name {
                        finishEditingCollection(collection.name)
                    }
                }
                .onAppear {
                    focusEditingCollection(collection.name)
                }
        } else {
            Label(collection.name, systemImage: "folder")
                .badge(collection.undoneCount)
                .help(collection.name)
                .onTapGesture {
                    model.selectedCollection = collection.name
                }
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        beginEditingCollection(collection.name, isNew: false)
                    }
                )
                .contextMenu {
                    Button("Clear all", role: .destructive) {
                        model.clearUnlockedItems(in: collection)
                    }
                    .disabled(!model.canClearUnlockedItems(in: collection))

                    Button("Clear done", role: .destructive) {
                        model.clearUnlockedItems(in: collection, doneOnly: true)
                    }
                    .disabled(!model.canClearDoneUnlockedItems(in: collection))

                    Button("Delete", role: .destructive) {
                        model.requestDeleteCollection(collection)
                    }
                }
        }
    }

    private func createCollection() {
        guard let name = model.createCollectionForEditing() else {
            return
        }

        beginEditingCollection(name, isNew: true)
    }

    private func beginEditingCollection(_ name: String, isNew: Bool) {
        editingCollection = name
        editingName = name
        newCollectionBeingEdited = isNew ? name : nil
        focusEditingCollection(name)
    }

    private func focusEditingCollection(_ name: String) {
        focusedCollection = name
        DispatchQueue.main.async {
            selectCurrentTextFieldText()
        }
    }

    private func finishEditingCollection(_ oldName: String) {
        guard editingCollection == oldName else {
            return
        }

        let cleanName = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanName.isEmpty {
            if newCollectionBeingEdited == oldName {
                model.deleteEmptyCollection(oldName)
            }

            clearEditingState()
            return
        }

        model.renameCollection(from: oldName, to: cleanName)
        clearEditingState()
    }

    private func clearEditingState() {
        editingCollection = nil
        editingName = ""
        newCollectionBeingEdited = nil
    }
}
