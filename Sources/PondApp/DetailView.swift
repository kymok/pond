import AppKit
import SwiftUI
import TaskCore
import UniformTypeIdentifiers

struct DetailView: View {
    @Environment(TaskAppModel.self) private var model
    @Environment(TaskDragState.self) private var taskDragState
    @State private var focusedField: TaskFocusField?
    @State private var pendingDraftFocusID: String?
    @State private var activeTitleEdit: ActiveTaskTitleEdit?
    @State private var pendingFocusSelection: [TaskFocusField: TaskFocusSelectionRequest] = [:]
    @State private var activeDraft: ActiveDraftTask?
    @State private var committedDrafts: [CommittedDraftTask] = []
    @State private var pendingScrollItemID: String?

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
            return displayedStoredItems.insertingDraft(pendingDraftItem, after: activeDraft?.previousItemID)
        }

        return displayedStoredItems
    }

    private var displayedStoredItems: [TaskItem] {
        taskDragState.orderedItems(visibleStoredItems)
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        let items = visibleItems
                        ForEach(items) { item in
                            taskRow(item, storedItems: displayedStoredItems)
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
                            visibleItems: displayedStoredItems,
                            dragState: taskDragState,
                            moveItem: reorderItem,
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
            deleteEmptyAndMoveFocusDown: deleteEmptyAndMoveFocusDown,
            mergeWithPrevious: mergeWithPrevious,
            splitTitle: splitTitle
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
        .opacity(taskDragState.draggedItemID == item.id ? 0 : 1)

        if itemIsPendingDraft {
            row
        } else {
            row
                .onDrag {
                    beginDragging(item)
                    return TaskItemDrag.itemProvider(id: item.id)
                } preview: {
                    TaskDragPreview(
                        item: item,
                        title: activeTitle(for: item) ?? item.title,
                        showsCollection: model.selectedCollectionName == nil,
                        collectionColor: model.collectionColor(named: item.collection),
                        sourceSize: taskDragState.sourceSize(for: item.id)
                    )
                }
                .onDrop(
                    of: TaskItemDrag.acceptedTypes,
                    delegate: TaskRowDropDelegate(
                        item: item,
                        visibleItems: storedItems,
                        dragState: taskDragState,
                        moveItem: reorderItem,
                        finishDragging: finishDragging
                    )
                )
        }
    }

    private func beginDragging(_ item: TaskItem) {
        settlePendingDraftBeforeDragging(item)
        taskDragState.beginDragging(
            item: item,
            visibleItemIDs: visibleStoredItems.map(\.id),
            selectedCollection: model.selectedCollectionName
        )
    }

    private func finishDragging() {
        taskDragState.finishDragging(reason: "DetailView.finishDragging")
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
            _ = focusNoteForFocusedItem()
            return true
        }

        guard event.isCommandOnlyKey else {
            return false
        }

        switch event.keyCode {
        case KeyCode.n:
            materializeDraft(collection: model.selectedCollectionName ?? TaskStore.defaultCollection)
            return true
        case KeyCode.backspace:
            return deleteFocusedItem()
        case KeyCode.d:
            return setFocusedStoredItemStatus(.draft)
        default:
            return false
        }
    }

    private func deleteFocusedItem() -> Bool {
        guard let itemID = focusedField?.itemID,
              let item = visibleItems.first(where: { $0.id == itemID }) else {
            return false
        }

        deleteAndFocusPrevious(item)
        return true
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
            if let previousItemID {
                if relocatePendingDraftIfEmpty(pendingDraftItem, after: previousItemID, collection: collection) {
                    return
                }

                saveDraft(pendingDraftItem, title: pendingDraftTitle(pendingDraftItem), newFocus: nil)
                if let remainingDraft = self.pendingDraftItem {
                    focusTextField(.title(remainingDraft.id))
                    return
                }
            } else {
                focusTextField(.title(pendingDraftItem.id))
                return
            }
        }

        if let activeTitleEdit,
           activeTitleEdit.isEmpty,
           model.items.contains(where: { $0.id == activeTitleEdit.id }) {
            focusTextField(.title(activeTitleEdit.id))
            return
        }

        createDraft(after: previousItemID, collection: collection)
    }

    private func relocatePendingDraftIfEmpty(
        _ item: TaskItem,
        after previousItemID: String,
        collection: String?
    ) -> Bool {
        guard pendingDraftTitle(item).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        var movedItem = item
        movedItem.collection = collection ?? collectionForNewDraft(after: previousItemID)

        withoutTaskListAnimation {
            activeDraft = ActiveDraftTask(item: movedItem, previousItemID: previousItemID)
            pendingScrollItemID = item.id
        }
        focusTextField(.title(item.id))
        return true
    }

    private func createDraft(after previousItemID: String? = nil, collection: String? = nil) {
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

    private func pendingDraftTitle(_ item: TaskItem) -> String {
        if focusedField == .title(item.id) {
            return currentDraftTitle(item)
        }

        return editedTitle(for: item)
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

    private func storedItem(for item: TaskItem) -> TaskItem? {
        model.items.first { $0.id == item.id }
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
                status: confirmationStatus(for: item) ?? .draft
            )
        } else if let storedItem = storedItem(for: item) {
            model.renameOrDeleteIfEmpty(
                storedItem,
                title: title,
                statusAfterEdit: confirmationStatus(for: storedItem)
            )
        }
    }

    private func confirmationStatus(for item: TaskItem) -> TaskStatus? {
        item.status == .draft ? .ready : model.autoDraftConfirmationStatus
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
                status: confirmationStatus(for: item) ?? .draft
            )
        } else if let storedItem = storedItem(for: item) {
            model.renameOrDeleteIfEmpty(
                storedItem,
                title: title,
                statusAfterEdit: confirmationStatus(for: storedItem)
            )
            materializeDraft(after: storedItem.id)
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

    private func mergeWithPrevious(_ item: TaskItem, title currentTitle: String) -> Bool {
        let visibleItems = self.visibleItems
        guard let index = visibleItems.firstIndex(where: { $0.id == item.id }),
              index > 0 else {
            return false
        }

        let previousItem = visibleItems[index - 1]
        guard previousItem.status == .draft || previousItem.status == .ready else {
            return true
        }
        guard previousItem.notes.isEmpty else {
            return true
        }

        let insertionPoint = (previousItem.title as NSString).length
        if isActiveDraft(item) {
            discardDraft(item.id)
            model.rename(previousItem, title: previousItem.title + currentTitle, statusAfterEdit: nil)
            focusTextField(.title(previousItem.id), selectionBehavior: .range(NSRange(location: insertionPoint, length: 0)))
            return true
        }

        guard hasStoredItem(id: item.id),
              model.mergeItem(item, into: previousItem, title: currentTitle) != nil else {
            return true
        }

        clearActiveTitleEdit(id: item.id)
        focusTextField(.title(previousItem.id), selectionBehavior: .range(NSRange(location: insertionPoint, length: 0)))
        return true
    }

    private func splitTitle(_ item: TaskItem, firstTitle: String, secondTitle: String) -> Bool {
        if isActiveDraft(item) {
            return splitActiveDraft(item, firstTitle: firstTitle, secondTitle: secondTitle)
        }

        guard hasStoredItem(id: item.id) else {
            return false
        }

        let secondID = model.makeTaskID()
        guard let secondItem = model.splitItem(
            item,
            firstTitle: firstTitle,
            secondTitle: secondTitle,
            secondID: secondID
        ) else {
            return true
        }

        clearActiveTitleEdit(id: item.id)
        pendingScrollItemID = secondItem.id
        focusTextField(.title(secondItem.id), selectionBehavior: .range(NSRange(location: 0, length: 0)))
        return true
    }

    private func splitActiveDraft(_ item: TaskItem, firstTitle: String, secondTitle: String) -> Bool {
        guard isActiveDraft(item) else {
            return false
        }

        let collection = activeDraft?.item.collection ?? item.collection
        let previousItemID = activeDraft?.previousItemID
        let secondID = uniqueDraftCommitID(excluding: item.id)

        withoutTaskListAnimation {
            discardDraft(item.id)
        }

        guard let firstItem = model.createTask(
            title: firstTitle,
            collection: collection,
            id: item.id,
            status: .ready
        ),
            let secondItem = model.createTask(
                title: secondTitle,
                collection: collection,
                id: secondID,
                status: .draft
            ) else {
            return true
        }

        if let previousItemID {
            model.reorderItem(id: firstItem.id, after: previousItemID, before: nil)
        }
        model.reorderItem(id: secondItem.id, after: firstItem.id, before: nil)
        pendingScrollItemID = secondItem.id
        focusTextField(.title(secondItem.id), selectionBehavior: .range(NSRange(location: 0, length: 0)))
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
            return (.title(visibleItems[index - 1].id), .moveInsertionPointToEnd)
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
    @Environment(TaskAppModel.self) private var model

    var body: some ToolbarContent {
        @Bindable var model = model
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

                Button("Bulk Change Statuses…") {
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
        .help("Task Options")
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
    let dragState: TaskDragState
    let moveItem: (String, String?, String?) -> Void
    let finishDragging: () -> Void

    func dropEntered(info: DropInfo) {
        dragState.moveDraggedItem(
            over: item.id,
            visibleItemIDs: visibleItems.map(\.id)
        )
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            finishDragging()
        }

        guard let placement = dragState.dropPlacement(visibleItemIDs: visibleItems.map(\.id)) else {
            return false
        }

        moveItem(placement.itemID, placement.previousID, placement.nextID)
        return true
    }
}

private struct TaskListDropDelegate: DropDelegate {
    let visibleItems: [TaskItem]
    let dragState: TaskDragState
    let moveItem: (String, String?, String?) -> Void
    let finishDragging: () -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            finishDragging()
        }

        guard let placement = dragState.dropPlacement(visibleItemIDs: visibleItems.map(\.id)) else {
            return false
        }

        moveItem(placement.itemID, placement.previousID, placement.nextID)
        return true
    }
}

