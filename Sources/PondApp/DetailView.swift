import AppKit
import SwiftUI
import TaskCore
import UniformTypeIdentifiers

struct DetailView: View {
    @EnvironmentObject private var model: TaskAppModel
    @State private var focusedField: TaskFocusField?
    @State private var pendingDraftFocusID: String?
    @State private var activeTitleEdit: ActiveTaskTitleEdit?
    @State private var pendingFocusSelection: [TaskFocusField: TaskFocusSelectionRequest] = [:]
    @State private var activeDraft: ActiveDraftTask?
    @State private var committedDrafts: [CommittedDraftTask] = []
    @State private var pendingScrollItemID: String?
    @State private var draggedItemID: String?
    @State private var didReorderDraggedItem = false

    private var visibleStoredItems: [TaskItem] {
        let baseItems = model.visibleItems
        let pinnedIDs = Set([focusedField?.itemID, pendingDraftFocusID].compactMap { $0 })
        let visibleCommittedDrafts = committedDrafts.filter { draft in
            !hasStoredItem(id: draft.id) && model.itemIsVisible(draft.item)
        }
        let visibleItems = baseItems.insertingCommittedDrafts(
            visibleCommittedDrafts
        )

        if pinnedIDs.isEmpty {
            return visibleItems
        }

        let baseIDs = Set(visibleItems.map(\.id))
        return model.items.filter { item in
            if baseIDs.contains(item.id) {
                return true
            }

            guard pinnedIDs.contains(item.id) else {
                return false
            }

            if item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }

            return model.selectedCollectionName.map { $0 == item.collection } ?? true
        }
        .insertingCommittedDrafts(visibleCommittedDrafts)
    }

    private var visibleItems: [TaskItem] {
        if let pendingDraftItem {
            return visibleStoredItems.insertingDraft(pendingDraftItem, after: activeDraft?.previousItemID)
        }

        return visibleStoredItems
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        let items = visibleItems
                        ForEach(items) { item in
                            taskRow(item, storedItems: visibleStoredItems)
                        }
                        .animation(.easeInOut(duration: 0.18), value: items.map(\.id))

                        if pendingDraftItem == nil {
                            DraftTaskRow(
                                materializeDraft: { materializeDraft() },
                                createTaskFromDroppedFile: createTaskFromDroppedFile
                            )
                            .id("draft")
                        }
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .top)
                    .onDrop(
                        of: TaskItemDrag.acceptedTypes,
                        delegate: TaskListDropDelegate(
                            finishDragging: finishDragging
                        )
                    )
                    .background {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture(perform: focusLatestTaskField)
                    }
                }
                .background {
                    Color(nsColor: .textBackgroundColor)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: defocusTaskField)
                }
                .onChange(of: pendingScrollItemID) { _, itemID in
                    scrollToPendingItem(itemID, with: scrollProxy)
                }
            }
        }
        .navigationTitle(model.title)
        .toolbar {
            DetailToolbar()
        }
        .background(LocalKeyDownHandler(isActive: true, onKeyDown: handleKeyDown))
    }

    @ViewBuilder
    private func taskRow(_ item: TaskItem, storedItems: [TaskItem]) -> some View {
        let itemIsPendingDraft = isPendingDraft(item)

        let row = TaskRow(
            item: item,
            isPendingDraft: itemIsPendingDraft,
            activeTitle: activeTitle(for: item),
            focusedField: $focusedField,
            updateActiveTitleEdit: updateActiveTitleEdit,
            clearActiveTitleEdit: clearActiveTitleEdit,
            saveTitleChange: saveTitle,
            confirmTitleChange: confirmTitle,
            moveItemToCollection: moveToCollection,
            insertDraftBelow: insertDraftBelow,
            titleFocusSelectionBehavior: pendingFocusSelection[.title(item.id)],
            noteFocusSelectionBehavior: pendingFocusSelection[.note(item.id)],
            focusTextField: focusTextField,
            consumeFocusSelectionBehavior: { pendingFocusSelection[$0] = nil },
            hasVisibleItemAfter: hasVisibleItemAfter,
            moveFocus: moveFocus,
            moveItem: moveItem,
            deleteAndFocusPrevious: deleteAndFocusPrevious,
            deleteEmptyAndMoveFocusDown: deleteEmptyAndMoveFocusDown
        )
        .transition(
            .asymmetric(
                insertion: .identity,
                removal: .opacity
            )
        )
        .onAppear {
            if pendingDraftFocusID == item.id {
                focusDraftItem(id: item.id)
            }
        }

        if itemIsPendingDraft {
            row
        } else {
            row
                .onDrag {
                    beginDragging(item)
                    return TaskItemDrag.itemProvider(id: item.id)
                } preview: {
                    Color.clear.frame(width: 1, height: 1)
                }
                .onDrop(
                    of: TaskItemDrag.acceptedTypes,
                    delegate: TaskRowDropDelegate(
                        item: item,
                        visibleItems: storedItems,
                        draggedItemID: $draggedItemID,
                        didReorderDraggedItem: $didReorderDraggedItem,
                        moveItem: reorderItem,
                        finishDragging: finishDragging
                    )
                )
        }
    }

    private func beginDragging(_ item: TaskItem) {
        settlePendingDraftBeforeDragging(item)
        draggedItemID = item.id
        didReorderDraggedItem = false
    }

    private func finishDragging() {
        draggedItemID = nil
        didReorderDraggedItem = false
    }

    private func focusDraftItem(id: String) {
        focusTextField(.title(id))
        pendingDraftFocusID = nil
    }

    private func scrollToPendingItem(_ itemID: String?, with scrollProxy: ScrollViewProxy) {
        guard let itemID else {
            return
        }

        DispatchQueue.main.async {
            scrollProxy.scrollTo(itemID)
            if pendingScrollItemID == itemID {
                pendingScrollItemID = nil
            }
        }
    }

    private func focusTextField(
        _ field: TaskFocusField,
        selectionBehavior: TaskFocusSelectionBehavior = .moveInsertionPointToEnd
    ) {
        focusedField = field
        pendingFocusSelection[field] = TaskFocusSelectionRequest(behavior: selectionBehavior)
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard event.window?.sheetParent == nil else {
            return false
        }

        if event.keyCode == KeyCode.n, event.isCommandOptionOnlyKey {
            return focusNoteForFocusedItem()
        }

        guard event.isCommandOnlyKey else {
            return false
        }

        switch event.keyCode {
        case KeyCode.n:
            materializeDraft(collection: model.selectedCollectionName ?? TaskStore.defaultCollection)
            return true
        case KeyCode.d:
            return setFocusedStoredItemStatus(.draft)
        case KeyCode.r:
            return setFocusedStoredItemStatus(.ready)
        default:
            return false
        }
    }

    private func focusNoteForFocusedItem() -> Bool {
        guard let itemID = focusedField?.itemID,
              model.items.contains(where: { $0.id == itemID }) else {
            return false
        }

        clearCurrentTextFieldSelection()
        focusTextField(.note(itemID), selectionBehavior: .moveInsertionPointToEnd)
        return true
    }

    private func setFocusedStoredItemStatus(_ status: TaskStatus) -> Bool {
        guard let itemID = focusedField?.itemID,
              let item = model.items.first(where: { $0.id == itemID }) else {
            return false
        }

        model.setStatus(item, status: status)
        return true
    }

    private func materializeDraft(after previousItemID: String? = nil, collection: String? = nil) {
        if let pendingDraftItem {
            focusTextField(.title(pendingDraftItem.id))
            return
        }

        if let activeTitleEdit,
           activeTitleEdit.isEmpty,
           model.items.contains(where: { $0.id == activeTitleEdit.id }) {
            focusTextField(.title(activeTitleEdit.id))
            return
        }

        let itemID = model.makeTaskID()
        withoutTaskListAnimation {
            pendingDraftFocusID = itemID
            pendingScrollItemID = itemID
            activeDraft = ActiveDraftTask(
                item: TaskItem(
                    id: itemID,
                    title: "",
                    collection: collection ?? collectionForNewDraft(after: previousItemID)
                ),
                previousItemID: previousItemID
            )
        }
    }

    private func collectionForNewDraft(after previousItemID: String?) -> String {
        if let selectedCollectionName = model.selectedCollectionName {
            return selectedCollectionName
        }

        if let previousItemID,
           let previousItem = model.items.first(where: { $0.id == previousItemID }) {
            return previousItem.collection
        }

        return model.visibleItems.last?.collection ?? TaskStore.defaultCollection
    }

    private func createTaskFromDroppedFile(_ fileURL: URL) {
        guard let item = withoutTaskListAnimation({
            model.createTask(
                title: fileURL.lastPathComponent,
                collection: collectionForNewDraft(after: nil)
            )
        }) else {
            return
        }

        pendingScrollItemID = item.id
        focusTextField(.title(item.id))
    }

    private func focusLatestTaskField() {
        if let pendingDraftItem {
            persistFocusedDraftKeepingFocus(pendingDraftItem)
            focusTextField(.title(pendingDraftItem.id))
        } else {
            materializeDraft()
        }
    }

    private func persistFocusedDraftKeepingFocus(_ draftItem: TaskItem) {
        guard focusedField == .title(draftItem.id) else {
            return
        }

        let title = currentDraftTitle(draftItem)
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        saveDraft(draftItem, title: title, newFocus: .title(draftItem.id))
    }

    private func defocusTaskField() {
        saveFocusedDraftBeforeDefocus()
        focusedField = nil
    }

    private func saveFocusedDraftBeforeDefocus() {
        guard let pendingDraftItem,
              focusedField == .title(pendingDraftItem.id) else {
            return
        }

        saveDraft(pendingDraftItem, title: currentDraftTitle(pendingDraftItem), newFocus: nil)
    }

    private func settlePendingDraftBeforeDragging(_ draggedItem: TaskItem) {
        guard let pendingDraftItem else {
            return
        }

        let draftIsFocused = focusedField == .title(pendingDraftItem.id)
        guard draftIsFocused || activeDraft?.previousItemID == draggedItem.id else {
            return
        }

        let title = draftIsFocused ? currentDraftTitle(pendingDraftItem) : editedTitle(for: pendingDraftItem)
        saveDraft(pendingDraftItem, title: title, newFocus: nil)

        if draftIsFocused {
            focusedField = nil
        }
    }

    private func currentDraftTitle(_ item: TaskItem) -> String {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.string
            ?? editedTitle(for: item)
    }

    private func editedTitle(for item: TaskItem) -> String {
        activeTitleEdit?.id == item.id ? activeTitleEdit?.title ?? item.title : item.title
    }

    private func activeTitle(for item: TaskItem) -> String? {
        activeTitleEdit?.id == item.id ? activeTitleEdit?.title : nil
    }

    private func updateActiveTitleEdit(id: String, title: String) {
        activeTitleEdit = ActiveTaskTitleEdit(id: id, title: title)
    }

    private func clearActiveTitleEdit(id: String) {
        if activeTitleEdit?.id == id {
            activeTitleEdit = nil
        }
    }

    private var pendingDraftItem: TaskItem? {
        guard let activeDraft, !hasStoredItem(id: activeDraft.id) else {
            return nil
        }

        return activeDraft.item
    }

    private func isPendingDraft(_ item: TaskItem) -> Bool {
        !hasStoredItem(id: item.id)
    }

    private func isActiveDraft(_ item: TaskItem) -> Bool {
        pendingDraftItem?.id == item.id
    }

    private func hasStoredItem(id: String) -> Bool {
        model.items.contains { $0.id == id }
    }

    private func saveTitle(_ item: TaskItem, _ title: String, _ newFocus: TaskFocusField?) {
        if isActiveDraft(item) {
            saveDraft(item, title: title, newFocus: newFocus)
        } else if hasStoredItem(id: item.id) {
            let statusAfterEdit = title == item.title ? nil : model.autoDraftEditStatus
            model.renameOrDeleteIfEmpty(item, title: title, statusAfterEdit: statusAfterEdit)
        }
    }

    private func confirmTitle(_ item: TaskItem, _ title: String, _ newFocus: TaskFocusField?) {
        if isActiveDraft(item) {
            saveDraft(
                item,
                title: title,
                newFocus: newFocus,
                status: model.autoDraftConfirmationStatus ?? .draft
            )
        } else if hasStoredItem(id: item.id) {
            model.renameOrDeleteIfEmpty(
                item,
                title: title,
                statusAfterEdit: model.autoDraftConfirmationStatus
            )
        }
    }

    private func saveDraft(
        _ item: TaskItem,
        title: String,
        newFocus: TaskFocusField?,
        status: TaskStatus = .draft
    ) {
        guard isActiveDraft(item) else {
            return
        }

        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if newFocus != .collection(item.id) {
                discardDraft(item.id)
            }

            return
        }

        let collection = activeDraft?.item.collection ?? item.collection
        let previousItemID = activeDraft?.previousItemID
        let focusSelectionBehavior = titleFocusSelectionBehavior(for: item, fallback: .moveInsertionPointToEnd)

        let createdItem = withoutTaskListAnimation {
            discardDraft(item.id, clearsActiveTitleEdit: newFocus != .title(item.id))
            let createdItem = model.createTask(title: title, collection: collection, id: item.id, status: status)

            if createdItem != nil, let previousItemID {
                model.reorderItem(id: item.id, after: previousItemID, before: nil)
            }

            return createdItem
        }

        if createdItem != nil {
            if newFocus == .title(item.id) {
                focusTextField(.title(item.id), selectionBehavior: focusSelectionBehavior)
            }
        } else {
            withoutTaskListAnimation {
                activeDraft = ActiveDraftTask(
                    item: TaskItem(
                        id: item.id,
                        title: title,
                        collection: collection,
                        status: item.status,
                        createdAt: item.createdAt,
                        updatedAt: item.updatedAt
                    ),
                    previousItemID: previousItemID
                )
            }
        }
    }

    private func titleFocusSelectionBehavior(
        for item: TaskItem,
        fallback: TaskFocusSelectionBehavior
    ) -> TaskFocusSelectionBehavior {
        guard focusedField == .title(item.id),
              let textView = NSApp.keyWindow?.firstResponder as? NSTextView else {
            return fallback
        }

        return .range(textView.selectedRange())
    }

    private func discardDraft(_ id: String, clearsActiveTitleEdit: Bool = true) {
        if activeDraft?.id == id {
            activeDraft = nil
        }

        if pendingDraftFocusID == id {
            pendingDraftFocusID = nil
        }

        if clearsActiveTitleEdit {
            clearActiveTitleEdit(id: id)
        }
    }

    private func moveToCollection(_ item: TaskItem, _ collection: String) {
        if isActiveDraft(item) {
            activeDraft?.item.collection = collection
        } else if hasStoredItem(id: item.id) {
            model.move(item, collection: collection)
        }
    }

    private func insertDraftBelow(_ item: TaskItem, title: String) {
        if isActiveDraft(item) {
            commitPendingDraftAndMaterializeNext(
                item,
                title: title,
                status: model.autoDraftConfirmationStatus ?? .draft
            )
        } else if hasStoredItem(id: item.id) {
            model.renameOrDeleteIfEmpty(item, title: title, statusAfterEdit: model.autoDraftConfirmationStatus)
            materializeDraft(after: item.id)
        }
    }

    private func commitPendingDraftAndMaterializeNext(
        _ item: TaskItem,
        title: String,
        status: TaskStatus
    ) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else {
            _ = deleteEmptyAndMoveFocusDown(item)
            return
        }

        let collection = activeDraft?.item.collection ?? item.collection
        let previousItemID = activeDraft?.previousItemID
        let committedItemID = uniqueDraftCommitID(excluding: item.id)
        let committedItem = TaskItem(
            id: committedItemID,
            title: title,
            collection: collection,
            status: status,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt
        )

        withoutTaskListAnimation {
            committedDrafts.append(CommittedDraftTask(item: committedItem, previousItemID: previousItemID))
            activeDraft = ActiveDraftTask(
                item: TaskItem(id: item.id, title: "", collection: collection),
                previousItemID: committedItemID
            )
        }

        model.createTaskInBackground(
            title: title,
            collection: collection,
            id: committedItemID,
            status: status,
            disablesAnimations: true
        ) { createdItem in
            withoutTaskListAnimation {
                if createdItem != nil, let previousItemID {
                    model.reorderItem(id: committedItemID, after: previousItemID, before: nil)
                }

                committedDrafts.removeAll { $0.id == committedItemID }
            }
        }
    }

    private func uniqueDraftCommitID(excluding draftID: String) -> String {
        var id = model.makeTaskID()
        while id == draftID || committedDrafts.contains(where: { $0.id == id }) {
            id = model.makeTaskID()
        }
        return id
    }

    private func hasVisibleItemAfter(_ item: TaskItem) -> Bool {
        let visibleItems = self.visibleItems
        guard let index = visibleItems.firstIndex(where: { $0.id == item.id }) else {
            return false
        }

        return focusTarget(in: visibleItems, from: index, direction: .down, selectionBehavior: .moveInsertionPointToEnd) != nil
    }

    @discardableResult
    private func moveFocus(
        from item: TaskItem,
        direction: TaskFocusDirection,
        selectionBehavior: TaskFocusSelectionBehavior = .moveInsertionPointToEnd
    ) -> Bool {
        let visibleItems = self.visibleItems
        guard let index = visibleItems.firstIndex(where: { $0.id == item.id }) else {
            return false
        }

        switch direction {
        case .up:
            if focusedField == .note(item.id), canFocusTitle(of: item) {
                focusTextField(.title(item.id), selectionBehavior: selectionBehavior)
                return true
            }

            guard let target = focusTarget(
                in: visibleItems,
                from: index,
                direction: .up,
                selectionBehavior: selectionBehavior
            ) else {
                return false
            }

            focusTextField(target.field, selectionBehavior: target.selectionBehavior)
            return true

        case .down:
            if focusedField == .title(item.id), !item.notes.isEmpty {
                focusTextField(.note(item.id), selectionBehavior: selectionBehavior)
                return true
            }

            guard let target = focusTarget(
                in: visibleItems,
                from: index,
                direction: .down,
                selectionBehavior: selectionBehavior
            ) else {
                return false
            }

            focusTextField(target.field, selectionBehavior: target.selectionBehavior)
            return true
        }
    }

    private func focusTarget(
        in visibleItems: [TaskItem],
        from index: Int,
        direction: TaskFocusDirection,
        selectionBehavior: TaskFocusSelectionBehavior
    ) -> (field: TaskFocusField, selectionBehavior: TaskFocusSelectionBehavior)? {
        let candidateIndexes: StrideThrough<Int>
        switch direction {
        case .up:
            guard index > 0 else {
                return nil
            }
            candidateIndexes = stride(from: index - 1, through: 0, by: -1)
        case .down:
            guard visibleItems.indices.contains(index + 1) else {
                return nil
            }
            candidateIndexes = stride(from: index + 1, through: visibleItems.count - 1, by: 1)
        }

        for candidateIndex in candidateIndexes {
            let candidate = visibleItems[candidateIndex]
            guard canFocusTitle(of: candidate) else {
                continue
            }

            switch direction {
            case .up:
                return (
                    candidate.notes.isEmpty ? .title(candidate.id) : .note(candidate.id),
                    selectionBehavior
                )
            case .down:
                return (.title(candidate.id), selectionBehavior)
            }
        }

        return nil
    }

    private func canFocusTitle(of item: TaskItem) -> Bool {
        isPendingDraft(item) || (item.status != .inProgress && item.status != .completed)
    }

    private func deleteAndFocusPrevious(_ item: TaskItem) {
        let focusTarget = focusTargetAfterDeleting(item)
        let deleted: Bool

        if isActiveDraft(item) {
            discardDraft(item.id)
            deleted = true
        } else if editedTitle(for: item).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            deleted = model.delete(id: item.id)
        } else {
            deleted = model.delete(item)
        }

        if deleted {
            clearActiveTitleEdit(id: item.id)

            if let focusTarget {
                focusTextField(focusTarget.field, selectionBehavior: focusTarget.selectionBehavior)
            }
        }
    }

    private func deleteEmptyAndMoveFocusDown(
        _ item: TaskItem,
        selectionBehavior: TaskFocusSelectionBehavior = .moveInsertionPointToEnd
    ) -> Bool {
        let visibleItems = self.visibleItems
        guard let index = visibleItems.firstIndex(where: { $0.id == item.id }) else {
            return false
        }

        guard let focusTarget = focusTarget(
            in: visibleItems,
            from: index,
            direction: .down,
            selectionBehavior: selectionBehavior
        ) else {
            return true
        }

        let deleted: Bool
        if isActiveDraft(item) {
            discardDraft(item.id)
            deleted = true
        } else if editedTitle(for: item).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            deleted = model.delete(id: item.id)
        } else {
            deleted = model.delete(item)
        }

        if deleted {
            clearActiveTitleEdit(id: item.id)
            focusTextField(focusTarget.field, selectionBehavior: focusTarget.selectionBehavior)
        }

        return true
    }

    private func focusTargetAfterDeleting(
        _ item: TaskItem
    ) -> (field: TaskFocusField, selectionBehavior: TaskFocusSelectionBehavior)? {
        let visibleItems = self.visibleItems
        guard let index = visibleItems.firstIndex(where: { $0.id == item.id }) else {
            return nil
        }

        if index > 0 {
            return (.title(visibleItems[index - 1].id), .selectAll)
        }

        if visibleItems.indices.contains(index + 1) {
            return (.title(visibleItems[index + 1].id), .moveInsertionPointToEnd)
        }

        return nil
    }

    private func reorderItem(_ id: String, _ previousID: String?, _ nextID: String?) {
        withAnimation(.easeInOut(duration: 0.18)) {
            model.reorderItem(id: id, after: previousID, before: nextID)
        }
    }

    private func moveItem(_ item: TaskItem, direction: TaskFocusDirection) -> Bool {
        guard hasStoredItem(id: item.id) else {
            return false
        }

        let storedVisibleItems = visibleItems.filter { hasStoredItem(id: $0.id) }
        guard let index = storedVisibleItems.firstIndex(where: { $0.id == item.id }) else {
            return false
        }

        let targetIndex: Int
        switch direction {
        case .up:
            targetIndex = index - 1
        case .down:
            targetIndex = index + 1
        }
        guard storedVisibleItems.indices.contains(targetIndex) else {
            return true
        }

        var reorderedItems = storedVisibleItems
        let movedItem = reorderedItems.remove(at: index)
        reorderedItems.insert(movedItem, at: targetIndex)

        guard let newIndex = reorderedItems.firstIndex(where: { $0.id == item.id }) else {
            return false
        }

        let previousID = newIndex > 0 ? reorderedItems[newIndex - 1].id : nil
        let nextID = reorderedItems.indices.contains(newIndex + 1) ? reorderedItems[newIndex + 1].id : nil
        reorderItem(item.id, previousID, nextID)
        return true
    }

    private func withoutTaskListAnimation<T>(_ updates: () -> T) -> T {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        return withTransaction(transaction, updates)
    }
}

