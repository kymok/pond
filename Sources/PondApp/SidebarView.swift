import OSLog
import SwiftUI
import UniformTypeIdentifiers

import TaskCore

private let sidebarDragLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.kymok.pond",
    category: "SidebarDrag"
)

private let sidebarRootGroupDropEdgeHeight: CGFloat = 36

private enum SidebarCollectionDrag {
    static let type = UTType(exportedAs: "dev.kymok.pond.sidebar-collection")
    static let acceptedTypes = [type]

    static func itemProvider(name: String) -> NSItemProvider {
        sidebarDragItemProvider(name: name, type: type)
    }
}

private enum SidebarGroupDrag {
    static let type = UTType(exportedAs: "dev.kymok.pond.sidebar-group")
    static let acceptedTypes = [type]

    static func itemProvider(name: String) -> NSItemProvider {
        sidebarDragItemProvider(name: name, type: type)
    }
}

private func sidebarDragItemProvider(name: String, type: UTType) -> NSItemProvider {
    let provider = NSItemProvider()
    provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { completion in
        completion(name.data(using: .utf8), nil)
        return nil
    }
    return provider
}

struct SidebarView: View {
    @Environment(TaskAppModel.self) private var model
    @Environment(TaskDragState.self) private var taskDragState
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
    @State private var taskDropTargetCollection: String?
    @State private var draggedSidebarCollection: String?
    @State private var draggedSidebarGroup: String?
    @State private var provisionalCollectionGroups: [TaskCollectionGroupSummary]?
    @State private var collapsedGroups: Set<String> = []
    @State private var sidebarSelection = TaskAppModel.allCollectionID

