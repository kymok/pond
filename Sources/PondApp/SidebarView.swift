import SwiftUI

import TaskCore

struct SidebarView: View {
    @EnvironmentObject private var model: TaskAppModel
    @Environment(\.openSettings) private var openSettings
    @AppStorage("alwaysOnTop") private var alwaysOnTop = false
    @FocusState private var focusedCollection: String?
    @State private var editingCollection: String?
    @State private var editingName = ""
    @State private var newCollectionBeingEdited: String?
    @State private var isHoveringCollections = false

    var body: some View {
        VStack(spacing: 0) {
            List(selection: selectedCollection) {
                Section {
                    Label("All", systemImage: "tray.full")
                        .badge(model.totalIncompleteCount)
                        .tag(TaskAppModel.allCollectionID)
                        .contextMenu {
                            Button("Bulk Change Status...") {
                                model.requestBulkStatusChangeForAll()
                            }
                            .disabled(model.items.isEmpty)
                        }

                    ForEach(model.visibleCollectionSummaries) { collection in
                        collectionRow(collection)
                            .tag(collection.name)
                    }
                } header: {
                    collectionSectionHeader("Collections", showsCreateButton: true)
                }

                if model.showsArchivedCollections && !model.archivedCollectionSummaries.isEmpty {
                    Section {
                        ForEach(model.archivedCollectionSummaries) { collection in
                            collectionRow(collection)
                                .tag(collection.name)
                        }
                    } header: {
                        collectionSectionHeader("Archived")
                    }
                }
            }

            HStack(spacing: 8) {
                Menu {
                    Toggle("Show Incomplete Only", isOn: showIncompleteOnlySelection)
                    Toggle("Show Archived Collections", isOn: $model.showsArchivedCollections)
                    Toggle("Auto Draft", isOn: $model.usesAutoDraft)
                    Toggle("Always On Top", isOn: $alwaysOnTop)

                    Divider()

                    Button("Settings...") {
                        openSettings()
                    }
                } label: {
                    footerIcon(systemName: "ellipsis", label: "Settings")
                }
                .buttonStyle(.plain)
                .help("Settings")

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func footerIcon(systemName: String, label: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .medium))
            .frame(width: 32, height: 28)
            .contentShape(Rectangle())
            .accessibilityLabel(label)
    }

    private func collectionSectionHeader(_ title: String, showsCreateButton: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            if showsCreateButton {
                Button {
                    createCollection()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .imageScale(.medium)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Create Collection")
                }
                .buttonStyle(.plain)
                .help("Create Collection")
                .opacity(isHoveringCollections ? 1 : 0)
                .disabled(!isHoveringCollections)
                .accessibilityHidden(!isHoveringCollections)
            }
        }
        .padding(.trailing, 12)
        .contentShape(Rectangle())
        .onHover { isHovering in
            if showsCreateButton {
                isHoveringCollections = isHovering
            }
        }
    }

    @ViewBuilder
    private func collectionRow(_ collection: TaskCollectionSummary) -> some View {
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
            Label {
                Text(collection.name)
            } icon: {
                collectionIcon(for: collection)
            }
                .badge(collection.incompleteCount)
                .help(collection.name)
                .onTapGesture {
                    selectCollection(collection.name)
                }
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        beginEditingCollection(collection.name, isNew: false)
                    }
                )
                .contextMenu {
                    CollectionActionMenuItems(
                        collection: collection,
                        showsCLICommand: true,
                        groupsCollectionActionsAtBottom: true
                    )
                }
        }
    }

    @ViewBuilder
    private func collectionIcon(for collection: TaskCollectionSummary) -> some View {
        switch collection.statusIndicator {
        case .aborted, .onHold, .rejected:
            if let status = collection.statusIndicator {
                TaskStatusIcon(status: status)
            }
        default:
            Image(systemName: "folder.fill")
                .foregroundStyle(collection.color.swiftUIColor)
        }
    }

    private var selectedCollection: Binding<String> {
        Binding {
            model.selectedCollection
        } set: { selection in
            selectCollection(selection)
        }
    }

    private var showIncompleteOnlySelection: Binding<Bool> {
        Binding {
            model.showsIncompleteOnly
        } set: { showsIncompleteOnly in
            setShowsIncompleteOnly(showsIncompleteOnly)
        }
    }

    private func selectCollection(_ selection: String) {
        guard model.selectedCollection != selection else {
            return
        }

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true

        // Collection switches can replace and reflow the whole detail list, so they should feel instant.
        withTransaction(transaction) {
            model.selectedCollection = selection
        }
    }

    private func setShowsIncompleteOnly(_ showsIncompleteOnly: Bool) {
        guard model.showsIncompleteOnly != showsIncompleteOnly else {
            return
        }

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true

        // Filter changes can replace and reflow the detail list, so they should feel instant.
        withTransaction(transaction) {
            model.showsIncompleteOnly = showsIncompleteOnly
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