private struct TaskDragPreview: View {
    let item: TaskItem
    let title: String
    let showsCollection: Bool
    let collectionColor: TaskCollectionColor
    let sourceSize: CGSize?

    var body: some View {
        previewContent
            .frame(
                width: frameSize.width,
                height: sourceSize?.height,
                alignment: .leading
            )
            .frame(minHeight: TaskRowLayout.rowMinHeight)
            .clipped()
    }

    private var previewContent: some View {
        HStack(alignment: .top, spacing: 10) {
            TaskStatusIcon(
                status: item.status,
                font: .system(size: 20, weight: .regular)
            )
                .frame(width: 24, height: 24)
                .alignmentGuide(.top) { dimensions in
                    dimensions[VerticalAlignment.center] - TaskRowLayout.titleFirstLineCenterY
                }

            itemMenuIcon
                .alignmentGuide(.top) { dimensions in
                    dimensions[VerticalAlignment.center] - TaskRowLayout.titleFirstLineCenterY
                }

            VStack(alignment: .leading, spacing: 6) {
                titleText

                if let note = item.notes.first {
                    notePreview(note.body)
                }
            }
            .frame(minHeight: TaskRowLayout.titleLineHeight, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsCollection {
                collectionChip
            }
        }
        .padding(.vertical, TaskRowLayout.rowVerticalPadding)
        .padding(.horizontal, 12)
        .frame(minHeight: TaskRowLayout.rowMinHeight)
    }

    private var frameSize: CGSize {
        CGSize(
            width: sourceSize?.width ?? 360,
            height: sourceSize?.height ?? TaskRowLayout.rowMinHeight
        )
    }

    private var titleText: some View {
        Text(title.isEmpty ? "Title" : title)
            .font(.system(size: TaskRowLayout.titleFont.pointSize))
            .foregroundStyle(titleColor)
            .lineSpacing(TaskRowLayout.titleLineSpacing)
            .frame(minHeight: TaskRowLayout.titleLineHeight, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var titleColor: HierarchicalShapeStyle {
        if title.isEmpty {
            return .tertiary
        }

        return item.status.dimsTitle ? .secondary : .primary
    }

    @ViewBuilder
    private var itemMenuIcon: some View {
        if title != item.title {
            ZStack {
                Image(systemName: "circle.fill")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.quaternary)

                Circle()
                    .fill(Color.blue)
                    .frame(width: 5, height: 5)
            }
            .frame(width: 24, height: 24)
        } else {
            Image(systemName: "ellipsis.circle.fill")
                .font(.system(size: 16, weight: .regular))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.primary, .quaternary)
                .frame(width: 24, height: 24)
        }
    }

    private func notePreview(_ body: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: "square.and.pencil")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16, height: TaskRowLayout.noteLineHeight, alignment: .center)
                .padding(.vertical, 2)

            Text(body.isEmpty ? "Note" : body)
                .font(.system(size: TaskRowLayout.noteFont.pointSize))
                .foregroundStyle(body.isEmpty ? .tertiary : .secondary)
                .lineSpacing(TaskRowLayout.noteLineSpacing)
                .frame(minHeight: TaskRowLayout.noteLineHeight, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    private var collectionChip: some View {
        HStack(spacing: 4) {
            CollectionColorSwatch(color: collectionColor, size: 7)

            Text(item.collection)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2)
                .imageScale(.small)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(width: TaskRowLayout.collectionControlContentWidth, alignment: .leading)
        .padding(.horizontal, TaskRowLayout.collectionControlHorizontalPadding)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
        .frame(width: TaskRowLayout.collectionControlWidth)
        .clipped()
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
