import AppKit
import SwiftUI
import TodoCore
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: TodoAppModel
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("alwaysOnTop") private var alwaysOnTop = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(SidebarLayout.width)
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

private enum TodoFocusField: Hashable {
    case title(String)
    case collection(String)
}

private extension TodoFocusField {
    var itemID: String? {
        switch self {
        case .title(let id), .collection(let id):
            id
        }
    }
}

private enum TodoFocusDirection {
    case up
    case down
}

private enum TodoFocusSelectionBehavior {
    case moveInsertionPointToEnd
    case selectAll

    @MainActor
    func applyToCurrentTextField() {
        switch self {
        case .moveInsertionPointToEnd:
            moveCurrentTextFieldInsertionPointToEnd()
        case .selectAll:
            selectCurrentTextFieldText()
        }
    }
}

private enum KeyCode {
    static let backspace: UInt16 = 51
    static let returnKey: UInt16 = 36
    static let keypadEnter: UInt16 = 76
    static let arrowDown: UInt16 = 125
    static let arrowUp: UInt16 = 126
}

private enum SidebarLayout {
    static let width: CGFloat = 160
}

private enum TodoRowLayout {
    static let collectionControlWidth: CGFloat = 80
    static let collectionControlHorizontalPadding: CGFloat = 8
    static let collectionControlContentWidth = collectionControlWidth - (collectionControlHorizontalPadding * 2)
    static let titleLineSpacing = NSFont.systemFontSize * 0.75
    static let rowVerticalPadding: CGFloat = 10
    static let rowMinHeight: CGFloat = 44

    static var titleFont: NSFont {
        NSFont.systemFont(ofSize: NSFont.systemFontSize)
    }

    static var titleLineHeight: CGFloat {
        NSLayoutManager().defaultLineHeight(for: titleFont)
    }

    static var titleFirstLineCenterY: CGFloat {
        titleLineHeight / 2
    }
}

private struct ActiveTodoTitleEdit {
    var id: String
    var title: String

    var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private extension NSEvent {
    var isPlainKey: Bool {
        let modifiers: ModifierFlags = [.command, .option, .control, .shift]
        return modifierFlags.intersection(modifiers).isEmpty
    }

    var isModifiedBackspace: Bool {
        let modifiers: ModifierFlags = [.command, .option, .control]
        return !modifierFlags.intersection(modifiers).isEmpty
    }
}

private struct SidebarView: View {
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

private struct DetailView: View {
    @EnvironmentObject private var model: TodoAppModel
    @State private var focusedField: TodoFocusField?
    @State private var pendingDraftFocusID: String?
    @State private var activeTitleEdit: ActiveTodoTitleEdit?
    @State private var draftItem: TodoItem?
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
            return items + [draftItem]
        }

        return items
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visibleItems) { item in
                        todoRow(item)
                    }

