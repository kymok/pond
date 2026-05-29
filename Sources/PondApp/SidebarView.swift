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
    @FocusState private var focusedGroup: String?
    @State private var editingGroup: String?
    @State private var editingGroupName = ""
    @State private var hoveringGroup: String?
    @State private var collapsedGroups: Set<String> = []
    @State private var sidebarSelection = TaskAppModel.allCollectionID

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $sidebarSelection) {
                Section {
                    Label("All", systemImage: "tray.full")
                        .badge(model.totalIncompleteCount)
                        .tag(TaskAppModel.allCollectionID)
                        .contextMenu {
                            Button("Bulk Change Statuses…") {
                                model.requestBulkStatusChangeForAll()
                            }
                            .disabled(model.items.isEmpty)
                        }
                }

                ForEach(model.visibleCollectionGroups) { group in
                    Section {
                        if !groupIsCollapsed(group.name) {
                            ForEach(group.collections) { collection in
                                Group {
                                    if collection.isArchived {
                                        archivedCollectionListRow(collection)
                                    } else {
                                        collectionListRow(collection)
                                    }
                                }
                                .tag(collection.name)
                                .transition(.move(edge: .top).combined(with: .opacity))
                            }
                        }
                    } header: {
                        collectionGroupHeader(
                            group,
                            title: model.collectionGroupDisplayName(group.name),
                            allowsEditing: group.name != TaskStore.defaultCollectionGroup
                        )
                    }
                }
            }
            .animation(.easeInOut(duration: 0.18), value: model.visibleCollectionGroups)
            .animation(.easeInOut(duration: 0.18), value: collapsedGroups)

            HStack(spacing: 8) {
                Menu {
                    Menu("Add a Collection") {
                        ForEach(model.collectionGroupSummaries) { group in
                            Button(model.collectionGroupDisplayName(group.name)) {
                                createCollection(group: group.name)
                            }
                        }
                    }

                    Button("Add a Group") {
                        createCollectionGroup()
                    }

                    Divider()

                    Toggle("Show Only Incomplete Items", isOn: showIncompleteOnlySelection)
                    Toggle("Show Archived Collections", isOn: $model.showsArchivedCollections)
                    Toggle("Automatic Drafts", isOn: $model.usesAutoDraft)
                    Toggle("Always On Top", isOn: $alwaysOnTop)

                    Divider()

                    Button("Settings…") {
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
        .onChange(of: model.groupEditingRequest) { _, group in
            guard let group else {
                return
            }

            beginEditingGroup(group)
            model.clearGroupEditingRequest(group)
        }
        .onAppear {
            setSidebarSelection(model.selectedCollection)
        }
        .onChange(of: sidebarSelection) { _, selection in
            selectCollection(selection)
        }
        .onChange(of: model.selectedCollection) { _, selection in
            setSidebarSelection(selection)
        }
    }

    private func footerIcon(systemName: String, label: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .medium))
            .frame(width: 32, height: 28)
            .contentShape(Rectangle())
            .accessibilityLabel(label)
    }

    @ViewBuilder
    private func collectionGroupHeader(
        _ group: TaskCollectionGroupSummary,
        groupKey: String? = nil,
        title: String? = nil,
        showsCreateButton: Bool = true,
        allowsEditing: Bool = true
    ) -> some View {
        let groupKey = groupKey ?? group.name
        HStack(spacing: 4) {
            if allowsEditing, editingGroup == group.name {
                TextField("Group", text: $editingGroupName)
                    .textFieldStyle(.plain)
                    .focused($focusedGroup, equals: group.name)
                    .onSubmit {
                        finishEditingGroup(group.name)
                    }
                    .onChange(of: focusedGroup) { oldFocus, newFocus in
                        if oldFocus == group.name, newFocus != group.name {
                            finishEditingGroup(group.name)
                        }
                    }
                    .onAppear {
                        focusEditingGroup(group.name)
                    }
            } else {
                Text(title ?? group.name)
                    .foregroundStyle(.secondary)
                    .onTapGesture(count: 2) {
                        if allowsEditing {
                            beginEditingGroup(group.name)
                        }
                    }
                    .contextMenu {
                        if allowsEditing {
                            Button("Rename Group") {
                                beginEditingGroup(group.name)
                            }

                            mergeGroupMenu(group)

                            Button("Delete Group", role: .destructive) {
                                model.deleteCollectionGroup(group.name)
                            }
                            .disabled(!model.canDeleteCollectionGroup(group.name))
                        }
                    }
            }

            Spacer(minLength: 0)

            if showsCreateButton {
                Button {
                    createCollection(group: group.name)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .imageScale(.medium)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Create Collection")
                }
                .buttonStyle(.plain)
                .help("Create Collection")
                .opacity(hoveringGroup == groupKey ? 1 : 0)
                .disabled(hoveringGroup != groupKey)
                .accessibilityHidden(hoveringGroup != groupKey)
            }

            Button {
                toggleGroup(groupKey)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .rotationEffect(.degrees(groupIsCollapsed(groupKey) ? -90 : 0))
                    .contentShape(Rectangle())
                    .accessibilityLabel(groupIsCollapsed(groupKey) ? "Expand Group" : "Collapse Group")
            }
            .buttonStyle(.plain)
            .help(groupIsCollapsed(groupKey) ? "Expand Group" : "Collapse Group")
            .opacity(hoveringGroup == groupKey ? 1 : 0)
            .disabled(hoveringGroup != groupKey)
            .accessibilityHidden(hoveringGroup != groupKey)
        }
        .padding(.trailing, 12)
        .contentShape(Rectangle())
        .onHover { isHovering in
            if isHovering {
                hoveringGroup = groupKey
            } else if hoveringGroup == groupKey {
                hoveringGroup = nil
            }
        }
    }

    @ViewBuilder
    private func mergeGroupMenu(_ group: TaskCollectionGroupSummary) -> some View {
        let targets = model.collectionGroupSummaries.filter { $0.name != group.name }
        if !targets.isEmpty {
            Menu("Merge To") {
                ForEach(targets) { target in
                    Button(model.collectionGroupDisplayName(target.name)) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            model.mergeCollectionGroup(from: group.name, to: target.name)
                        }
                    }
                }
            }
        }
    }

    private func collectionListRow(_ collection: TaskCollectionSummary) -> some View {
        collectionRow(collection, allowsEditing: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private func archivedCollectionListRow(_ collection: TaskCollectionSummary) -> some View {
        collectionRow(collection, allowsEditing: false)
            .opacity(0.55)
    }

    @ViewBuilder
    private func collectionRow(_ collection: TaskCollectionSummary, allowsEditing: Bool) -> some View {
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
                Text(collection.displayName)
            } icon: {
                collectionIcon(for: collection)
            }
                .badge(collection.incompleteCount)
                .help(collection.name)
                .onTapGesture {
                    setSidebarSelection(collection.name)
                }
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        guard allowsEditing, !model.isDefaultCollection(collection) else {
                            return
                        }

                        beginEditingCollection(
                            collection.name,
                            displayName: collection.displayName,
                            isNew: false
                        )
                    }
                )
                .contextMenu {
                    if allowsEditing {
                        CollectionActionMenuItems(
                            collection: collection,
                            showsCLICommand: true,
                            groupsCollectionActionsAtBottom: true
                        )
                    }
                }
        }
    }

    @ViewBuilder
    private func collectionIcon(for collection: TaskCollectionSummary) -> some View {
        if collection.isArchived {
            Image(systemName: "archivebox")
                .foregroundStyle(.tertiary)
        } else {
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
    }

    private var showIncompleteOnlySelection: Binding<Bool> {
        Binding {
            model.showsIncompleteOnly
        } set: { showsIncompleteOnly in
            setShowsIncompleteOnly(showsIncompleteOnly)
        }
    }

    private func setSidebarSelection(_ selection: String) {
        guard sidebarSelection != selection else {
            return
        }

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            sidebarSelection = selection
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

    private func createCollection(group: String) {
        let name = withAnimation(.easeInOut(duration: 0.18)) {
            model.createCollectionForEditing(group: group)
        }
        guard let name else { return }

        let displayName = model.collectionSummaries.first { $0.name == name }?.displayName ?? name
        beginEditingCollection(name, displayName: displayName, isNew: true)
    }

    private func beginEditingCollection(_ name: String, displayName: String, isNew: Bool) {
        editingCollection = name
        editingName = displayName
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

    private func createCollectionGroup() {
        let name = withAnimation(.easeInOut(duration: 0.18)) {
            model.createCollectionGroupForEditing()
        }
        guard let name else { return }

        beginEditingGroup(name)
    }

    private func beginEditingGroup(_ name: String) {
        editingGroup = name
        editingGroupName = name
        focusEditingGroup(name)
    }

    private func focusEditingGroup(_ name: String) {
        focusedGroup = name
        DispatchQueue.main.async {
            selectCurrentTextFieldText()
        }
    }

    private func finishEditingGroup(_ oldName: String) {
        guard editingGroup == oldName else {
            return
        }

        let cleanName = editingGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanName.isEmpty {
            model.renameCollectionGroup(from: oldName, to: cleanName)
        }
        clearGroupEditingState()
    }

    private func clearGroupEditingState() {
        editingGroup = nil
        editingGroupName = ""
    }

    private func groupIsCollapsed(_ group: String) -> Bool {
        collapsedGroups.contains(group)
    }

    private func toggleGroup(_ group: String) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if collapsedGroups.contains(group) {
                collapsedGroups.remove(group)
            } else {
                collapsedGroups.insert(group)
            }
        }
    }

}