private struct ActiveDraftTask {
    var item: TaskItem
    var previousItemID: String?

    var id: String {
        item.id
    }
}

private struct CommittedDraftTask: Identifiable {
    var item: TaskItem
    var previousItemID: String?

    var id: String {
        item.id
    }
}

private extension Array where Element == TaskItem {
    func insertingDraft(_ draftItem: TaskItem, after previousItemID: String?) -> [TaskItem] {
        guard let previousItemID,
              let previousIndex = firstIndex(where: { $0.id == previousItemID }) else {
            return self + [draftItem]
        }

        var items = self
        items.insert(draftItem, at: previousIndex + 1)
        return items
    }

    func insertingCommittedDrafts(_ drafts: [CommittedDraftTask]) -> [TaskItem] {
        drafts.reduce(self) { items, draft in
            guard !items.contains(where: { $0.id == draft.id }) else {
                return items
            }

            return items.insertingDraft(draft.item, after: draft.previousItemID)
        }
    }
}

private struct DetailToolbar: ToolbarContent {
    @EnvironmentObject private var model: TaskAppModel

    var body: some ToolbarContent {
        ToolbarItem(id: "taskOptions") {
            taskOptionsMenu
        }

        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed)
        }

        ToolbarItem(id: "taskSearch") {
            ToolbarSearchField(text: $model.searchText)
                .frame(width: 180)
                .padding(.leading, searchLeadingPadding)
                .help("Search")
        }
    }

    private var searchLeadingPadding: CGFloat {
        if #available(macOS 26.0, *) {
            return 0
        }

        return 12
    }

    private var taskOptionsMenu: some View {
        Menu {
            if let collection = model.selectedCollectionSummary {
                CollectionActionMenuItems(
                    collection: collection,
                    showsCLICommand: true,
                    showsExport: true,
                    groupsCollectionActionsAtBottom: true,
                    bulkStatusScope: .visibleItems
                )
            } else {
                Divider()

                Button("Bulk Change Status...") {
                    model.requestBulkStatusChangeForVisibleItems()
                }
                .disabled(!model.canBulkChangeVisibleStatuses)
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .menuIndicator(.hidden)
        .help("Task options")
    }
}

private struct ToolbarSearchField: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> SafeSearchField {
        let searchField = SafeSearchField()
        searchField.placeholderString = "Search"
        searchField.delegate = context.coordinator
        searchField.target = context.coordinator
        searchField.action = #selector(Coordinator.searchFieldChanged(_:))
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.controlSize = .regular
        searchField.font = .systemFont(ofSize: NSFont.systemFontSize)
        searchField.cell?.usesSingleLineMode = true
        searchField.cell?.wraps = false
        searchField.cell?.isScrollable = true
        return searchField
    }

    func updateNSView(_ searchField: SafeSearchField, context: Context) {
        context.coordinator.parent = self
        guard !searchField.hasMarkedText,
              searchField.stringValue != text else {
            return
        }

        searchField.stringValue = text
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: ToolbarSearchField

        init(_ parent: ToolbarSearchField) {
            self.parent = parent
        }

        @MainActor
        @objc func searchFieldChanged(_ sender: NSSearchField) {
            parent.text = sender.stringValue
        }

        @MainActor
        func controlTextDidChange(_ notification: Notification) {
            guard let searchField = notification.object as? NSSearchField else {
                return
            }

            parent.text = searchField.stringValue
        }
    }

    final class SafeSearchField: NSSearchField {
        var hasMarkedText: Bool {
            (currentEditor() as? NSTextView)?.hasMarkedText() ?? false
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else {
                super.mouseDown(with: event)
                return
            }

            if clearButtonContains(event) {
                clearSearchText()
                return
            }

            window.makeFirstResponder(self)
            moveInsertionPointToEnd(retries: 1)
        }

        private func clearButtonContains(_ event: NSEvent) -> Bool {
            guard let cell = cell as? NSSearchFieldCell,
                  !stringValue.isEmpty else {
                return false
            }

            let point = convert(event.locationInWindow, from: nil)
            return cell.cancelButtonRect(forBounds: bounds).contains(point)
        }

        private func clearSearchText() {
            stringValue = ""
            if let action {
                NSApp.sendAction(action, to: target, from: self)
            }
        }

        private func moveInsertionPointToEnd(retries: Int = 0) {
            guard let editor = currentEditor() as? NSTextView else {
                guard retries > 0 else {
                    return
                }

                DispatchQueue.main.async { [weak self] in
                    self?.moveInsertionPointToEnd(retries: retries - 1)
                }
                return
            }

            let length = (stringValue as NSString).length
            editor.setSelectedRange(NSRange(location: length, length: 0))
        }
    }
}