                    if draftItem == nil {
                        DraftTodoRow(
                            materializeDraft: materializeDraft
                        )
                            .id("draft")
                    }
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .top)
                .background {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(perform: defocusTodoField)
                }
            }
            .background {
                Color(nsColor: .textBackgroundColor)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: defocusTodoField)
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

    private func focusTextField(
        _ field: TodoFocusField,
        selectionBehavior: TodoFocusSelectionBehavior = .moveInsertionPointToEnd
    ) {
        focusedField = field
        DispatchQueue.main.async {
            selectionBehavior.applyToCurrentTextField()
        }
    }

    private func materializeDraft() {
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
        draftItem = TodoItem(
            id: itemID,
            title: "",
            collection: model.selectedCollectionName ?? TodoStore.defaultCollection
        )
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
        if model.createTodo(title: title, collection: collection, id: item.id) != nil {
            discardDraft(item.id)
        }
    }

    private func discardDraft(_ id: String) {
        if draftItem?.id == id {
            draftItem = nil
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

            focusTextField(.title(visibleItems[index - 1].id), selectionBehavior: selectionBehavior)
            return true

        case .down:
            guard visibleItems.indices.contains(index + 1) else {
                if isDraft(item) {
                    saveDraft(item, title: currentDraftTitle(item), newFocus: nil)
                }

                materializeDraft()
                return true
            }

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

private struct DetailToolbar: ToolbarContent {
    @EnvironmentObject private var model: TodoAppModel

    var body: some ToolbarContent {
        ToolbarItem {
            Button {
                model.showsUndoneOnly.toggle()
            } label: {
                Image(systemName: model.showsUndoneOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .help(model.showsUndoneOnly ? "Show all todos" : "Show undone todos only")
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

private struct TodoRow: View {
    @EnvironmentObject private var model: TodoAppModel

    let item: TodoItem
    let isDraft: Bool
    let isDragPlaceholder: Bool
    let focusedField: Binding<TodoFocusField?>
    let updateActiveTitleEdit: (String, String) -> Void
    let clearActiveTitleEdit: (String) -> Void
    let saveTitleChange: (TodoItem, String, TodoFocusField?) -> Void
    let moveItemToCollection: (TodoItem, String) -> Void
    let moveFocus: (TodoItem, TodoFocusDirection, TodoFocusSelectionBehavior) -> Bool
    let deleteAndFocusPrevious: (TodoItem) -> Void
    let deleteEmptyAndMoveFocusDown: (TodoItem, TodoFocusSelectionBehavior) -> Bool

    @State private var title: String
    @State private var isCreatingCollection = false
    @State private var newCollection = ""
    @FocusState private var isCollectionFocused: Bool

    init(
        item: TodoItem,
        isDraft: Bool,
        isDragPlaceholder: Bool,
        focusedField: Binding<TodoFocusField?>,
        updateActiveTitleEdit: @escaping (String, String) -> Void,
        clearActiveTitleEdit: @escaping (String) -> Void,
        saveTitleChange: @escaping (TodoItem, String, TodoFocusField?) -> Void,
        moveItemToCollection: @escaping (TodoItem, String) -> Void,
        moveFocus: @escaping (TodoItem, TodoFocusDirection, TodoFocusSelectionBehavior) -> Bool,
        deleteAndFocusPrevious: @escaping (TodoItem) -> Void,
        deleteEmptyAndMoveFocusDown: @escaping (TodoItem, TodoFocusSelectionBehavior) -> Bool
    ) {
        self.item = item
        self.isDraft = isDraft
        self.isDragPlaceholder = isDragPlaceholder
        self.focusedField = focusedField
        self.updateActiveTitleEdit = updateActiveTitleEdit
        self.clearActiveTitleEdit = clearActiveTitleEdit
        self.saveTitleChange = saveTitleChange
        self.moveItemToCollection = moveItemToCollection
        self.moveFocus = moveFocus
        self.deleteAndFocusPrevious = deleteAndFocusPrevious
        self.deleteEmptyAndMoveFocusDown = deleteEmptyAndMoveFocusDown
        _title = State(initialValue: item.title)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                model.setDone(item, isDone: !item.isDone)
            } label: {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(item.isDone ? .green : .secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(item.isDone ? "Mark undone" : "Mark done")
            .disabled(isDraft)
            .alignmentGuide(.top) { dimensions in
                dimensions[VerticalAlignment.center] - TodoRowLayout.titleFirstLineCenterY
            }

            Button {
                model.setLocked(item, isLocked: !item.isLocked)
            } label: {
                Image(systemName: item.isLocked ? "lock.fill" : "lock.open")
                    .font(.system(size: 16, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(item.isLocked ? .orange : .secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(item.isLocked ? "Unlock" : "Lock")
            .disabled(isDraft)
            .alignmentGuide(.top) { dimensions in
                dimensions[VerticalAlignment.center] - TodoRowLayout.titleFirstLineCenterY
            }

            ZStack(alignment: .topLeading) {
                if title.isEmpty {
                    Text("Title")
                        .frame(height: TodoRowLayout.titleLineHeight, alignment: .center)
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }

                TodoTitleTextView(
                    text: $title,
                    isFocused: focusedField.wrappedValue == .title(item.id),
                    isDone: item.isDone,
                    isLocked: item.isLocked,
                    focus: {
                        focusedField.wrappedValue = .title(item.id)
                    },
                    clearFocusIfCurrent: {
                        if focusedField.wrappedValue == .title(item.id) {
                            focusedField.wrappedValue = nil
                        }
                    }
                )
                .id(model.selectedCollectionName == nil)
            }
            .frame(minHeight: TodoRowLayout.titleLineHeight, alignment: .topLeading)
            .onChange(of: focusedField.wrappedValue) { oldFocus, newFocus in
                if newFocus == .title(item.id) {
                    updateActiveTitleEdit(item.id, title)
                }

                if oldFocus == .title(item.id), newFocus != .title(item.id) {
                    saveTitle(afterMovingFocusTo: newFocus)
                    clearActiveTitleEdit(item.id)
                }
            }
            .onChange(of: item.title) { _, newValue in
                title = newValue
                if focusedField.wrappedValue == .title(item.id) {
                    updateActiveTitleEdit(item.id, newValue)
                }
            }
            .onChange(of: title) { _, newValue in
                if focusedField.wrappedValue == .title(item.id) {
                    updateActiveTitleEdit(item.id, newValue)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if model.selectedCollectionName == nil {
                collectionControl
            }
        }
        .opacity(isDragPlaceholder ? 0 : 1)
        .padding(.vertical, TodoRowLayout.rowVerticalPadding)
        .padding(.horizontal, 12)
        .frame(minHeight: TodoRowLayout.rowMinHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .todoRowHitArea(focusTitle)
        .background(
            FocusedTextFieldKeyHandler(isActive: isFocused) { event, fieldEditor in
                handleKeyDown(event, fieldEditor: fieldEditor)
            }
        )
        .contextMenu {
            Button(item.isDone ? "Mark Undone" : "Mark Done") {
                model.setDone(item, isDone: !item.isDone)
            }
            .disabled(isDraft)

            Button("Delete", role: .destructive) {
                deleteAndFocusPrevious(item)
            }
            .disabled(item.isLocked)
        }
    }

    private var isFocused: Bool {
        focusedField.wrappedValue == .title(item.id)
            || focusedField.wrappedValue == .collection(item.id)
    }

    private func focusTitle() {
        guard !item.isLocked else {
            return
        }

        updateActiveTitleEdit(item.id, title)
        focusedField.wrappedValue = .title(item.id)
        DispatchQueue.main.async {
            moveCurrentTextFieldInsertionPointToEnd()
        }
    }

    private func handleKeyDown(_ event: NSEvent, fieldEditor: NSTextView) -> Bool {
        guard !fieldEditor.hasMarkedText() else {
            return false
        }

        switch event.keyCode {
        case KeyCode.backspace:
            return deleteIfEmptyTitleAtStart(event, fieldEditor: fieldEditor)
        case KeyCode.returnKey, KeyCode.keypadEnter:
            return moveFocusDownFromTitle(event)
        case KeyCode.arrowUp:
            guard event.isPlainKey else {
                return false
            }

            if focusedField.wrappedValue == .title(item.id), !isInsertionPointOnFirstVisualLine(fieldEditor) {
                return false
            }

            return moveFocus(item, .up, .selectAll)
        case KeyCode.arrowDown:
            guard event.isPlainKey else {
                return false
            }

            if focusedField.wrappedValue == .title(item.id) {
                guard isInsertionPointOnLastVisualLine(fieldEditor) else {
                    return false
                }

                return moveFocusDownFromTitle(event, selectionBehavior: .selectAll)
            }

            return moveFocus(item, .down, .selectAll)
        default:
            return false
        }
    }

    private func isInsertionPointOnFirstVisualLine(_ fieldEditor: NSTextView) -> Bool {
        let length = (fieldEditor.string as NSString).length
        guard length > 0 else {
            return true
        }

        if fieldEditor.selectedRange().location == 0 {
            return true
        }

        guard let currentLine = visualLineRange(containingSelectionIn: fieldEditor),
              let firstLine = visualLineRange(containingCharacterAt: 0, in: fieldEditor) else {
            return true
        }

        return currentLine.location == firstLine.location
    }

    private func isInsertionPointOnLastVisualLine(_ fieldEditor: NSTextView) -> Bool {
        let length = (fieldEditor.string as NSString).length
        guard length > 0 else {
            return true
        }

        if fieldEditor.selectedRange().location >= length {
            return true
        }

        guard let currentLine = visualLineRange(containingSelectionIn: fieldEditor),
              let lastLine = visualLineRange(containingCharacterAt: length - 1, in: fieldEditor) else {
            return true
        }

        return currentLine.location == lastLine.location
            && currentLine.length == lastLine.length
    }

    private func visualLineRange(containingSelectionIn fieldEditor: NSTextView) -> NSRange? {
        let length = (fieldEditor.string as NSString).length
        guard length > 0 else {
            return NSRange(location: 0, length: 0)
        }

        let characterIndex = min(fieldEditor.selectedRange().location, length - 1)
        return visualLineRange(containingCharacterAt: characterIndex, in: fieldEditor)
    }

    private func visualLineRange(containingCharacterAt characterIndex: Int, in fieldEditor: NSTextView) -> NSRange? {
        guard let layoutManager = fieldEditor.layoutManager,
              let textContainer = fieldEditor.textContainer else {
            return nil
        }

        layoutManager.ensureLayout(for: textContainer)
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
        var lineRange = NSRange()
        layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineRange)
        return lineRange
    }

    private func deleteIfEmptyTitleAtStart(_ event: NSEvent, fieldEditor: NSTextView) -> Bool {
        guard focusedField.wrappedValue == .title(item.id), !event.isModifiedBackspace else {
            return false
        }

        let selectedRange = fieldEditor.selectedRange()
        guard fieldEditor.string.isEmpty && selectedRange.location == 0 && selectedRange.length == 0 else {
            return false
        }

        deleteAndFocusPrevious(item)
        return true
    }

    private func moveFocusDownFromTitle(
        _ event: NSEvent,
        selectionBehavior: TodoFocusSelectionBehavior = .moveInsertionPointToEnd
    ) -> Bool {
        guard focusedField.wrappedValue == .title(item.id), event.isPlainKey else {
            return false
        }

        if isEmptyTitle {
            return deleteEmptyAndMoveFocusDown(item, selectionBehavior)
        }

        return moveFocus(item, .down, selectionBehavior)
    }

    private func saveTitle() {
        saveTitleChange(item, title, nil)
    }

    private func saveTitle(afterMovingFocusTo newFocus: TodoFocusField?) {
        guard !(isEmptyTitle && newFocus == .collection(item.id)) else {
            return
        }

        saveTitleChange(item, title, newFocus)
    }

    private var isEmptyTitle: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var collectionControl: some View {
        if isCreatingCollection {
            TextField("Collection", text: $newCollection)
                .textFieldStyle(.plain)
                .focused($isCollectionFocused)
                .collectionChipStyle()
                .onSubmit(saveNewCollectionAndFocusTitle)
                .onChange(of: isCollectionFocused) { oldFocus, newFocus in
                    if newFocus {
                        focusedField.wrappedValue = .collection(item.id)
                    }

                    if oldFocus, !newFocus {
                        let nextFocus = focusedField.wrappedValue
                        if nextFocus == .collection(item.id) {
                            focusedField.wrappedValue = nil
                        }

                        saveNewCollection()
                        if nextFocus != .title(item.id) {
                            saveTitle()
                        }
                    }
                }
                .onChange(of: focusedField.wrappedValue) { oldFocus, newFocus in
                    if newFocus == .collection(item.id), !isCollectionFocused {
                        isCollectionFocused = true
                    }

                    if oldFocus == .collection(item.id),
                       newFocus != .collection(item.id),
                       isCollectionFocused {
                        isCollectionFocused = false
                    }
                }
                .onAppear {
                    focusNewCollectionField()
                }
        } else {
            Menu {
                ForEach(model.collectionNames, id: \.self) { collection in
                    Button(collection) {
                        moveToCollection(collection)
                        if isEmptyTitle {
                            focusTitle()
                        }
                    }
                }

                Divider()
                Button("Create new...") {
                    beginCreatingCollection()
                }
            } label: {
                HStack(spacing: 4) {
                    Text(item.collection)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .imageScale(.small)
                }
                .collectionChipStyle()
            }
            .buttonStyle(.plain)
            .frame(width: TodoRowLayout.collectionControlWidth)
            .disabled(item.isLocked)
        }
    }

    private func beginCreatingCollection() {
        isCreatingCollection = true
        newCollection = ""
    }

    private func moveToCollection(_ name: String) {
        guard name != item.collection else {
            return
        }

        moveItemToCollection(item, name)
    }

    private func focusNewCollectionField() {
        focusedField.wrappedValue = .collection(item.id)
        DispatchQueue.main.async {
            isCollectionFocused = true
            moveCurrentTextFieldInsertionPointToEnd()
        }
    }

    private func saveNewCollection() {
        guard isCreatingCollection else {
            return
        }

        let cleanCollection = newCollection.trimmingCharacters(in: .whitespacesAndNewlines)
        isCreatingCollection = false
        newCollection = ""

        guard !cleanCollection.isEmpty else {
            return
        }

        moveToCollection(cleanCollection)
    }

    private func saveNewCollectionAndFocusTitle() {
        saveNewCollection()
        focusTitle()
    }
}

private struct TodoTitleTextView: NSViewRepresentable {
    @Binding var text: String

    let isFocused: Bool
    let isDone: Bool
    let isLocked: Bool
    let focus: () -> Void
    let clearFocusIfCurrent: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> SelfSizingTextView {
        let textView = SelfSizingTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.lineBreakMode = .byWordWrapping
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: TodoRowLayout.titleLineHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        return textView
    }

    func updateNSView(_ textView: SelfSizingTextView, context: Context) {
        context.coordinator.parent = self

        if textView.string != text {
            let selectedRange = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(selectedRange.clamped(to: textView.string))
        }

        applyStyle(to: textView)
        textView.isEditable = !isLocked
        textView.isSelectable = !isLocked
        textView.updateTextContainerWidth()
        textView.invalidateIntrinsicContentSize()

        if isFocused, !isLocked {
            focus(textView)
        } else if textView.window?.firstResponder === textView {
            textView.window?.makeFirstResponder(nil)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SelfSizingTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.enclosingScrollView?.contentSize.width ?? nsView.bounds.width
        guard width > 0 else {
            return CGSize(width: proposal.width ?? 0, height: TodoRowLayout.titleLineHeight)
        }

        return CGSize(width: width, height: nsView.measuredHeight(fitting: width))
    }

    private func focus(_ textView: SelfSizingTextView) {
        if let window = textView.window {
            if window.firstResponder !== textView {
                window.makeFirstResponder(textView)
            }
        } else {
            DispatchQueue.main.async {
                if self.isFocused, !self.isLocked {
                    textView.window?.makeFirstResponder(textView)
                }
            }
        }
    }

    private func applyStyle(to textView: NSTextView) {
        let selectedRange = textView.selectedRange()
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = TodoRowLayout.titleLineSpacing
        paragraphStyle.lineBreakMode = .byWordWrapping

        let textColor = isDone ? NSColor.secondaryLabelColor : NSColor.labelColor
        textView.font = TodoRowLayout.titleFont
        textView.textColor = textColor
        textView.defaultParagraphStyle = paragraphStyle
        textView.typingAttributes = [
            .font: TodoRowLayout.titleFont,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle
        ]

        let range = NSRange(location: 0, length: (textView.string as NSString).length)
        if range.length > 0 {
            textView.textStorage?.setAttributes(textView.typingAttributes, range: range)
        }

        textView.setSelectedRange(selectedRange.clamped(to: textView.string))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TodoTitleTextView

        init(_ parent: TodoTitleTextView) {
            self.parent = parent
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.focus()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? SelfSizingTextView else {
                return
            }

            parent.text = textView.string
            textView.invalidateIntrinsicContentSize()
        }

        func textDidEndEditing(_ notification: Notification) {
            guard let textView = notification.object as? SelfSizingTextView else {
                return
            }

            DispatchQueue.main.async {
                let window = textView.window
                let firstResponder = window?.firstResponder
                guard firstResponder !== textView else {
                    return
                }

                if self.parent.isFocused,
                   !self.parent.isLocked,
                   firstResponder == nil || firstResponder === window {
                    self.parent.focus(textView)
                    return
                }

                self.parent.clearFocusIfCurrent()
            }
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            replacementString?.contains("\n") != true
        }
    }

    final class SelfSizingTextView: NSTextView {
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: measuredHeight(fitting: bounds.width))
        }

        override func setFrameSize(_ newSize: NSSize) {
            let oldWidth = frame.width
            super.setFrameSize(newSize)
            updateTextContainerWidth()

            if abs(oldWidth - newSize.width) > 0.5 {
                invalidateIntrinsicContentSize()
            }
        }

        func measuredHeight(fitting width: CGFloat) -> CGFloat {
            guard width > 0,
                  let layoutManager,
                  let textContainer else {
                return TodoRowLayout.titleLineHeight
            }

            textContainer.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            layoutManager.ensureLayout(for: textContainer)

            let usedHeight = layoutManager.usedRect(for: textContainer).height + textContainerInset.height * 2
            return max(TodoRowLayout.titleLineHeight, ceil(usedHeight))
        }

        func updateTextContainerWidth() {
            guard bounds.width > 0 else {
                return
            }

            textContainer?.containerSize = NSSize(width: bounds.width, height: CGFloat.greatestFiniteMagnitude)
        }
    }
}

private extension NSRange {
    func clamped(to string: String) -> NSRange {
        let length = (string as NSString).length
        let clampedLocation = min(location, length)
        let clampedLength = min(self.length, length - clampedLocation)
        return NSRange(location: clampedLocation, length: clampedLength)
    }
}

private struct FocusedTextFieldKeyHandler: View {
    let isActive: Bool
    let onKeyDown: (NSEvent, NSTextView) -> Bool

    var body: some View {
        LocalKeyDownHandler(isActive: isActive) { event in
            guard let fieldEditor = event.window?.firstResponder as? NSTextView else {
                return false
            }

            return onKeyDown(event, fieldEditor)
        }
    }
}

private struct LocalKeyDownHandler: NSViewRepresentable {
    let isActive: Bool
    let onKeyDown: (NSEvent) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
        context.coordinator.onKeyDown = onKeyDown

        if isActive {
            context.coordinator.installMonitorIfNeeded()
        } else {
            context.coordinator.removeMonitor()
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var onKeyDown: (NSEvent) -> Bool = { _ in false }

        private var monitor: Any?

        func installMonitorIfNeeded() {
            guard monitor == nil else {
                return
            }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.handle(event) else {
                    return event
                }

                return nil
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }

            monitor = nil
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard let window = view?.window,
                  event.window === window || event.window?.sheetParent === window else {
                return false
            }

            return onKeyDown(event)
        }
    }
}

private struct WindowLevelController: NSViewRepresentable {
    let alwaysOnTop: Bool

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.level = alwaysOnTop ? .floating : .normal
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        nsView.window?.level = .normal
    }
}

private struct DraftTodoRow: View {
    let materializeDraft: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "circle")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.tertiary)
                .frame(width: 24, height: 24)
                .alignmentGuide(.top) { dimensions in
                    dimensions[VerticalAlignment.center] - TodoRowLayout.titleFirstLineCenterY
                }

            Image(systemName: "lock.open")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.tertiary)
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
    }
}

private extension View {
    func todoRowHitArea(_ focusTitle: @escaping () -> Void) -> some View {
        background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: focusTitle)
        }
    }

    func collectionChipStyle() -> some View {
        font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: TodoRowLayout.collectionControlContentWidth, alignment: .leading)
            .padding(.horizontal, TodoRowLayout.collectionControlHorizontalPadding)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
            .frame(width: TodoRowLayout.collectionControlWidth)
            .clipped()
    }
}

private func deleteCollectionMessage(for collection: TodoCollectionSummary) -> String {
    let itemLabel = collection.totalCount == 1 ? "todo" : "todos"
    return "This will delete \"\(collection.name)\" and \(collection.totalCount) \(itemLabel)."
}

@MainActor
private func moveCurrentTextFieldInsertionPointToEnd() {
    guard let fieldEditor = NSApp.keyWindow?.firstResponder as? NSTextView else {
        return
    }

    let length = (fieldEditor.string as NSString).length
    fieldEditor.setSelectedRange(NSRange(location: length, length: 0))
}

@MainActor
private func selectCurrentTextFieldText() {
    guard let fieldEditor = NSApp.keyWindow?.firstResponder as? NSTextView else {
        return
    }

    fieldEditor.selectAll(nil)
}
