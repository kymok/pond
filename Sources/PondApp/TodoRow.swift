import AppKit
import SwiftUI
import TodoCore

struct TodoRow: View {
    @EnvironmentObject private var model: TodoAppModel

    let item: TodoItem
    let isPendingDraft: Bool
    let focusedField: Binding<TodoFocusField?>
    let updateActiveTitleEdit: (String, String) -> Void
    let clearActiveTitleEdit: (String) -> Void
    let saveTitleChange: (TodoItem, String, TodoFocusField?) -> Void
    let moveItemToCollection: (TodoItem, String) -> Void
    let insertDraftBelow: (TodoItem, String) -> Void
    let titleFocusSelectionBehavior: TodoFocusSelectionBehavior?
    let consumeTitleFocusSelectionBehavior: () -> Void
    let hasVisibleItemAfter: (TodoItem) -> Bool
    let moveFocus: (TodoItem, TodoFocusDirection, TodoFocusSelectionBehavior) -> Bool
    let deleteAndFocusPrevious: (TodoItem) -> Void
    let deleteEmptyAndMoveFocusDown: (TodoItem, TodoFocusSelectionBehavior) -> Bool

    @State private var autosaveTask: Task<Void, Never>?
    @State private var title: String
    @State private var isComposingTitle = false
    @State private var isCreatingCollection = false
    @State private var newCollection = ""
    @State private var skipsNextFocusLossSave = false
    @FocusState private var isCollectionFocused: Bool

    init(
        item: TodoItem,
        isPendingDraft: Bool,
        focusedField: Binding<TodoFocusField?>,
        updateActiveTitleEdit: @escaping (String, String) -> Void,
        clearActiveTitleEdit: @escaping (String) -> Void,
        saveTitleChange: @escaping (TodoItem, String, TodoFocusField?) -> Void,
        moveItemToCollection: @escaping (TodoItem, String) -> Void,
        insertDraftBelow: @escaping (TodoItem, String) -> Void,
        titleFocusSelectionBehavior: TodoFocusSelectionBehavior?,
        consumeTitleFocusSelectionBehavior: @escaping () -> Void,
        hasVisibleItemAfter: @escaping (TodoItem) -> Bool,
        moveFocus: @escaping (TodoItem, TodoFocusDirection, TodoFocusSelectionBehavior) -> Bool,
        deleteAndFocusPrevious: @escaping (TodoItem) -> Void,
        deleteEmptyAndMoveFocusDown: @escaping (TodoItem, TodoFocusSelectionBehavior) -> Bool
    ) {
        self.item = item
        self.isPendingDraft = isPendingDraft
        self.focusedField = focusedField
        self.updateActiveTitleEdit = updateActiveTitleEdit
        self.clearActiveTitleEdit = clearActiveTitleEdit
        self.saveTitleChange = saveTitleChange
        self.moveItemToCollection = moveItemToCollection
        self.insertDraftBelow = insertDraftBelow
        self.titleFocusSelectionBehavior = titleFocusSelectionBehavior
        self.consumeTitleFocusSelectionBehavior = consumeTitleFocusSelectionBehavior
        self.hasVisibleItemAfter = hasVisibleItemAfter
        self.moveFocus = moveFocus
        self.deleteAndFocusPrevious = deleteAndFocusPrevious
        self.deleteEmptyAndMoveFocusDown = deleteEmptyAndMoveFocusDown
        _title = State(initialValue: item.title)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                model.advanceStatusFromLeadingClick(item)
            } label: {
                statusImage
            }
            .buttonStyle(.plain)
            .help(leadingStatusButtonTitle)
            .disabled(isPendingDraft)
            .background(
                LocalRightClickHandler {
                    markDraftFromStatusButton()
                }
            )
            .alignmentGuide(.top) { dimensions in
                dimensions[VerticalAlignment.center] - TodoRowLayout.titleFirstLineCenterY
            }