private struct TaskRowDropDelegate: DropDelegate {
    let item: TaskItem
    let visibleItems: [TaskItem]
    @Binding var draggedItemID: String?
    @Binding var didReorderDraggedItem: Bool
    let moveItem: (String, String?, String?) -> Void
    let finishDragging: () -> Void

    func dropEntered(info: DropInfo) {
        if reorderDraggedItem() {
            didReorderDraggedItem = true
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        if !didReorderDraggedItem {
            _ = reorderDraggedItem()
        }

        finishDragging()
        return true
    }

    private func reorderDraggedItem() -> Bool {
        guard let draggedItemID,
              draggedItemID != item.id,
              let fromIndex = visibleItems.firstIndex(where: { $0.id == draggedItemID }),
              let toIndex = visibleItems.firstIndex(where: { $0.id == item.id }) else {
            return false
        }

        var reorderedItems = visibleItems
        let draggedItem = reorderedItems.remove(at: fromIndex)
        guard let targetIndex = reorderedItems.firstIndex(where: { $0.id == item.id }) else {
            return false
        }

        let insertionIndex = fromIndex < toIndex ? targetIndex + 1 : targetIndex
        reorderedItems.insert(draggedItem, at: insertionIndex)

        guard let newIndex = reorderedItems.firstIndex(where: { $0.id == draggedItemID }) else {
            return false
        }

        let previousID = newIndex > 0 ? reorderedItems[newIndex - 1].id : nil
        let nextID = reorderedItems.indices.contains(newIndex + 1) ? reorderedItems[newIndex + 1].id : nil
        moveItem(draggedItemID, previousID, nextID)
        return true
    }
}

private struct TaskListDropDelegate: DropDelegate {
    let finishDragging: () -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        finishDragging()
        return true
    }
}

