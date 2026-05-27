import AppKit
import SwiftUI
import TodoCore
import UniformTypeIdentifiers

struct DetailView: View {
    @EnvironmentObject private var model: TodoAppModel
    @State private var focusedField: TodoFocusField?
    @State private var pendingDraftFocusID: String?
    @State private var activeTitleEdit: ActiveTodoTitleEdit?
    @State private var draftItem: TodoItem?
    @State private var draftPreviousItemID: String?
    @State private var pendingScrollItemID: String?
    @State private var draggedItemID: String?

    private var visibleItems: [TodoItem] {
        let baseItems = model.visibleItems
        let pinnedIDs = Set([focusedField?.itemID, pendingDraftFocusID].compactMap { $0 })
        let items: [TodoItem]

        if pinnedIDs.isEmpty {
            items = baseItems
        } else {
            let baseIDs = Set(baseItems.map(\.id))
            items = model.items.filter { item in
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

        if let draftItem {
            return items.insertingDraft(draftItem, after: draftPreviousItemID)
        }

        return items
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        let items = visibleItems
                        ForEach(items) { item in
                            todoRow(item)
                        }

                        if draftItem == nil {
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
                        of: [UTType.text],
                        delegate: TodoListDropDelegate(draggedItemID: $draggedItemID)
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

    private func todoRow(_ item: TodoItem) -> some View {
        let itemIsDraft = isDraft(item)

        return TodoRow(
            item: item,
            isDraft: itemIsDraft,
            isDragPlaceholder: !itemIsDraft && draggedItemID == item.id,
            focusedField: $focusedField,
            updateActiveTitleEdit: updateActiveTitleEdit,
            clearActiveTitleEdit: clearActiveTitleEdit,
            saveTitleChange: saveTitle,
            moveItemToCollection: moveToCollection,
            insertDraftBelow: insertDraftBelow,
            moveFocus: moveFocus,
            deleteAndFocusPrevious: deleteAndFocusPrevious,
            deleteEmptyAndMoveFocusDown: deleteEmptyAndMoveFocusDown
        )
        .id(item.id)
        .onDrag {
            DispatchQueue.main.async {
                draggedItemID = item.id
            }
            return NSItemProvider(object: item.id as NSString)
        }
        .onDrop(
            of: [UTType.text],
            delegate: TodoRowDropDelegate(
                item: item,
                visibleItems: visibleItems,
                draggedItemID: $draggedItemID,
                moveItem: reorderItem
            )
        )
        .onAppear {
            if pendingDraftFocusID == item.id {
                focusDraftItem(id: item.id)
            }
        }
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
        DispatchQueue.main.async {
            selectionBehavior.applyToCurrentTextField()
        }
    }

    private func materializeDraft(after previousItemID: String? = nil) {
        guard draftItem == nil else {
            focusTextField(.title(draftItem!.id))
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
        if let draftItem {
            persistFocusedDraftKeepingFocus(draftItem)
            focusTextField(.title(draftItem.id))
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
        guard let draftItem,
              focusedField == .title(draftItem.id) else {
            return
        }

        saveDraft(draftItem, title: currentDraftTitle(draftItem), newFocus: nil)
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

    private func isDraft(_ item: TodoItem) -> Bool {
        draftItem?.id == item.id
    }

    private func saveTitle(_ item: TodoItem, _ title: String, _ newFocus: TodoFocusField?) {
        if isDraft(item) {
            saveDraft(item, title: title, newFocus: newFocus)
        } else {
            model.renameOrDeleteIfEmpty(item, title: title)
        }
    }

    private func saveDraft(_ item: TodoItem, title: String, newFocus: TodoFocusField?) {
        guard draftItem?.id == item.id else {
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
        if model.createTodo(title: title, collection: collection, id: item.id) != nil {
            discardDraft(item.id)
            if let previousItemID {
                model.reorderItem(id: item.id, after: previousItemID, before: nil)
            }
        }
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
        if isDraft(item) {
            draftItem?.collection = collection
        } else {
            model.move(item, collection: collection)
        }
    }

    private func insertDraftBelow(_ item: TodoItem, title: String) {
        if isDraft(item) {
            saveDraft(item, title: title, newFocus: nil)
        }

        materializeDraft(after: item.id)
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
                if isDraft(item) {
                    saveDraft(item, title: currentDraftTitle(item), newFocus: nil)
                }

                clearCurrentTextFieldSelection()
                materializeDraft(after: item.id)
                return true
            }

            clearCurrentTextFieldSelection()
            focusTextField(.title(visibleItems[index + 1].id), selectionBehavior: selectionBehavior)
            return true
        }
    }

    private func deleteAndFocusPrevious(_ item: TodoItem) {
        let focusTarget = focusTargetAfterDeleting(item)
        let deleted: Bool

        if isDraft(item) {
            discardDraft(item.id)
            deleted = true
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
        if model.delete(item) {
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
        guard draftItem?.id != id else {
            return
        }

        let draftID = draftItem?.id
        let previousID = previousID == draftID ? nil : previousID
        let nextID = nextID == draftID ? nil : nextID
        model.reorderItem(id: id, after: previousID, before: nextID)
    }
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
                Toggle("Show undone only", isOn: Binding(
                    get: { model.showsUndoneOnly },
                    set: { model.showsUndoneOnly = $0 }
                ))

                if let collection = model.selectedCollectionSummary {
                    Divider()

                    Button("Clear all", role: .destructive) {
                        model.clearUnlockedItems(in: collection)
                    }
                    .disabled(!model.canClearUnlockedItems(in: collection))

                    Button("Clear done", role: .destructive) {
                        model.clearUnlockedItems(in: collection, doneOnly: true)
                    }
                    .disabled(!model.canClearDoneUnlockedItems(in: collection))

                    Button("Delete Collection", role: .destructive) {
                        model.requestDeleteCollection(collection)
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .help("Todo options")
        }
    }
}

private struct TodoRowDropDelegate: DropDelegate {
    let item: TodoItem
    let visibleItems: [TodoItem]
    @Binding var draggedItemID: String?
    let moveItem: (String, String?, String?) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedItemID,
              draggedItemID != item.id,
              let fromIndex = visibleItems.firstIndex(where: { $0.id == draggedItemID }),
              let toIndex = visibleItems.firstIndex(where: { $0.id == item.id }) else {
            return
        }

        var reorderedItems = visibleItems
        let draggedItem = reorderedItems.remove(at: fromIndex)
        guard let targetIndex = reorderedItems.firstIndex(where: { $0.id == item.id }) else {
            return
        }

        let insertionIndex = fromIndex < toIndex ? targetIndex + 1 : targetIndex
        reorderedItems.insert(draggedItem, at: insertionIndex)

        guard let newIndex = reorderedItems.firstIndex(where: { $0.id == draggedItemID }) else {
            return
        }

        let previousID = newIndex > 0 ? reorderedItems[newIndex - 1].id : nil
        let nextID = reorderedItems.indices.contains(newIndex + 1) ? reorderedItems[newIndex + 1].id : nil
        moveItem(draggedItemID, previousID, nextID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedItemID = nil
        return true
    }
}

private struct TodoListDropDelegate: DropDelegate {
    @Binding var draggedItemID: String?

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        draggedItemID = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedItemID = nil
        return true
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