            if isPendingDraft {
                Color.clear
                    .frame(width: 24, height: 24)
                    .alignmentGuide(.top) { dimensions in
                        dimensions[VerticalAlignment.center] - TodoRowLayout.titleFirstLineCenterY
                    }
            } else {
                Menu {
                    Section("Status") {
                        ForEach(TodoStatus.allCases, id: \.self) { status in
                            Button {
                                model.setStatus(item, status: status)
                            } label: {
                                TodoStatusLabel(status: status)
                            }
                        }
                    }

                    Section("Priority") {
                        ForEach(TodoPriority.allCases, id: \.self) { priority in
                            Button {
                                model.setPriority(item, priority: priority)
                            } label: {
                                Label {
                                    Text(priority.displayName)
                                } icon: {
                                    if item.priority == priority {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }

                    Divider()

                    Section("Item") {
                        Button(cleanAssignees.isEmpty ? "Set Assignees..." : "Edit Assignees...") {
                            model.requestAssigneeEdit(item)
                        }

                        Button("Copy ID") {
                            copyIDToPasteboard()
                        }

                        Button("Delete", role: .destructive) {
                            deleteAndFocusPrevious(item)
                        }
                    }
                } label: {
                    itemMenuIcon
                }
                .buttonStyle(.plain)
                .help("Todo status")
                .alignmentGuide(.top) { dimensions in
                    dimensions[VerticalAlignment.center] - TodoRowLayout.titleFirstLineCenterY
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                titleEditor

                if item.priority == .prioritized {
                    priorityLabel
                        .transition(.opacity)
                }

                if !cleanAssignees.isEmpty {
                    assigneeLabel(cleanAssignees)
                        .transition(.opacity)
                }
            }
            .frame(minHeight: TodoRowLayout.titleLineHeight, alignment: .topLeading)
            .animation(.easeInOut(duration: 0.22), value: item.priority)
            .animation(.easeInOut(duration: 0.22), value: cleanAssignees)
            .onChange(of: focusedField.wrappedValue) { oldFocus, newFocus in
                if newFocus == .title(item.id) {
                    updateActiveTitleEdit(item.id, title)
                }

                if oldFocus == .title(item.id), newFocus != .title(item.id) {
                    cancelAutosave()
                    if skipsNextFocusLossSave {
                        skipsNextFocusLossSave = false
                    } else {
                        saveTitle(afterMovingFocusTo: newFocus)
                    }
                    clearActiveTitleEdit(item.id)
                }
            }
            .onChange(of: item.title) { _, newValue in
                if focusedField.wrappedValue == .title(item.id) {
                    updateActiveTitleEdit(item.id, title)
                    if newValue != title {
                        scheduleAutosave(title)
                    }
                    return
                }

                title = newValue
            }
            .onChange(of: title) { _, newValue in
                if focusedField.wrappedValue == .title(item.id) {
                    updateActiveTitleEdit(item.id, newValue)
                    scheduleAutosave(newValue)
                }
            }
            .onChange(of: isComposingTitle) { _, isComposing in
                if isComposing {
                    cancelAutosave()
                } else if focusedField.wrappedValue == .title(item.id) {
                    scheduleAutosave(title)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if model.selectedCollectionName == nil {
                collectionControl
            }
        }
        .padding(.vertical, TodoRowLayout.rowVerticalPadding)
        .padding(.horizontal, 12)
        .frame(minHeight: TodoRowLayout.rowMinHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .todoRowHitArea(focusTitle)
        .background(
            FocusedTextFieldKeyHandler(isActive: isCollectionFocusedForKeyHandling) { event, fieldEditor in
                handleCollectionKeyDown(event, fieldEditor: fieldEditor)
            }
        )
        .contextMenu {
            Button("Mark Draft") {
                model.setStatus(item, status: .draft)
            }
            .disabled(isPendingDraft || item.status == .draft)

            Button("Delete", role: .destructive) {
                deleteAndFocusPrevious(item)
            }
        }
        .onChange(of: item.status) { _, _ in
            clearSelectionAfterStatusChange()
            clearLockedFocus()
        }
        .onDisappear(perform: cancelAutosave)
    }

    private var isFocused: Bool {
        canEditTitleAndCollection
            && (
                focusedField.wrappedValue == .title(item.id)
                    || focusedField.wrappedValue == .collection(item.id)
            )
    }

    private var isCollectionFocusedForKeyHandling: Bool {
        canEditTitleAndCollection && focusedField.wrappedValue == .collection(item.id)
    }

    private var canEditTitleAndCollection: Bool {
        item.status != .inProgress && item.status != .completed
    }

    private var leadingStatusButtonTitle: String {
        "Mark \(item.status.leadingStatusClickTarget.displayName)"
    }

    private func markDraftFromStatusButton() {
        guard !isPendingDraft, item.status != .draft else {
            return
        }

        model.setStatus(item, status: .draft)
    }

    @ViewBuilder
    private var statusImage: some View {
        let image = TodoStatusIcon(
            status: item.status,
            font: .system(size: 20, weight: .regular)
        )
            .frame(width: 24, height: 24)

        if #available(macOS 15.0, *) {
            image.contentTransition(.symbolEffect(.replace.magic(fallback: .replace.downUp)))
        } else {
            image
        }
    }

    private var cleanAssignees: [String] {
        item.assignees
    }

    private var titleEditor: some View {
        ZStack(alignment: .topLeading) {
            if title.isEmpty {
                Text("Title")
                    .frame(height: TodoRowLayout.titleLineHeight, alignment: .center)
                    .foregroundStyle(.tertiary)
                    .allowsHitTesting(false)
            }

            TodoTitleTextView(
                text: $title,
                isComposing: $isComposingTitle,
                isFocused: canEditTitleAndCollection && focusedField.wrappedValue == .title(item.id),
                isEditable: canEditTitleAndCollection,
                status: item.status,
                selectionBehavior: titleFocusSelectionBehavior,
                consumeSelectionBehavior: consumeTitleFocusSelectionBehavior,
                focus: {
                    guard canEditTitleAndCollection else {
                        return
                    }

                    focusedField.wrappedValue = .title(item.id)
                },
                clearFocusIfCurrent: {
                    if focusedField.wrappedValue == .title(item.id) {
                        focusedField.wrappedValue = nil
                    }
                },
                onKeyDown: { event, textView in
                    handleTitleKeyDown(event, textView: textView)
                }
            )
            .id(TodoTitleTextViewIdentity(
                itemID: item.id,
                showsCollection: model.selectedCollectionName == nil
            ))
            .allowsHitTesting(canEditTitleAndCollection || item.status != .inProgress)
        }
    }

    private func assigneeLabel(_ assignees: [String]) -> some View {
        Button {
            model.requestAssigneeEdit(item)
        } label: {
            metadataRow {
                metadataIcon(systemName: "person.fill")
            } text: {
                Text(assignees.joined(separator: ", "))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help("Edit assignees")
    }

    private var priorityLabel: some View {
        Menu {
            ForEach(TodoPriority.allCases, id: \.self) { priority in
                Button {
                    model.setPriority(item, priority: priority)
                } label: {
                    Label {
                        Text(priority.displayName)
                    } icon: {
                        if item.priority == priority {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            metadataRow {
                metadataIcon(systemName: "arrow.trianglehead.turn.up.right.diamond.fill")
            } text: {
                Text(TodoPriority.prioritized.displayName)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help("Change priority")
    }

    private func metadataRow<Icon: View, Label: View>(
        @ViewBuilder icon: () -> Icon,
        @ViewBuilder text: () -> Label
    ) -> some View {
        HStack(spacing: 4) {
            icon()
                .frame(width: 16, alignment: .center)

            text()
        }
        .font(.caption)
    }

    private func metadataIcon(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.caption)
            .foregroundStyle(Color.gray)
            .frame(width: 16, alignment: .center)
    }

    private var hasUnsavedTitleText: Bool {
        title != item.title || autosaveTask != nil || isComposingTitle
    }

    @ViewBuilder
    private var itemMenuIcon: some View {
        if hasUnsavedTitleText {
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

    private func copyIDToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.id, forType: .string)
    }

    private func focusTitle() {
        guard canEditTitleAndCollection else {
            return
        }

        updateActiveTitleEdit(item.id, title)
        focusedField.wrappedValue = .title(item.id)
        DispatchQueue.main.async {
            moveCurrentTextFieldInsertionPointToEnd()
        }
    }

    private func clearLockedFocus() {
        guard !canEditTitleAndCollection else {
            return
        }

        if focusedField.wrappedValue == .title(item.id)
            || focusedField.wrappedValue == .collection(item.id) {
            focusedField.wrappedValue = nil
        }

        isCollectionFocused = false
        isCreatingCollection = false
        newCollection = ""
    }

    private func clearSelectionAfterStatusChange() {
        guard focusedField.wrappedValue == .title(item.id) else {
            return
        }

        clearCurrentTextFieldSelection()
    }

    private func handleTitleKeyDown(_ event: NSEvent, textView: NSTextView) -> Bool {
        guard !textView.hasMarkedText() else {
            return false
        }

        switch event.keyCode {
        case KeyCode.escape:
            return defocus(event)
        case KeyCode.backspace:
            syncTitleFocusAndText(from: textView)
            return deleteIfEmptyTitleAtStart(event, fieldEditor: textView)
        case KeyCode.returnKey, KeyCode.keypadEnter:
            return handleTitleReturn(event, textView: textView)
        case KeyCode.arrowUp:
            guard event.isPlainKey else {
                return false
            }

            syncTitleFocusAndText(from: textView)
            guard isInsertionPointOnFirstVisualLine(textView) else {
                return false
            }

            return moveFocus(item, .up, .selectAll)
        case KeyCode.arrowDown:
            guard event.isPlainKey else {
                return false
            }

            syncTitleFocusAndText(from: textView)
            guard isInsertionPointOnLastVisualLine(textView) else {
                return false
            }

            return moveFocusDownFromTitle(event, selectionBehavior: .selectAll)
        default:
            return false
        }
    }

    private func handleCollectionKeyDown(_ event: NSEvent, fieldEditor: NSTextView) -> Bool {
        guard !fieldEditor.hasMarkedText() else {
            return false
        }

        switch event.keyCode {
        case KeyCode.escape:
            return defocus(event)
        case KeyCode.arrowUp:
            guard event.isPlainKey else {
                return false
            }

            return moveFocus(item, .up, .selectAll)
        case KeyCode.arrowDown:
            guard event.isPlainKey else {
                return false
            }

            return moveFocus(item, .down, .selectAll)
        default:
            return false
        }
    }

    private func defocus(_ event: NSEvent) -> Bool {
        guard event.isPlainKey else {
            return false
        }

        focusedField.wrappedValue = nil
        isCollectionFocused = false
        event.window?.makeFirstResponder(nil)
        return true
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

    private func handleTitleReturn(_ event: NSEvent, textView: NSTextView) -> Bool {
        guard event.isPlainKey else {
            return false
        }

        syncTitleFocusAndText(from: textView)
        let currentTitle = textView.string
        if currentTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return deleteEmptyAndMoveFocusDown(item, .moveInsertionPointToEnd)
        }

        if hasVisibleItemAfter(item) {
            _ = moveFocus(item, .down, .moveInsertionPointToEnd)
            return true
        }

        cancelAutosave()
        skipsNextFocusLossSave = true
        insertDraftBelow(item, currentTitle)
        if isPendingDraft {
            resetTitleEditorForNextDraft(textView)
        }
        return true
    }

    private func resetTitleEditorForNextDraft(_ textView: NSTextView) {
        title = ""
        updateActiveTitleEdit(item.id, "")
        textView.string = ""
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.invalidateIntrinsicContentSize()
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
        cancelAutosave()
        saveTitleChange(item, title, nil)
    }

    private func saveTitle(afterMovingFocusTo newFocus: TodoFocusField?) {
        guard !(isEmptyTitle && newFocus == .collection(item.id)) else {
            return
        }

        saveTitleChange(item, title, newFocus)
    }

    private func scheduleAutosave(_ newTitle: String) {
        cancelAutosave()

        guard !isComposingTitle,
              !newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        autosaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled,
                  !isComposingTitle,
                  !currentTitleEditorHasMarkedText(),
                  focusedField.wrappedValue == .title(item.id),
                  title == newTitle else {
                return
            }

            saveTitleChange(item, newTitle, focusedField.wrappedValue)
            autosaveTask = nil
        }
    }

    private func cancelAutosave() {
        autosaveTask?.cancel()
        autosaveTask = nil
    }

    private func currentTitleEditorHasMarkedText() -> Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
    }

    private func syncTitleFocusAndText(from textView: NSTextView) {
        let currentTitle = textView.string
        focusedField.wrappedValue = .title(item.id)

        if title != currentTitle {
            title = currentTitle
        }

        updateActiveTitleEdit(item.id, currentTitle)
    }

    private var isEmptyTitle: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var collectionControl: some View {
        if isCreatingCollection && canEditTitleAndCollection {
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
                    Button {
                        moveToCollection(collection)
                        if isEmptyTitle {
                            focusTitle()
                        }
                    } label: {
                        collectionLabel(collection)
                    }
                }

                Divider()
                Button("Create New...") {
                    beginCreatingCollection()
                }
            } label: {
                HStack(spacing: 4) {
                    collectionColorIcon(item.collection)

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
            .disabled(!canEditTitleAndCollection)
        }
    }

    private func collectionLabel(_ collection: String) -> some View {
        Label {
            Text(collection)
        } icon: {
            collectionColorIcon(collection)
        }
    }

    private func collectionColorIcon(_ collection: String) -> some View {
        CollectionColorSwatch(color: model.collectionColor(named: collection), size: 7)
    }

    private func beginCreatingCollection() {
        guard canEditTitleAndCollection else {
            return
        }

        isCreatingCollection = true
        newCollection = ""
    }

    private func moveToCollection(_ name: String) {
        guard canEditTitleAndCollection, name != item.collection else {
            return
        }

        moveItemToCollection(item, name)
    }

    private func focusNewCollectionField() {
        guard canEditTitleAndCollection else {
            return
        }

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

private struct TodoTitleTextViewIdentity: Hashable {
    var itemID: String
    var showsCollection: Bool
}

private struct TodoTitleTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var isComposing: Bool

    let isFocused: Bool
    let isEditable: Bool
    let status: TodoStatus
    let selectionBehavior: TodoFocusSelectionBehavior?
    let consumeSelectionBehavior: () -> Void
    let focus: () -> Void
    let clearFocusIfCurrent: () -> Void
    let onKeyDown: (NSEvent, NSTextView) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> SelfSizingTextView {
        let textView = SelfSizingTextView()
        textView.delegate = context.coordinator
        textView.onKeyDown = onKeyDown
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
        textView.registerForDraggedTypes([.fileURL])
        return textView
    }

    func updateNSView(_ textView: SelfSizingTextView, context: Context) {
        context.coordinator.parent = self
        textView.onKeyDown = onKeyDown

        var needsStyleUpdate = textView.appliedStyleDimsTitle != status.dimsTitle
        var needsSizeInvalidation = false
        if !textView.hasMarkedText(), textView.string != text {
            let selectedRange = textView.selectedRange()
            textView.string = text
            textView.setSelectedRangeIfNeeded(selectedRange.clamped(to: textView.string))
            needsStyleUpdate = true
            needsSizeInvalidation = true
        }

        if !textView.hasMarkedText(), needsStyleUpdate {
            applyStyle(to: textView)
        }

        textView.setEditableIfNeeded(isEditable)
        if textView.updateTextContainerWidth() || needsSizeInvalidation {
            textView.invalidateIntrinsicContentSize()
        }

        if isFocused && isEditable {
            focus(textView, selectionBehavior: selectionBehavior)
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

    private func focus(_ textView: SelfSizingTextView, selectionBehavior: TodoFocusSelectionBehavior?) {
        if let window = textView.window {
            if window.firstResponder !== textView {
                window.makeFirstResponder(textView)
            }
            applySelectionIfNeeded(to: textView, selectionBehavior: selectionBehavior)
        } else {
            DispatchQueue.main.async {
                if self.isFocused {
                    textView.window?.makeFirstResponder(textView)
                    self.applySelectionIfNeeded(to: textView, selectionBehavior: selectionBehavior)
                }
            }
        }
    }

    @MainActor
    private func applySelectionIfNeeded(
        to textView: SelfSizingTextView,
        selectionBehavior: TodoFocusSelectionBehavior?
    ) {
        guard textView.window?.firstResponder === textView,
              let selectionBehavior else {
            return
        }

        selectionBehavior.apply(to: textView)
        consumeSelectionBehavior()
    }

    private func applyStyle(to textView: SelfSizingTextView) {
        let selectedRange = textView.selectedRange()
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = TodoRowLayout.titleLineSpacing
        paragraphStyle.lineBreakMode = .byWordWrapping

        let textColor = status.dimsTitle ? NSColor.secondaryLabelColor : NSColor.labelColor
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

        textView.setSelectedRangeIfNeeded(selectedRange.clamped(to: textView.string))
        textView.appliedStyleDimsTitle = status.dimsTitle
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TodoTitleTextView

        init(_ parent: TodoTitleTextView) {
            self.parent = parent
        }

        func textDidBeginEditing(_ notification: Notification) {
            guard parent.isEditable else {
                parent.clearFocusIfCurrent()
                return
            }

            parent.focus()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? SelfSizingTextView else {
                return
            }

            let hasMarkedText = textView.hasMarkedText()
            if hasMarkedText {
                parent.isComposing = true
            }

            parent.text = textView.string

            if !hasMarkedText {
                parent.isComposing = false
            }

            textView.invalidateIntrinsicContentSize()
        }

        func textDidEndEditing(_ notification: Notification) {
            guard let textView = notification.object as? SelfSizingTextView else {
                return
            }

            parent.isComposing = false

            DispatchQueue.main.async {
                let window = textView.window
                let firstResponder = window?.firstResponder
                guard firstResponder !== textView else {
                    return
                }

                if self.parent.isFocused,
                   firstResponder == nil || firstResponder === window {
                    self.parent.focus(textView, selectionBehavior: self.parent.selectionBehavior)
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
            guard parent.isEditable else {
                return false
            }

            return true
        }
    }

    final class SelfSizingTextView: NSTextView {
        var appliedStyleDimsTitle: Bool?
        var onKeyDown: ((NSEvent, NSTextView) -> Bool)?

        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: measuredHeight(fitting: bounds.width))
        }

        override func keyDown(with event: NSEvent) {
            if onKeyDown?(event, self) == true {
                return
            }

            super.keyDown(with: event)
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            filePaths(from: sender).isEmpty ? [] : .copy
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            filePaths(from: sender).isEmpty ? [] : .copy
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let paths = filePaths(from: sender)
            guard isEditable, !paths.isEmpty else {
                return false
            }

            let insertion = paths
                .map { $0.replacingOccurrences(of: "\n", with: " ") }
                .joined(separator: " ")
            let insertionIndex = min(
                characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil)),
                (string as NSString).length
            )
            let insertionRange = NSRange(location: insertionIndex, length: 0)
            setSelectedRange(insertionRange)
            insertText(insertion, replacementRange: insertionRange)
            invalidateIntrinsicContentSize()
            return true
        }

        override func setFrameSize(_ newSize: NSSize) {
            let oldWidth = frame.width
            super.setFrameSize(newSize)
            _ = updateTextContainerWidth()

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

        func updateTextContainerWidth() -> Bool {
            guard bounds.width > 0 else {
                return false
            }

            let newSize = NSSize(width: bounds.width, height: CGFloat.greatestFiniteMagnitude)
            guard textContainer?.containerSize != newSize else {
                return false
            }

            textContainer?.containerSize = newSize
            return true
        }

        func setEditableIfNeeded(_ isEditable: Bool) {
            if self.isEditable != isEditable {
                self.isEditable = isEditable
            }

            if isSelectable != isEditable {
                isSelectable = isEditable
            }
        }

        func setSelectedRangeIfNeeded(_ range: NSRange) {
            guard selectedRange() != range else {
                return
            }

            setSelectedRange(range)
        }

        private func filePaths(from draggingInfo: NSDraggingInfo) -> [String] {
            let objects = draggingInfo.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) ?? []

            return objects.compactMap { object in
                if let url = object as? URL {
                    return url.path
                }

                return (object as? NSURL)?.path
            }
        }
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