private enum TaskItemDrag {
    static let type = UTType(exportedAs: "dev.kymok.pond.task-item")
    static let acceptedTypes = [type]

    static func itemProvider(id: String) -> NSItemProvider {
        let provider = NSItemProvider(object: id as NSString)
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { completion in
            completion(id.data(using: .utf8), nil)
            return nil
        }
        return provider
    }
}

private struct DraftTaskRow: View {
    let materializeDraft: () -> Void
    let createTaskFromDroppedFile: (URL) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "circle")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.tertiary)
                .frame(width: 24, height: 24)
                .alignmentGuide(.top) { dimensions in
                    dimensions[VerticalAlignment.center] - TaskRowLayout.titleFirstLineCenterY
                }

            Color.clear
                .frame(width: 24, height: 24)
                .alignmentGuide(.top) { dimensions in
                    dimensions[VerticalAlignment.center] - TaskRowLayout.titleFirstLineCenterY
                }

            Text("Title")
                .frame(height: TaskRowLayout.titleLineHeight, alignment: .center)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, TaskRowLayout.rowVerticalPadding)
        .padding(.horizontal, 12)
        .frame(minHeight: TaskRowLayout.rowMinHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: materializeDraft)
        .onDrop(of: [UTType.fileURL], isTargeted: nil, perform: handleFileDrop)
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let fileURL = droppedFileURL(from: item) else {
                return
            }

            DispatchQueue.main.async {
                createTaskFromDroppedFile(fileURL)
            }
        }

        return true
    }
}

private func droppedFileURL(from item: NSSecureCoding?) -> URL? {
    if let url = item as? URL {
        return url
    }

    if let url = item as? NSURL {
        return url as URL
    }

    if let data = item as? Data,
       let string = String(data: data, encoding: .utf8) {
        return URL(string: string)
    }

    if let string = item as? String {
        return URL(string: string)
    }

    return nil
}
