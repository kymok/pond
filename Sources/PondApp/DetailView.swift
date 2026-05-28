import AppKit
import SwiftUI
import TodoCore
import UniformTypeIdentifiers

struct DetailView: View {
    @EnvironmentObject private var model: TodoAppModel
    @State private var focusedField: TodoFocusField?
    @State private var pendingDraftFocusID: String?
    @State private var activeTitleEdit: ActiveTodoTitleEdit?
    @State private var pendingTitleFocusSelection: [String: TodoFocusSelectionBehavior] = [:]
    @State private var draftItem: TodoItem?
    @State private var draftPreviousItemID: String?
    @State private var pendingScrollItemID: String?
    @State private var draggedItemID: String?
    @State private var didReorderDraggedItem = false

    private var visibleStoredItems: [TodoItem] {
        let baseItems = model.visibleItems
        let pinnedIDs = Set([focusedField?.itemID, pendingDraftFocusID].compactMap { $0 })

        if pinnedIDs.isEmpty {
            return baseItems
        }

        let baseIDs = Set(baseItems.map(\.id))
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
    }

    private var visibleItems: [TodoItem] {
        if let pendingDraftItem {
            return visibleStoredItems.insertingDraft(pendingDraftItem, after: draftPreviousItemID)
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
                            todoRow(item, storedItems: visibleStoredItems)
                        }
                        .animation(.easeInOut(duration: 0.18), value: items.map(\.id))

                        if pendingDraftItem == nil {
                            DraftTodoRow(
                                materializeDraft: { materializeDraft() },
                                createTodoFromDroppedFile: createTodoFromDroppedFile
                            )
                            .id("draft")
                        }
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .top)
                    .onDrop(
                        of: TodoItemDrag.acceptedTypes,
                        delegate: TodoListDropDelegate(
                            finishDragging: finishDragging
                        )
                    )
                    .background {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture(perform: focusLatestTodoField)
                    }
                }
                .background {
                    Color(nsColor: .textBackgroundColor)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: defocusTodoField)
                }
                .onChange(of: pendingScrollItemID) { _, itemID in
                    scrollToPendingItem(itemID, with: scrollProxy)
                }
            }
        }
        .navigationTitle(model.title)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search")
        .toolbar {
            DetailToolbar()
        }
    }

    @ViewBuilder
    private func todoRow(_ item: TodoItem, storedItems: [TodoItem]) -> some View {
        let itemIsPendingDraft = isPendingDraft(item)

        let row = TodoRow(
            item: item,
            isPendingDraft: itemIsPendingDraft,
            focusedField: $focusedField,
            updateActiveTitleEdit: updateActiveTitleEdit,
            clearActiveTitleEdit: clearActiveTitleEdit,
            saveTitleChange: saveTitle,
            moveItemToCollection: moveToCollection,
            insertDraftBelow: insertDraftBelow,
            titleFocusSelectionBehavior: pendingTitleFocusSelection[item.id],
            consumeTitleFocusSelectionBehavior: { pendingTitleFocusSelection[item.id] = nil },
            hasVisibleItemAfter: hasVisibleItemAfter,
            moveFocus: moveFocus,
            deleteAndFocusPrevious: deleteAndFocusPrevious,
            deleteEmptyAndMoveFocusDown: deleteEmptyAndMoveFocusDown
        )
        .id(TodoRowRenderIdentity(itemID: item.id, isPendingDraft: itemIsPendingDraft))
        .id(item.id)
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
                    return TodoItemDrag.itemProvider(id: item.id)
                } preview: {
                    Color.clear.frame(width: 1, height: 1)
                }
                .onDrop(
                    of: TodoItemDrag.acceptedTypes,
                    delegate: TodoRowDropDelegate(
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

    private func beginDragging(_ item: TodoItem) {
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
        _ field: TodoFocusField,
        selectionBehavior: TodoFocusSelectionBehavior = .moveInsertionPointToEnd
    ) {
        focusedField = field
        if case .title(let itemID) = field {
            pendingTitleFocusSelection[itemID] = selectionBehavior
        }
        DispatchQueue.main.async {
            selectionBehavior.applyToCurrentTextField()
        }
    }

    private func materializeDraft(after previousItemID: String? = nil) {
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

        let itemID = model.makeTodoID()
        pendingDraftFocusID = itemID
        pendingScrollItemID = itemID
        draftPreviousItemID = previousItemID
        draftItem = TodoItem(
            id: itemID,
            title: "",
            collection: collectionForNewDraft(after: previousItemID)
        )
    }

    private func collectionForNewDraft(after previousItemID: String?) -> String {
        if let selectedCollectionName = model.selectedCollectionName {
            return selectedCollectionName
        }

        if let previousItemID,
           let previousItem = model.items.first(where: { $0.id == previousItemID }) {
            return previousItem.collection
        }

        return model.visibleItems.last?.collection ?? TodoStore.defaultCollection
    }

    private func createTodoFromDroppedFile(_ fileURL: URL) {
        guard let item = model.createTodo(
            title: fileURL.lastPathComponent,
            collection: collectionForNewDraft(after: nil)
        ) else {
            return
        }

        pendingScrollItemID = item.id
        focusTextField(.title(item.id))
    }

    private func focusLatestTodoField() {
        if let pendingDraftItem {
            persistFocusedDraftKeepingFocus(pendingDraftItem)
            focusTextField(.title(pendingDraftItem.id))
        } else {
            materializeDraft()
        }
    }

    private func persistFocusedDraftKeepingFocus(_ draftItem: TodoItem) {
        guard focusedField == .title(draftItem.id) else {
            return
        }

        let title = currentDraftTitle(draftItem)
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        saveDraft(draftItem, title: title, newFocus: .title(draftItem.id))
    }

    private func defocusTodoField() {
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

    private func settlePendingDraftBeforeDragging(_ draggedItem: TodoItem) {
        guard let pendingDraftItem else {
            return
        }

        let draftIsFocused = focusedField == .title(pendingDraftItem.id)
        guard draftIsFocused || draftPreviousItemID == draggedItem.id else {
            return
        }

        let title = draftIsFocused ? currentDraftTitle(pendingDraftItem) : editedTitle(for: pendingDraftItem)
        saveDraft(pendingDraftItem, title: title, newFocus: nil)

        if draftIsFocused {
            focusedField = nil
        }
    }

    private func currentDraftTitle(_ item: TodoItem) -> String {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.string
            ?? editedTitle(for: item)
    }

    private func editedTitle(for item: TodoItem) -> String {
        activeTitleEdit?.id == item.id ? activeTitleEdit?.title ?? item.title : item.title
    }

    private func updateActiveTitleEdit(id: String, title: String) {
        activeTitleEdit = ActiveTodoTitleEdit(id: id, title: title)
    }

    private func clearActiveTitleEdit(id: String) {
        if activeTitleEdit?.id == id {
            activeTitleEdit = nil
        }
    }

    private var pendingDraftItem: TodoItem? {
        guard let draftItem, !hasStoredItem(id: draftItem.id) else {
            return nil
        }

        return draftItem
    }

    private func isPendingDraft(_ item: TodoItem) -> Bool {
        pendingDraftItem?.id == item.id
    }

    private func hasStoredItem(id: String) -> Bool {
        model.items.contains { $0.id == id }
    }

    private func saveTitle(_ item: TodoItem, _ title: String, _ newFocus: TodoFocusField?) {
        if isPendingDraft(item) {
            saveDraft(item, title: title, newFocus: newFocus)
        } else {
            let statusAfterEdit = title == item.title ? nil : model.autoDraftEditStatus
            model.renameOrDeleteIfEmpty(item, title: title, statusAfterEdit: statusAfterEdit)
        }
    }

    private func saveDraft(
        _ item: TodoItem,
        title: String,
        newFocus: TodoFocusField?,
        status: TodoStatus = .draft
    ) {
        guard isPendingDraft(item) else {
            return
        }

        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if newFocus != .collection(item.id) {
                discardDraft(item.id)
            }

            return
        }

        let collection = draftItem?.collection ?? item.collection
        let previousItemID = draftPreviousItemID
        let focusSelectionBehavior = titleFocusSelectionBehavior(for: item, fallback: .moveInsertionPointToEnd)
        discardDraft(item.id)

        if model.createTodo(title: title, collection: collection, id: item.id, status: status) != nil {
            if let previousItemID {
                model.reorderItem(id: item.id, after: previousItemID, before: nil)
            }

            if newFocus == .title(item.id) {
                focusTextField(.title(item.id), selectionBehavior: focusSelectionBehavior)
            }
        } else {
            draftItem = TodoItem(
                id: item.id,
                title: title,
                collection: collection,
                status: item.status,
                createdAt: item.createdAt,
                updatedAt: item.updatedAt
            )
            draftPreviousItemID = previousItemID
        }
    }

    private func titleFocusSelectionBehavior(
        for item: TodoItem,
        fallback: TodoFocusSelectionBehavior
    ) -> TodoFocusSelectionBehavior {
        guard focusedField == .title(item.id),
              let textView = NSApp.keyWindow?.firstResponder as? NSTextView else {
            return fallback
        }

        return .range(textView.selectedRange())
    }

    private func discardDraft(_ id: String) {
        if draftItem?.id == id {
            draftItem = nil
            draftPreviousItemID = nil
        }

        if pendingDraftFocusID == id {
            pendingDraftFocusID = nil
        }

        clearActiveTitleEdit(id: id)
    }

    private func moveToCollection(_ item: TodoItem, _ collection: String) {
        if isPendingDraft(item) {
            draftItem?.collection = collection
        } else {
            model.move(item, collection: collection)
        }
    }

    private func insertDraftBelow(_ item: TodoItem, title: String) {
        if isPendingDraft(item) {
            saveDraft(
                item,
                title: title,
                newFocus: nil,
                status: model.autoDraftConfirmationStatus ?? .draft
            )
        } else {
            model.renameOrDeleteIfEmpty(item, title: title, statusAfterEdit: model.autoDraftConfirmationStatus)
        }

        materializeDraft(after: item.id)
    }

    private func hasVisibleItemAfter(_ item: TodoItem) -> Bool {
        let visibleItems = self.visibleItems
        guard let index = visibleItems.firstIndex(where: { $0.id == item.id }) else {
            return false
        }

        return visibleItems.indices.contains(index + 1)
    }

    @discardableResult
    private func moveFocus(
        from item: TodoItem,
        direction: TodoFocusDirection,
        selectionBehavior: TodoFocusSelectionBehavior = .moveInsertionPointToEnd
    ) -> Bool {
        let visibleItems = self.visibleItems
        guard let index = visibleItems.firstIndex(where: { $0.id == item.id }) else {
            return false
        }

        switch direction {
        case .up:
            guard index > 0 else {
                return false
            }

            clearCurrentTextFieldSelection()
            focusTextField(.title(visibleItems[index - 1].id), selectionBehavior: selectionBehavior)
            return true

        case .down:
            guard visibleItems.indices.contains(index + 1) else {
                return false
            }

            clearCurrentTextFieldSelection()
            focusTextField(.title(visibleItems[index + 1].id), selectionBehavior: selectionBehavior)
            return true
        }
    }

    private func deleteAndFocusPrevious(_ item: TodoItem) {
        let focusTarget = focusTargetAfterDeleting(item)
        let deleted: Bool

        if isPendingDraft(item) {
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
        _ item: TodoItem,
        selectionBehavior: TodoFocusSelectionBehavior = .moveInsertionPointToEnd
    ) -> Bool {
        let visibleItems = self.visibleItems
        guard let index = visibleItems.firstIndex(where: { $0.id == item.id }) else {
            return false
        }

        guard visibleItems.indices.contains(index + 1) else {
            return true
        }

        let focusTarget = TodoFocusField.title(visibleItems[index + 1].id)
        let deleted: Bool
        if isPendingDraft(item) {
            discardDraft(item.id)
            deleted = true
        } else if editedTitle(for: item).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            deleted = model.delete(id: item.id)
        } else {
            deleted = model.delete(item)
        }

        if deleted {
            clearActiveTitleEdit(id: item.id)
            focusTextField(focusTarget, selectionBehavior: selectionBehavior)
        }

        return true
    }

    private func focusTargetAfterDeleting(
        _ item: TodoItem
    ) -> (field: TodoFocusField, selectionBehavior: TodoFocusSelectionBehavior)? {
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
}

private struct TodoRowRenderIdentity: Hashable {
    var itemID: String
    var isPendingDraft: Bool
}

private extension Array where Element == TodoItem {
    func insertingDraft(_ draftItem: TodoItem, after previousItemID: String?) -> [TodoItem] {
        guard let previousItemID,
              let previousIndex = firstIndex(where: { $0.id == previousItemID }) else {
            return self + [draftItem]
        }

        var items = self
        items.insert(draftItem, at: previousIndex + 1)
        return items
    }
}

private struct DetailToolbar: ToolbarContent {
    @EnvironmentObject private var model: TodoAppModel

    var body: some ToolbarContent {
        ToolbarItem {
            Menu {
                if let collection = model.selectedCollectionSummary {
                    CollectionActionMenuItems(
                        collection: collection,
                        showsCLICommand: true,
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
            .menuIndicator(.hidden)
            .help("Todo options")
        }
    }
}

private struct TodoRowDropDelegate: DropDelegate {
    let item: TodoItem
    let visibleItems: [TodoItem]
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

private struct TodoListDropDelegate: DropDelegate {
    let finishDragging: () -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        finishDragging()
        return true
    }
}

private enum TodoItemDrag {
    static let type = UTType(exportedAs: "dev.kymok.pond.todo-item")
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

private struct DraftTodoRow: View {
    let materializeDraft: () -> Void
    let createTodoFromDroppedFile: (URL) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "circle")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.tertiary)
                .frame(width: 24, height: 24)
                .alignmentGuide(.top) { dimensions in
                    dimensions[VerticalAlignment.center] - TodoRowLayout.titleFirstLineCenterY
                }

            Color.clear
                .frame(width: 24, height: 24)
                .alignmentGuide(.top) { dimensions in
                    dimensions[VerticalAlignment.center] - TodoRowLayout.titleFirstLineCenterY
                }

            Text("Title")
                .frame(height: TodoRowLayout.titleLineHeight, alignment: .center)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, TodoRowLayout.rowVerticalPadding)
        .padding(.horizontal, 12)
        .frame(minHeight: TodoRowLayout.rowMinHeight)
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
                createTodoFromDroppedFile(fileURL)
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