    var body: some View {
        @Bindable var model = model
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

                ForEach(displayedCollectionGroups) { group in
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
            .animation(.easeInOut(duration: 0.18), value: displayedCollectionGroups)
            .animation(.easeInOut(duration: 0.18), value: collapsedGroups)

            HStack(spacing: 8) {
                Menu {
                    Menu("Add a Collection To") {
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

                    Toggle("Hide Completed Items", isOn: showIncompleteOnlySelection)
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
        .contentShape(Rectangle())
        .onDrop(
            of: TaskItemDrag.acceptedTypes + SidebarCollectionDrag.acceptedTypes + SidebarGroupDrag.acceptedTypes,
            delegate: SidebarTaskDropCleanupDelegate(
                groups: displayedCollectionGroups,
                dragState: taskDragState,
                draggedCollection: $draggedSidebarCollection,
                draggedGroup: $draggedSidebarGroup,
                provisionalGroups: $provisionalCollectionGroups,
                moveCollection: model.reorderCollection,
                moveGroup: model.reorderCollectionGroup
            )
        )
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
        .onChange(of: taskDragState.draggedItemID) { _, itemID in
            guard itemID == nil else {
                return
            }

            clearTaskDropTarget()
        }
    }

    private var displayedCollectionGroups: [TaskCollectionGroupSummary] {
        provisionalCollectionGroups ?? model.visibleCollectionGroups
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
            collectionGroupHeaderTitleArea(group, title: title, allowsEditing: allowsEditing)

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
        .onDrop(
            of: SidebarCollectionDrag.acceptedTypes + SidebarGroupDrag.acceptedTypes,
            delegate: SidebarGroupHeaderDropDelegate(
                group: group,
                groups: displayedCollectionGroups,
                draggedCollection: $draggedSidebarCollection,
                draggedGroup: $draggedSidebarGroup,
                provisionalGroups: $provisionalCollectionGroups,
                moveCollection: model.reorderCollection,
                moveGroup: model.reorderCollectionGroup
            )
        )
    }

    @ViewBuilder
    private func collectionGroupHeaderTitleArea(
        _ group: TaskCollectionGroupSummary,
        title: String?,
        allowsEditing: Bool
    ) -> some View {
        let isEditing = allowsEditing && editingGroup == group.name
        let titleArea = HStack(spacing: 4) {
            if isEditing {
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
                collectionGroupTitle(group, title: title, allowsEditing: allowsEditing)
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())

        if allowsEditing, !isEditing {
            titleArea
                .onDrag {
                    beginDraggingGroup(group.name)
                } preview: {
                    SidebarGroupDragPreview(title: title ?? group.name)
                }
        } else {
            titleArea
        }
    }

    @ViewBuilder
    private func collectionGroupTitle(
        _ group: TaskCollectionGroupSummary,
        title: String?,
        allowsEditing: Bool
    ) -> some View {
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

    @ViewBuilder
    private func collectionListRow(_ collection: TaskCollectionSummary) -> some View {
        let dropDelegate = SidebarCollectionDropDelegate(
            collection: collection,
            groups: displayedCollectionGroups,
            items: model.items,
            dragState: taskDragState,
            draggedCollection: $draggedSidebarCollection,
            provisionalGroups: $provisionalCollectionGroups,
            targetCollection: $taskDropTargetCollection,
            moveItemToCollection: { item, collection in
                model.move(item, collection: collection)
            },
            moveCollection: model.reorderCollection
        )
        let row = collectionRow(collection, allowsEditing: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                if editingCollection != collection.name {
                    setSidebarSelection(collection.name)
                }
            }
            .background {
                Color.clear
                    .padding(.vertical, -5)
                    .contentShape(Rectangle())
                    .onDrop(
                        of: TaskItemDrag.acceptedTypes + SidebarCollectionDrag.acceptedTypes,
                        delegate: dropDelegate
                    )
            }
            .onDrop(
                of: TaskItemDrag.acceptedTypes + SidebarCollectionDrag.acceptedTypes,
                delegate: dropDelegate
            )
            .listRowBackground(collectionDropBackground(collection))

        if canDragCollection(collection) {
            row.onDrag {
                beginDraggingCollection(collection.name)
            } preview: {
                SidebarCollectionDragPreview(collection: collection)
            }
        } else {
            row
        }
    }

    @ViewBuilder
    private func archivedCollectionListRow(_ collection: TaskCollectionSummary) -> some View {
        let row = collectionRow(collection, allowsEditing: false)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                setSidebarSelection(collection.name)
            }
            .contextMenu {
                archivedCollectionActionMenuItems(collection)
            }
            .opacity(0.55)

        if canDragCollection(collection) {
            row.onDrag {
                beginDraggingCollection(collection.name)
            } preview: {
                SidebarCollectionDragPreview(collection: collection)
            }
        } else {
            row
        }
    }

    @ViewBuilder
    private func archivedCollectionActionMenuItems(_ collection: TaskCollectionSummary) -> some View {
        Menu("Group") {
            ForEach(model.collectionGroupSummaries) { group in
                Button(model.collectionGroupDisplayName(group.name)) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        model.moveCollection(collection, toGroup: group.name)
                    }
                }
                .disabled(group.name == collection.groupName)
            }

            Divider()

            Button("Add to a New Group") {
                withAnimation(.easeInOut(duration: 0.18)) {
                    _ = model.createCollectionGroupAndMoveCollectionForEditing(collection)
                }
            }
        }

        Button("Unarchive Collection") {
            model.setCollectionArchived(collection, isArchived: false)
        }
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

    private func collectionDropBackground(_ collection: TaskCollectionSummary) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color.accentColor.opacity(taskDropTargetCollection == collection.name ? 0.14 : 0))
            .padding(.horizontal, 10)
            .animation(.easeOut(duration: 0.18), value: taskDropTargetCollection)
    }

    private func clearTaskDropTarget() {
        guard taskDropTargetCollection != nil else {
            return
        }

        withAnimation(.easeOut(duration: 0.18)) {
            taskDropTargetCollection = nil
        }
    }

    private func canDragCollection(_ collection: TaskCollectionSummary) -> Bool {
        !model.isDefaultCollection(collection)
    }

    private func beginDraggingCollection(_ collection: String) -> NSItemProvider {
        draggedSidebarGroup = nil
        draggedSidebarCollection = collection
        provisionalCollectionGroups = model.visibleCollectionGroups
        sidebarDragLogger.info("Collection drag started source='\(collection, privacy: .public)'")
        return SidebarCollectionDrag.itemProvider(name: collection)
    }

    private func beginDraggingGroup(_ group: String) -> NSItemProvider {
        draggedSidebarCollection = nil
        draggedSidebarGroup = group
        provisionalCollectionGroups = model.visibleCollectionGroups
        sidebarDragLogger.info(
            "Group drag started source='\(group, privacy: .public)' order='\(sidebarGroupOrderDescription(model.visibleCollectionGroups), privacy: .public)'"
        )
        return SidebarGroupDrag.itemProvider(name: group)
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

private struct SidebarCollectionDragPreview: View {
    let collection: TaskCollectionSummary

    var body: some View {
        Label {
            Text(collection.displayName)
                .lineLimit(1)
        } icon: {
            CollectionColorSwatch(color: collection.color, size: 9)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct SidebarGroupDragPreview: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct SidebarCollectionPlacement {
    let group: String
    let after: String?
    let before: String?
}

private struct SidebarGroupPlacement {
    let after: String?
    let before: String?
}

private func sidebarGroupOrderDescription(_ groups: [TaskCollectionGroupSummary]) -> String {
    groups.map(\.name).joined(separator: " > ")
}

private func moveCollectionInSidebarGroups(
    _ source: String,
    toGroup targetGroup: String,
    targetCollection: String?,
    groups: [TaskCollectionGroupSummary]
) -> [TaskCollectionGroupSummary]? {
    var groups = groups
    guard let sourceGroupIndex = groups.firstIndex(where: { group in
        group.collections.contains { $0.name == source }
    }),
    let sourceIndex = groups[sourceGroupIndex].collections.firstIndex(where: { $0.name == source }),
    let targetGroupIndex = groups.firstIndex(where: { $0.name == targetGroup }) else {
        return nil
    }

    let originalTargetIndex = targetCollection.flatMap { targetCollection in
        groups[targetGroupIndex].collections.firstIndex { $0.name == targetCollection }
    }
    let sourceCollection = groups[sourceGroupIndex].collections[sourceIndex]
    var sourceCollections = groups[sourceGroupIndex].collections
    sourceCollections.remove(at: sourceIndex)
    groups[sourceGroupIndex] = TaskCollectionGroupSummary(
        name: groups[sourceGroupIndex].name,
        collections: sourceCollections
    )

    guard let currentTargetGroupIndex = groups.firstIndex(where: { $0.name == targetGroup }) else {
        return nil
    }

    var targetCollections = groups[currentTargetGroupIndex].collections
    let insertionIndex: Int
    if let targetCollection,
       let targetIndex = targetCollections.firstIndex(where: { $0.name == targetCollection }) {
        if sourceGroupIndex == targetGroupIndex,
           let originalTargetIndex,
           sourceIndex < originalTargetIndex {
            insertionIndex = targetIndex + 1
        } else {
            insertionIndex = targetIndex
        }
    } else {
        insertionIndex = targetCollections.count
    }

    targetCollections.insert(sourceCollection, at: min(insertionIndex, targetCollections.count))
    groups[currentTargetGroupIndex] = TaskCollectionGroupSummary(
        name: groups[currentTargetGroupIndex].name,
        collections: targetCollections
    )
    return groups
}

private func collectionPlacement(
    for source: String,
    in groups: [TaskCollectionGroupSummary]
) -> SidebarCollectionPlacement? {
    guard let group = groups.first(where: { group in
        group.collections.contains { $0.name == source }
    }),
    let index = group.collections.firstIndex(where: { $0.name == source }) else {
        return nil
    }

    let after = index > 0 ? group.collections[index - 1].name : nil
    let before = group.collections.indices.contains(index + 1) ? group.collections[index + 1].name : nil
    return SidebarCollectionPlacement(group: group.name, after: after, before: before)
}

private func moveGroupInSidebarGroups(
    _ source: String,
    target: String,
    groups: [TaskCollectionGroupSummary]
) -> [TaskCollectionGroupSummary]? {
    guard source != TaskStore.defaultCollectionGroup,
          source != target,
          let sourceIndex = groups.firstIndex(where: { $0.name == source }),
          let targetIndex = groups.firstIndex(where: { $0.name == target }) else {
        return nil
    }

    var groups = groups
    let sourceGroup = groups.remove(at: sourceIndex)
    let currentTargetIndex = groups.firstIndex(where: { $0.name == target }) ?? targetIndex
    let insertionIndex = sourceIndex < targetIndex ? currentTargetIndex + 1 : currentTargetIndex
    groups.insert(sourceGroup, at: min(insertionIndex, groups.count))
    let orderedGroups = groups.filter { $0.name == TaskStore.defaultCollectionGroup }
        + groups.filter { $0.name != TaskStore.defaultCollectionGroup }
    sidebarDragLogger.debug(
        "Group provisional reorder source='\(source, privacy: .public)' target='\(target, privacy: .public)' order='\(sidebarGroupOrderDescription(orderedGroups), privacy: .public)'"
    )
    return orderedGroups
}

private func moveGroupToBottomInSidebarGroups(
    _ source: String,
    groups: [TaskCollectionGroupSummary]
) -> [TaskCollectionGroupSummary]? {
    guard source != TaskStore.defaultCollectionGroup,
          let sourceIndex = groups.firstIndex(where: { $0.name == source }),
          let lastMovableIndex = groups.lastIndex(where: { $0.name != TaskStore.defaultCollectionGroup }),
          sourceIndex != lastMovableIndex else {
        return nil
    }

    var groups = groups
    let sourceGroup = groups.remove(at: sourceIndex)
    groups.append(sourceGroup)
    let orderedGroups = groups.filter { $0.name == TaskStore.defaultCollectionGroup }
        + groups.filter { $0.name != TaskStore.defaultCollectionGroup }
    sidebarDragLogger.debug(
        "Group provisional root-bottom source='\(source, privacy: .public)' order='\(sidebarGroupOrderDescription(orderedGroups), privacy: .public)'"
    )
    return orderedGroups
}

private func moveGroupToTopInSidebarGroups(
    _ source: String,
    groups: [TaskCollectionGroupSummary]
) -> [TaskCollectionGroupSummary]? {
    guard source != TaskStore.defaultCollectionGroup,
          let sourceIndex = groups.firstIndex(where: { $0.name == source }) else {
        return nil
    }

    let firstMovableIndex = groups.firstIndex { $0.name != TaskStore.defaultCollectionGroup } ?? groups.count
    guard sourceIndex != firstMovableIndex else {
        return nil
    }

    var groups = groups
    let sourceGroup = groups.remove(at: sourceIndex)
    let insertionIndex = groups.firstIndex { $0.name != TaskStore.defaultCollectionGroup } ?? groups.count
    groups.insert(sourceGroup, at: insertionIndex)
    let orderedGroups = groups.filter { $0.name == TaskStore.defaultCollectionGroup }
        + groups.filter { $0.name != TaskStore.defaultCollectionGroup }
    sidebarDragLogger.debug(
        "Group provisional root-top source='\(source, privacy: .public)' order='\(sidebarGroupOrderDescription(orderedGroups), privacy: .public)'"
    )
    return orderedGroups
}

private func groupPlacement(
    for source: String,
    in groups: [TaskCollectionGroupSummary]
) -> SidebarGroupPlacement? {
    guard let index = groups.firstIndex(where: { $0.name == source }) else {
        return nil
    }

    let after = index > 0 ? groups[index - 1].name : nil
    let before = groups.indices.contains(index + 1) ? groups[index + 1].name : nil
    return SidebarGroupPlacement(after: after, before: before)
}

private struct SidebarCollectionDropDelegate: DropDelegate {
    let collection: TaskCollectionSummary
    let groups: [TaskCollectionGroupSummary]
    let items: [TaskItem]
    let dragState: TaskDragState
    @Binding var draggedCollection: String?
    @Binding var provisionalGroups: [TaskCollectionGroupSummary]?
    @Binding var targetCollection: String?
    let moveItemToCollection: (TaskItem, String) -> Void
    let moveCollection: (String, String, String?, String?) -> Bool

    func dropEntered(info: DropInfo) {
        if info.hasItemsConforming(to: SidebarCollectionDrag.acceptedTypes) {
            sidebarDragLogger.debug("Collection drop entered target='\(collection.name, privacy: .public)'")
            updateProvisionalOrder()
        } else if canShowTarget {
            setTarget()
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if info.hasItemsConforming(to: SidebarCollectionDrag.acceptedTypes) {
            guard canAcceptCollectionDrop else {
                sidebarDragLogger.debug(
                    "Collection drop validation failed target='\(collection.name, privacy: .public)' source='\(draggedCollection ?? "", privacy: .public)'"
                )
                return nil
            }

            updateProvisionalOrder()
            return DropProposal(operation: .move)
        }

        let acceptsDrop = canAcceptDrop(info: info)
        guard acceptsDrop else {
            clearTarget()
            return nil
        }

        if canShowTarget {
            setTarget()
        } else {
            clearTarget()
        }

        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        clearTarget()
    }

    func performDrop(info: DropInfo) -> Bool {
        if info.hasItemsConforming(to: SidebarCollectionDrag.acceptedTypes) {
            return performCollectionDrop()
        }

        defer {
            clearTarget()
        }

        guard let item = draggedItem else {
            return performDropWithProvider(info: info)
        }

        defer {
            dragState.finishDragging(reason: "CollectionTaskDropDelegate.performDrop")
        }

        return move(item)
    }

    private func performCollectionDrop() -> Bool {
        defer {
            draggedCollection = nil
            provisionalGroups = nil
        }

        guard canAcceptCollectionDrop,
              let source = draggedCollection else {
            sidebarDragLogger.info("Collection drop skipped target='\(collection.name, privacy: .public)'")
            return false
        }

        let finalGroups = provisionalGroups ?? groups
        guard let placement = collectionPlacement(for: source, in: finalGroups) else {
            sidebarDragLogger.info(
                "Collection drop no-op source='\(source, privacy: .public)' target='\(collection.name, privacy: .public)'"
            )
            return true
        }

        sidebarDragLogger.info(
            "Collection drop performing source='\(source, privacy: .public)' target='\(collection.name, privacy: .public)' group='\(placement.group, privacy: .public)'"
        )
        return moveCollection(source, placement.group, placement.after, placement.before)
    }

    private func updateProvisionalOrder() {
        guard canAcceptCollectionDrop,
              let source = draggedCollection,
              source != collection.name,
              let movedGroups = moveCollectionInSidebarGroups(
                source,
                toGroup: collection.groupName,
                targetCollection: collection.name,
                groups: provisionalGroups ?? groups
              ) else {
            return
        }

        withAnimation(.easeInOut(duration: 0.18)) {
            provisionalGroups = movedGroups
        }
    }

    private func canAcceptDrop(info: DropInfo) -> Bool {
        draggedItem?.allowsTitleAndCollectionEditing
            ?? info.hasItemsConforming(to: TaskItemDrag.acceptedTypes)
    }

    private var canAcceptCollectionDrop: Bool {
        guard let draggedCollection,
              draggedCollection != TaskStore.defaultCollection,
              let source = collectionSummary(named: draggedCollection),
              !source.isArchived,
              !collection.isArchived else {
            return false
        }

        return true
    }

    private func collectionSummary(named name: String) -> TaskCollectionSummary? {
        groups.lazy.flatMap(\.collections).first { $0.name == name }
    }

    private var canShowTarget: Bool {
        draggedItem?.allowsTitleAndCollectionEditing == true
    }

    private func clearTarget() {
        if targetCollection == collection.name {
            withAnimation(.easeOut(duration: 0.18)) {
                targetCollection = nil
            }
        }
    }

    private func setTarget() {
        guard targetCollection != collection.name else {
            return
        }

        targetCollection = collection.name
    }

    private func performDropWithProvider(info: DropInfo) -> Bool {
        let isLoading = TaskItemDrag.loadItemID(from: info) { itemID in
            defer {
                dragState.finishDragging(reason: "CollectionTaskDropDelegate.performDropWithProvider")
            }

            guard let itemID,
                  let item = items.first(where: { $0.id == itemID }) else {
                return
            }

            _ = move(item)
        }
        if !isLoading {
            dragState.finishDragging(reason: "CollectionTaskDropDelegate.noProvider")
        }
        return isLoading
    }

    private func move(_ item: TaskItem) -> Bool {
        guard item.allowsTitleAndCollectionEditing else {
            return false
        }

        guard item.collection != collection.name else {
            return true
        }

        moveItemToCollection(item, collection.name)
        return true
    }

    private var draggedItem: TaskItem? {
        guard let itemID = dragState.draggedItemID else {
            return nil
        }

        return items.first { $0.id == itemID }
    }
}

private struct SidebarGroupHeaderDropDelegate: DropDelegate {
    let group: TaskCollectionGroupSummary
    let groups: [TaskCollectionGroupSummary]
    @Binding var draggedCollection: String?
    @Binding var draggedGroup: String?
    @Binding var provisionalGroups: [TaskCollectionGroupSummary]?
    let moveCollection: (String, String, String?, String?) -> Bool
    let moveGroup: (String, String?, String?) -> Bool

    func dropEntered(info: DropInfo) {
        if info.hasItemsConforming(to: SidebarGroupDrag.acceptedTypes) {
            sidebarDragLogger.debug("Group drop entered target='\(group.name, privacy: .public)'")
            updateProvisionalGroupOrder()
        } else if info.hasItemsConforming(to: SidebarCollectionDrag.acceptedTypes) {
            sidebarDragLogger.debug("Collection group drop entered target='\(group.name, privacy: .public)'")
            updateProvisionalCollectionOrder()
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if info.hasItemsConforming(to: SidebarGroupDrag.acceptedTypes) {
            guard canAcceptGroupDrop else {
                sidebarDragLogger.debug(
                    "Group drop validation failed target='\(group.name, privacy: .public)' source='\(draggedGroup ?? "", privacy: .public)'"
                )
                return nil
            }
            updateProvisionalGroupOrder()
            return DropProposal(operation: .move)
        }

        if info.hasItemsConforming(to: SidebarCollectionDrag.acceptedTypes) {
            guard canAcceptCollectionDrop else {
                sidebarDragLogger.debug(
                    "Collection group drop validation failed target='\(group.name, privacy: .public)' source='\(draggedCollection ?? "", privacy: .public)'"
                )
                return nil
            }
            updateProvisionalCollectionOrder()
            return DropProposal(operation: .move)
        }

        return nil
    }

    func performDrop(info: DropInfo) -> Bool {
        if info.hasItemsConforming(to: SidebarGroupDrag.acceptedTypes) {
            return performGroupDrop()
        }

        if info.hasItemsConforming(to: SidebarCollectionDrag.acceptedTypes) {
            return performCollectionDrop()
        }

        return false
    }

    private func performGroupDrop() -> Bool {
        defer {
            draggedGroup = nil
            provisionalGroups = nil
        }

        guard canCommitGroupDrop,
              let source = draggedGroup else {
            sidebarDragLogger.info("Group drop skipped target='\(group.name, privacy: .public)'")
            return false
        }

        let finalGroups = provisionalGroups ?? groups
        guard let placement = groupPlacement(for: source, in: finalGroups) else {
            sidebarDragLogger.info(
                "Group drop no-op source='\(source, privacy: .public)' target='\(group.name, privacy: .public)'"
            )
            return true
        }

        sidebarDragLogger.info(
            "Group drop performing source='\(source, privacy: .public)' target='\(group.name, privacy: .public)'"
        )
        return moveGroup(source, placement.after, placement.before)
    }

    private func performCollectionDrop() -> Bool {
        defer {
            draggedCollection = nil
            provisionalGroups = nil
        }

        guard canAcceptCollectionDrop,
              let source = draggedCollection else {
            sidebarDragLogger.info("Collection group drop skipped target='\(group.name, privacy: .public)'")
            return false
        }

        let finalGroups = provisionalGroups ?? groups
        guard let placement = collectionPlacement(for: source, in: finalGroups) else {
            sidebarDragLogger.info(
                "Collection group drop no-op source='\(source, privacy: .public)' target='\(group.name, privacy: .public)'"
            )
            return true
        }

        sidebarDragLogger.info(
            "Collection group drop performing source='\(source, privacy: .public)' target='\(group.name, privacy: .public)'"
        )
        return moveCollection(source, placement.group, placement.after, placement.before)
    }

    private func updateProvisionalCollectionOrder() {
        guard canAcceptCollectionDrop,
              let source = draggedCollection,
              let movedGroups = moveCollectionInSidebarGroups(
                source,
                toGroup: group.name,
                targetCollection: nil,
                groups: provisionalGroups ?? groups
              ) else {
            return
        }

        withAnimation(.easeInOut(duration: 0.18)) {
            provisionalGroups = movedGroups
        }
    }

    private func updateProvisionalGroupOrder() {
        guard canAcceptGroupDrop,
              let source = draggedGroup,
              source != group.name,
              let movedGroups = moveGroupInSidebarGroups(
                source,
                target: group.name,
                groups: provisionalGroups ?? groups
              ) else {
            return
        }

        withAnimation(.easeInOut(duration: 0.18)) {
            provisionalGroups = movedGroups
        }
    }

    private var canAcceptGroupDrop: Bool {
        guard let draggedGroup,
              draggedGroup != TaskStore.defaultCollectionGroup,
              groups.contains(where: { $0.name == draggedGroup }) else {
            return false
        }

        return true
    }

    private var canCommitGroupDrop: Bool {
        guard let draggedGroup,
              draggedGroup != TaskStore.defaultCollectionGroup,
              (provisionalGroups ?? groups).contains(where: { $0.name == draggedGroup }) else {
            return false
        }

        return true
    }

    private var canAcceptCollectionDrop: Bool {
        guard let draggedCollection,
              draggedCollection != TaskStore.defaultCollection,
              collectionSummary(named: draggedCollection) != nil else {
            return false
        }

        return true
    }

    private func collectionSummary(named name: String) -> TaskCollectionSummary? {
        groups.lazy.flatMap(\.collections).first { $0.name == name }
    }
}

private struct SidebarTaskDropCleanupDelegate: DropDelegate {
    let groups: [TaskCollectionGroupSummary]
    let dragState: TaskDragState
    @Binding var draggedCollection: String?
    @Binding var draggedGroup: String?
    @Binding var provisionalGroups: [TaskCollectionGroupSummary]?
    let moveCollection: (String, String, String?, String?) -> Bool
    let moveGroup: (String, String?, String?) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: TaskItemDrag.acceptedTypes)
            || info.hasItemsConforming(to: SidebarCollectionDrag.acceptedTypes)
            || info.hasItemsConforming(to: SidebarGroupDrag.acceptedTypes)
    }

    func dropEntered(info: DropInfo) {
        updateProvisionalGroupAtRootEdge(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateProvisionalGroupAtRootEdge(info: info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            dragState.finishDraggingAfterCurrentEvent(reason: "SidebarTaskDropCleanupDelegate.performDrop")
            if draggedCollection != nil || draggedGroup != nil {
                sidebarDragLogger.info(
                    "Sidebar drag cleanup collection='\(draggedCollection ?? "", privacy: .public)' group='\(draggedGroup ?? "", privacy: .public)'"
                )
            }
            draggedCollection = nil
            draggedGroup = nil
            provisionalGroups = nil
        }

        if info.hasItemsConforming(to: SidebarCollectionDrag.acceptedTypes) {
            return performCollectionDrop()
        }

        if info.hasItemsConforming(to: SidebarGroupDrag.acceptedTypes) {
            return performGroupDrop(info: info)
        }

        return true
    }

    private func performCollectionDrop() -> Bool {
        guard let source = draggedCollection else {
            return true
        }

        let finalGroups = provisionalGroups ?? groups
        guard let placement = collectionPlacement(for: source, in: finalGroups) else {
            sidebarDragLogger.info("Collection root drop no-op source='\(source, privacy: .public)'")
            return true
        }

        sidebarDragLogger.info(
            "Collection root drop performing source='\(source, privacy: .public)' group='\(placement.group, privacy: .public)'"
        )
        return moveCollection(source, placement.group, placement.after, placement.before)
    }

    private func performGroupDrop(info: DropInfo) -> Bool {
        guard let source = draggedGroup else {
            return true
        }

        let finalGroups = provisionalGroups ?? rootEdgeMovedGroups(for: source, location: info.location) ?? groups
        guard let placement = groupPlacement(for: source, in: finalGroups) else {
            sidebarDragLogger.info("Group root drop no-op source='\(source, privacy: .public)'")
            return true
        }

        sidebarDragLogger.info("Group root drop performing source='\(source, privacy: .public)'")
        return moveGroup(source, placement.after, placement.before)
    }

    private func updateProvisionalGroupAtRootEdge(info: DropInfo) {
        guard info.hasItemsConforming(to: SidebarGroupDrag.acceptedTypes),
              let source = draggedGroup,
              let movedGroups = rootEdgeMovedGroups(for: source, location: info.location) else {
            return
        }

        let edge = rootEdge(for: info.location) ?? "middle"
        sidebarDragLogger.debug(
            "Group root drop entered \(edge, privacy: .public) source='\(source, privacy: .public)' y=\(info.location.y, privacy: .public) order='\(sidebarGroupOrderDescription(movedGroups), privacy: .public)'"
        )
        withAnimation(.easeInOut(duration: 0.18)) {
            provisionalGroups = movedGroups
        }
    }

    private func rootEdgeMovedGroups(for source: String, location: CGPoint? = nil) -> [TaskCollectionGroupSummary]? {
        let baseGroups = provisionalGroups ?? groups
        guard let edge = location.flatMap(rootEdge(for:)) else {
            return nil
        }

        if edge == "top" {
            return moveGroupToTopInSidebarGroups(source, groups: baseGroups)
        }
        return moveGroupToBottomInSidebarGroups(source, groups: baseGroups)
    }

    private func rootEdge(for location: CGPoint) -> String? {
        // A group dropped in the root area goes to the top only when released in
        // the narrow band above the first group; anything lower (the empty space
        // below the list) moves it to the bottom.
        location.y <= sidebarRootGroupDropEdgeHeight ? "top" : "bottom"
    }
}
