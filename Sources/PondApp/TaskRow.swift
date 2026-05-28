import AppKit
import SwiftUI
import TaskCore

struct TaskRow: View {
    @EnvironmentObject private var model: TaskAppModel

    let item: TaskItem
    let isPendingDraft: Bool
    let focusedField: Binding<TaskFocusField?>
    let updateActiveTitleEdit: (String, String) -> Void
    let clearActiveTitleEdit: (String) -> Void
    let saveTitleChange: (TaskItem, String, TaskFocusField?) -> Void
    let confirmTitleChange: (TaskItem, String, TaskFocusField?) -> Void
    let moveItemToCollection: (TaskItem, String) -> Void
    let insertDraftBelow: (TaskItem, String) -> Void
    let titleFocusSelectionBehavior: TaskFocusSelectionRequest?
    let noteFocusSelectionBehavior: TaskFocusSelectionRequest?
    let focusTextField: (TaskFocusField, TaskFocusSelectionBehavior) -> Void
    let consumeFocusSelectionBehavior: (TaskFocusField) -> Void
    let hasVisibleItemAfter: (TaskItem) -> Bool
    let moveFocus: (TaskItem, TaskFocusDirection, TaskFocusSelectionBehavior) -> Bool
    let moveItem: (TaskItem, TaskFocusDirection) -> Bool
    let deleteAndFocusPrevious: (TaskItem) -> Void
    let deleteEmptyAndMoveFocusDown: (TaskItem, TaskFocusSelectionBehavior) -> Bool

    @State private var autosaveTask: Task<Void, Never>?
    @State private var noteAutosaveTask: Task<Void, Never>?
    @State private var title: String
    @State private var isComposingTitle = false
    @State private var isComposingNote = false
    @State private var isCreatingCollection = false
    @State private var newCollection = ""
    @State private var skipsNextFocusLossSave = false
    @State private var noteBodies: [String: String] = [:]
    @State private var draftNoteBody: String?
    @FocusState private var isCollectionFocused: Bool

    init(
        item: TaskItem,
        isPendingDraft: Bool,
        activeTitle: String? = nil,
        focusedField: Binding<TaskFocusField?>,
        updateActiveTitleEdit: @escaping (String, String) -> Void,
        clearActiveTitleEdit: @escaping (String) -> Void,
        saveTitleChange: @escaping (TaskItem, String, TaskFocusField?) -> Void,
        confirmTitleChange: @escaping (TaskItem, String, TaskFocusField?) -> Void,
        moveItemToCollection: @escaping (TaskItem, String) -> Void,
        insertDraftBelow: @escaping (TaskItem, String) -> Void,
        titleFocusSelectionBehavior: TaskFocusSelectionRequest?,
        noteFocusSelectionBehavior: TaskFocusSelectionRequest?,
        focusTextField: @escaping (TaskFocusField, TaskFocusSelectionBehavior) -> Void,
        consumeFocusSelectionBehavior: @escaping (TaskFocusField) -> Void,
        hasVisibleItemAfter: @escaping (TaskItem) -> Bool,
        moveFocus: @escaping (TaskItem, TaskFocusDirection, TaskFocusSelectionBehavior) -> Bool,
        moveItem: @escaping (TaskItem, TaskFocusDirection) -> Bool,
        deleteAndFocusPrevious: @escaping (TaskItem) -> Void,
        deleteEmptyAndMoveFocusDown: @escaping (TaskItem, TaskFocusSelectionBehavior) -> Bool
    ) {
        self.item = item
        self.isPendingDraft = isPendingDraft
        self.focusedField = focusedField
        self.updateActiveTitleEdit = updateActiveTitleEdit
        self.clearActiveTitleEdit = clearActiveTitleEdit
        self.saveTitleChange = saveTitleChange
        self.confirmTitleChange = confirmTitleChange
        self.moveItemToCollection = moveItemToCollection
        self.insertDraftBelow = insertDraftBelow
        self.titleFocusSelectionBehavior = titleFocusSelectionBehavior
        self.noteFocusSelectionBehavior = noteFocusSelectionBehavior
        self.focusTextField = focusTextField
        self.consumeFocusSelectionBehavior = consumeFocusSelectionBehavior
        self.hasVisibleItemAfter = hasVisibleItemAfter
        self.moveFocus = moveFocus
        self.moveItem = moveItem
        self.deleteAndFocusPrevious = deleteAndFocusPrevious
        self.deleteEmptyAndMoveFocusDown = deleteEmptyAndMoveFocusDown
        _title = State(initialValue: activeTitle ?? item.title)
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
                dimensions[VerticalAlignment.center] - TaskRowLayout.titleFirstLineCenterY
            }

            if isPendingDraft {
                Color.clear
                    .frame(width: 24, height: 24)
                    .alignmentGuide(.top) { dimensions in
                        dimensions[VerticalAlignment.center] - TaskRowLayout.titleFirstLineCenterY
                    }
            } else {
                Menu {
                    Section("Status") {
                        ForEach(TaskStatus.allCases, id: \.self) { status in
                            Button {
                                model.setStatus(item, status: status)
                            } label: {
                                Label {
                                    Text(status.displayName)
                                } icon: {
                                    Image(nsImage: status.menuImage)
                                        .renderingMode(.original)
                                }
                            }
                        }
                    }

                    Section("Item") {
                        Button(item.notes.isEmpty ? "Add Note" : "Edit Note") {
                            beginAddingNote()
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
                .help("Task status")
                .alignmentGuide(.top) { dimensions in
                    dimensions[VerticalAlignment.center] - TaskRowLayout.titleFirstLineCenterY
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                titleEditor

                if showsNotes {
                    notesBlock
                        .transition(.opacity)
                }
            }
            .frame(minHeight: TaskRowLayout.titleLineHeight, alignment: .topLeading)
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

                if oldFocus == .note(item.id), newFocus != .note(item.id) {
                    cancelNoteAutosave()
                    saveNoteIfNeeded(allowsEmptyRemoval: true)
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
            .onChange(of: isComposingNote) { _, isComposing in
                if isComposing {
                    cancelNoteAutosave()
                } else if focusedField.wrappedValue == .note(item.id) {
                    scheduleNoteAutosave(currentNoteBody)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if model.selectedCollectionName == nil {
                collectionControl
            }
        }
        .padding(.vertical, TaskRowLayout.rowVerticalPadding)
        .padding(.horizontal, 12)
        .frame(minHeight: TaskRowLayout.rowMinHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .taskRowHitArea(focusTitle(at:))
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

            Button(item.notes.isEmpty ? "Add Note" : "Edit Note") {
                beginAddingNote()
            }
            .disabled(isPendingDraft)

            Button("Delete", role: .destructive) {
                deleteAndFocusPrevious(item)
            }
        }
        .onChange(of: item.status) { _, _ in
            clearSelectionAfterStatusChange()
            clearLockedFocus()
        }
        .onChange(of: item.notes) { _, notes in
            syncNoteBodies(with: notes)
        }
        .onDisappear {
            cancelAutosave()
            cancelNoteAutosave()
        }
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
        let image = TaskStatusIcon(
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

    private var titleEditor: some View {
        ZStack(alignment: .topLeading) {
            if title.isEmpty {
                Text("Title")
                    .frame(height: TaskRowLayout.titleLineHeight, alignment: .center)
                    .foregroundStyle(.tertiary)
                    .allowsHitTesting(false)
            }

            TaskTitleTextView(
                text: $title,
                isComposing: $isComposingTitle,
                isFocused: canEditTitleAndCollection && focusedField.wrappedValue == .title(item.id),
                isEditable: canEditTitleAndCollection,
                style: .title(status: item.status),
                selectionBehavior: titleFocusSelectionBehavior,
                consumeSelectionBehavior: { consumeFocusSelectionBehavior(.title(item.id)) },
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
                },
                onCommand: { commandSelector, textView, event in
                    handleTitleCommand(commandSelector, textView: textView, event: event)
                }
            )
            .id(TaskTitleTextViewIdentity(
                itemID: item.id,
                showsCollection: model.selectedCollectionName == nil
            ))
            .allowsHitTesting(canEditTitleAndCollection || item.status != .inProgress)
        }
    }

    private var showsNotes: Bool {
        !item.notes.isEmpty || draftNoteBody != nil || isNoteFocused
    }

    private var isNoteFocused: Bool {
        focusedField.wrappedValue == .note(item.id)
    }

    private var notesBlock: some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: "square.and.pencil")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16, height: TaskRowLayout.noteLineHeight, alignment: .center)
                .padding(.vertical, 2)

            noteEditor
        }
        .animation(.easeInOut(duration: 0.22), value: item.notes.map(\.id))
        .animation(.easeInOut(duration: 0.22), value: draftNoteBody != nil)
        .animation(.easeInOut(duration: 0.22), value: isNoteFocused)
    }

    private var noteEditor: some View {
        ZStack(alignment: .topLeading) {
            if currentNoteBody.isEmpty {
                Text("Note")
                    .frame(height: TaskRowLayout.noteLineHeight, alignment: .center)
                    .foregroundStyle(.tertiary)
                    .font(.caption)
                    .allowsHitTesting(false)
            }

            TaskTitleTextView(
                text: currentNoteBinding,
                isComposing: $isComposingNote,
                isFocused: focusedField.wrappedValue == .note(item.id),
                isEditable: !isPendingDraft,
                style: .note,
                selectionBehavior: noteFocusSelectionBehavior,
                consumeSelectionBehavior: { consumeFocusSelectionBehavior(.note(item.id)) },
                focus: {
                    guard !isPendingDraft else {
                        return
                    }

                    focusedField.wrappedValue = .note(item.id)
                },
                clearFocusIfCurrent: {
                    if focusedField.wrappedValue == .note(item.id) {
                        focusedField.wrappedValue = nil
                    }
                },
                onKeyDown: { event, textView in
                    handleNoteKeyDown(event, textView: textView)
                },
                onCommand: { commandSelector, textView, event in
                    handleNoteCommand(commandSelector, textView: textView, event: event)
                }
            )
        }
        .padding(.vertical, 2)
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

    private var currentNoteBinding: Binding<String> {
        Binding {
            currentNoteBody
        } set: { body in
            if let note = item.notes.first {
                noteBodies[note.id] = body
            } else {
                draftNoteBody = body
            }

            if focusedField.wrappedValue == .note(item.id) {
                scheduleNoteAutosave(body)
            }
        }
    }

    private var currentNoteBody: String {
        if let note = item.notes.first {
            return noteBodies[note.id] ?? note.body
        }

        return draftNoteBody ?? ""
    }

    private func beginAddingNote() {
        guard !isPendingDraft else {
            return
        }

        if item.notes.isEmpty, draftNoteBody == nil {
            draftNoteBody = ""
        }

        DispatchQueue.main.async {
            focusTextField(.note(item.id), .moveInsertionPointToEnd)
        }
    }

    private func saveNoteIfNeeded(allowsEmptyRemoval: Bool) {
        guard let note = item.notes.first else {
            saveDraftNoteIfNeeded(allowsEmptyRemoval: allowsEmptyRemoval)
            return
        }

        let id = note.id
        let body = noteBodies[id] ?? note.body
        let cleanBody = body.trimmingCharacters(in: .whitespacesAndNewlines)

        if cleanBody.isEmpty {
            guard allowsEmptyRemoval else {
                return
            }

            model.deleteNote(item, note: note)
            noteBodies[id] = nil
            if focusedField.wrappedValue == .note(item.id) {
                focusedField.wrappedValue = nil
            }
        } else if cleanBody != note.body {
            withoutNotePersistenceAnimation {
                model.updateNote(item, note: note, body: cleanBody)
                clearCachedNoteBodyAfterSave(id)
            }
        } else {
            clearCachedNoteBodyAfterSave(id)
        }
    }

    private func saveDraftNoteIfNeeded(allowsEmptyRemoval: Bool) {
        let body = draftNoteBody ?? ""
        let cleanBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let focusSelectionBehavior = focusedNoteSelectionBehavior()

        guard !cleanBody.isEmpty else {
            guard allowsEmptyRemoval else {
                return
            }

            draftNoteBody = nil
            if focusedField.wrappedValue == .note(item.id) {
                focusedField.wrappedValue = nil
            }
            return
        }

        let updatedItem = withoutNotePersistenceAnimation { () -> TaskItem? in
            let updatedItem = model.addNote(item, body: cleanBody)
            if focusedField.wrappedValue == .note(item.id),
               let note = updatedItem?.notes.first {
                noteBodies[note.id] = body
            }
            draftNoteBody = nil
            return updatedItem
        }

        if focusedField.wrappedValue == .note(item.id),
           updatedItem?.notes.first != nil {
            if let focusSelectionBehavior {
                DispatchQueue.main.async {
                    focusTextField(.note(item.id), focusSelectionBehavior)
                }
            }
        }
    }

    private func syncNoteBodies(with notes: [TaskNote]) {
        let visibleNoteIDs = Set(notes.map(\.id))
        noteBodies = noteBodies.filter { visibleNoteIDs.contains($0.key) }
    }

    private func clearCachedNoteBodyAfterSave(_ id: String) {
        guard focusedField.wrappedValue != .note(item.id) else {
            return
        }

        noteBodies[id] = nil
    }

    private func focusedNoteSelectionBehavior() -> TaskFocusSelectionBehavior? {
        guard focusedField.wrappedValue == .note(item.id),
              let textView = NSApp.keyWindow?.firstResponder as? NSTextView else {
            return nil
        }

        return .range(textView.selectedRange())
    }

    private func withoutNotePersistenceAnimation<T>(_ updates: () -> T) -> T {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        return withTransaction(transaction, updates)
    }

    private func focusTitle() {
        focusTitle(selectionBehavior: .moveInsertionPointToEnd)
    }

    private func focusTitle(at windowPoint: NSPoint) {
        focusTitle(selectionBehavior: .nearestInsertionPoint(toWindowPoint: windowPoint))
    }

    private func focusTitle(selectionBehavior: TaskFocusSelectionBehavior) {
        guard canEditTitleAndCollection else {
            return
        }

        updateActiveTitleEdit(item.id, title)
        focusTextField(.title(item.id), selectionBehavior)
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

    private func prepareFocusTransition(from textView: NSTextView) {
        clearTextFieldSelection(textView)
    }

    private func moveAdjacentFocus(
        from textView: NSTextView,
        direction: TaskFocusDirection,
        selectionBehavior: TaskFocusSelectionBehavior
    ) -> Bool {
        guard moveFocus(item, direction, selectionBehavior) else {
            return false
        }

        prepareFocusTransition(from: textView)
        return true
    }

    private func handleTitleKeyDown(_ event: NSEvent, textView: NSTextView) -> Bool {
        guard !textView.hasMarkedText() else {
            return false
        }

        switch event.keyCode {
        case KeyCode.escape:
            return defocus(event)
        case KeyCode.end:
            guard event.isPlainKey else {
                return false
            }

            syncTitleFocusAndText(from: textView)
            moveInsertionPointToEnd(textView)
            return true
        case KeyCode.tab:
            guard event.isPlainKey else {
                return false
            }

            syncTitleFocusAndText(from: textView)
            return moveFocusDownFromTitle(
                textView,
                selectionBehavior: .moveInsertionPointToEnd,
                confirmsTitle: true
            )
        case KeyCode.backspace:
            syncTitleFocusAndText(from: textView)
            return deleteIfEmptyTitleAtStart(event, fieldEditor: textView)
        case KeyCode.arrowUp:
            if event.isCommandOnlyKey {
                syncTitleFocusAndText(from: textView)
                saveNonEmptyTitleBeforeReordering()
                return moveItem(item, .up)
            }

            guard event.isPlainKey else {
                return false
            }

            syncTitleFocusAndText(from: textView)
            guard isInsertionPointOnFirstVisualLine(textView) else {
                return false
            }

            return moveAdjacentFocus(from: textView, direction: .up, selectionBehavior: .selectAll)
        case KeyCode.arrowDown:
            if event.isCommandOnlyKey {
                syncTitleFocusAndText(from: textView)
                saveNonEmptyTitleBeforeReordering()
                return moveItem(item, .down)
            }

            guard event.isPlainKey else {
                return false
            }

            syncTitleFocusAndText(from: textView)
            guard isInsertionPointOnLastVisualLine(textView) else {
                return false
            }

            return moveFocusDownFromTitle(textView, selectionBehavior: .selectAll)
        default:
            return false
        }
    }

    private func handleTitleCommand(_ commandSelector: Selector, textView: NSTextView, event: NSEvent?) -> Bool {
        guard shouldHandlePlainReturnCommand(commandSelector, textView: textView, event: event) else {
            return false
        }

        return handleTitleReturn(textView)
    }

    private func handleCollectionKeyDown(_ event: NSEvent, fieldEditor: NSTextView) -> Bool {
        guard !fieldEditor.hasMarkedText() else {
            return false
        }

        switch event.keyCode {
        case KeyCode.escape:
            return defocus(event)
        case KeyCode.tab:
            guard event.isPlainKey else {
                return false
            }

            return moveFocusDownFromCollection(fieldEditor, selectionBehavior: .moveInsertionPointToEnd)
        case KeyCode.arrowUp:
            if event.isCommandOnlyKey {
                saveNewCollection()
                return moveItem(item, .up)
            }

            guard event.isPlainKey else {
                return false
            }

            return moveAdjacentFocus(from: fieldEditor, direction: .up, selectionBehavior: .selectAll)
        case KeyCode.arrowDown:
            if event.isCommandOnlyKey {
                saveNewCollection()
                return moveItem(item, .down)
            }

            guard event.isPlainKey else {
                return false
            }

            return moveFocusDownFromCollection(fieldEditor, selectionBehavior: .selectAll)
        default:
            return false
        }
    }

    private func handleNoteKeyDown(_ event: NSEvent, textView: NSTextView) -> Bool {
        guard !textView.hasMarkedText() else {
            return false
        }

        switch event.keyCode {
        case KeyCode.escape:
            return defocus(event)
        case KeyCode.tab:
            return moveFocusDownFromNote(event, textView: textView)
        case KeyCode.arrowUp:
            if event.isCommandOnlyKey {
                syncNoteFocusAndText(from: textView)
                saveNoteIfNeeded(allowsEmptyRemoval: true)
                return moveItem(item, .up)
            }

            guard event.isPlainKey else {
                return false
            }

            syncNoteFocusAndText(from: textView)
            guard isInsertionPointOnFirstVisualLine(textView) else {
                return false
            }

            return moveAdjacentFocus(from: textView, direction: .up, selectionBehavior: .selectAll)
        case KeyCode.arrowDown:
            if event.isCommandOnlyKey {
                syncNoteFocusAndText(from: textView)
                saveNoteIfNeeded(allowsEmptyRemoval: true)
                return moveItem(item, .down)
            }

            guard event.isPlainKey else {
                return false
            }

            syncNoteFocusAndText(from: textView)
            guard isInsertionPointOnLastVisualLine(textView) else {
                return false
            }

            return moveFocusDownFromNote(event, textView: textView, selectionBehavior: .selectAll)
        default:
            return false
        }
    }

    private func handleNoteCommand(_ commandSelector: Selector, textView: NSTextView, event: NSEvent?) -> Bool {
        guard shouldHandlePlainReturnCommand(commandSelector, textView: textView, event: event) else {
            return false
        }

        return moveFocusDownFromNote(textView, selectionBehavior: .moveInsertionPointToEnd)
    }

    private func shouldHandlePlainReturnCommand(
        _ commandSelector: Selector,
        textView: NSTextView,
        event: NSEvent?
    ) -> Bool {
        guard commandSelector.isNewlineInsertionCommand,
              event?.isPlainReturnKey == true,
              !textView.hasMarkedText() else {
            return false
        }

        return true
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

    private func handleTitleReturn(_ textView: NSTextView) -> Bool {
        syncTitleFocusAndText(from: textView)
        return moveFocusDownFromTitle(
            textView,
            selectionBehavior: .moveInsertionPointToEnd,
            confirmsTitle: true
        )
    }

    private func resetTitleEditorForNextDraft(_ textView: NSTextView) {
        title = ""
        updateActiveTitleEdit(item.id, "")
        textView.string = ""
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.invalidateIntrinsicContentSize()
    }

    private func moveFocusDownFromTitle(
        _ textView: NSTextView,
        selectionBehavior: TaskFocusSelectionBehavior = .moveInsertionPointToEnd,
        confirmsTitle: Bool = false
    ) -> Bool {
        guard focusedField.wrappedValue == .title(item.id) else {
            return false
        }

        let currentTitle = textView.string
        if currentTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return deleteEmptyAndMoveFocusDown(item, selectionBehavior)
        }

        prepareFocusTransition(from: textView)

        if showsNotes {
            if confirmsTitle {
                confirmTitleForTransition(currentTitle)
            }

            focusTextField(.note(item.id), selectionBehavior)
            return true
        }

        if hasVisibleItemAfter(item) {
            if confirmsTitle {
                confirmTitleForTransition(currentTitle)
            }

            _ = moveFocus(item, .down, selectionBehavior)
            return true
        }

        cancelAutosave()
        skipsNextFocusLossSave = true
        if !isPendingDraft {
            endCurrentTitleEdit(textView)
        }
        insertDraftBelow(item, currentTitle)
        if isPendingDraft {
            resetTitleEditorForNextDraft(textView)
        }
        return true
    }

    private func endCurrentTitleEdit(_ textView: NSTextView) {
        moveInsertionPointToEnd(textView)
        focusedField.wrappedValue = nil
        textView.window?.makeFirstResponder(nil)
    }

    private func moveInsertionPointToEnd(_ textView: NSTextView) {
        let length = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: length, length: 0))
    }

    private func moveFocusDownFromNote(
        _ event: NSEvent,
        textView: NSTextView,
        selectionBehavior: TaskFocusSelectionBehavior = .moveInsertionPointToEnd
    ) -> Bool {
        guard event.isPlainKey else {
            return false
        }

        return moveFocusDownFromNote(textView, selectionBehavior: selectionBehavior)
    }

    private func moveFocusDownFromNote(
        _ textView: NSTextView,
        selectionBehavior: TaskFocusSelectionBehavior
    ) -> Bool {
        syncNoteFocusAndText(from: textView)
        prepareFocusTransition(from: textView)
        saveNoteIfNeeded(allowsEmptyRemoval: true)
        if moveFocus(item, .down, selectionBehavior) {
            return true
        }

        cancelAutosave()
        skipsNextFocusLossSave = true
        insertDraftBelow(item, title)
        return true
    }

    private func moveFocusDownFromCollection(
        _ fieldEditor: NSTextView,
        selectionBehavior: TaskFocusSelectionBehavior
    ) -> Bool {
        prepareFocusTransition(from: fieldEditor)
        saveNewCollection()
        if moveFocus(item, .down, selectionBehavior) {
            return true
        }

        guard !isEmptyTitle else {
            return true
        }

        cancelAutosave()
        skipsNextFocusLossSave = true
        insertDraftBelow(item, title)
        return true
    }

    private func confirmTitleForTransition(_ currentTitle: String) {
        cancelAutosave()
        skipsNextFocusLossSave = true
        confirmTitleChange(item, currentTitle, nil)
    }

    private func saveNonEmptyTitleBeforeReordering() {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        cancelAutosave()
        saveTitleChange(item, title, .title(item.id))
    }

    private func saveTitle() {
        cancelAutosave()
        saveTitleChange(item, title, nil)
    }

    private func saveTitle(afterMovingFocusTo newFocus: TaskFocusField?) {
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

    private func scheduleNoteAutosave(_ newBody: String) {
        cancelNoteAutosave()

        guard !isComposingNote else {
            return
        }

        noteAutosaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled,
                  !isComposingNote,
                  !currentTextEditorHasMarkedText(),
                  focusedField.wrappedValue == .note(item.id),
                  currentNoteBody == newBody else {
                return
            }

            saveNoteIfNeeded(allowsEmptyRemoval: false)
            noteAutosaveTask = nil
        }
    }

    private func cancelAutosave() {
        autosaveTask?.cancel()
        autosaveTask = nil
    }

    private func cancelNoteAutosave() {
        noteAutosaveTask?.cancel()
        noteAutosaveTask = nil
    }

    private func currentTitleEditorHasMarkedText() -> Bool {
        currentTextEditorHasMarkedText()
    }

    private func currentTextEditorHasMarkedText() -> Bool {
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

    private func syncNoteFocusAndText(from textView: NSTextView) {
        focusedField.wrappedValue = .note(item.id)
        let currentBody = textView.string

        if let note = item.notes.first {
            if noteBodies[note.id] != currentBody {
                noteBodies[note.id] = currentBody
            }
        } else if draftNoteBody != currentBody {
            draftNoteBody = currentBody
        }
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
            .frame(width: TaskRowLayout.collectionControlWidth)
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

private struct TaskTitleTextViewIdentity: Hashable {
    var itemID: String
    var showsCollection: Bool
}

private extension Selector {
    var isNewlineInsertionCommand: Bool {
        self == #selector(NSResponder.insertNewline(_:))
            || self == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
    }
}

private struct TaskTextViewStyle {
    let id: String
    let font: NSFont
    let lineHeight: CGFloat
    let lineSpacing: CGFloat
    let textColor: NSColor
    let maximumLineCount: Int?
    let allowsFileDrops: Bool

    var maximumHeight: CGFloat? {
        maximumLineCount.map { CGFloat($0) * lineHeight }
    }

    static func title(status: TaskStatus) -> TaskTextViewStyle {
        TaskTextViewStyle(
            id: "title-\(status.dimsTitle)",
            font: TaskRowLayout.titleFont,
            lineHeight: TaskRowLayout.titleLineHeight,
            lineSpacing: TaskRowLayout.titleLineSpacing,
            textColor: status.dimsTitle ? .secondaryLabelColor : .labelColor,
            maximumLineCount: nil,
            allowsFileDrops: true
        )
    }

    static var note: TaskTextViewStyle {
        TaskTextViewStyle(
            id: "note",
            font: TaskRowLayout.noteFont,
            lineHeight: TaskRowLayout.noteLineHeight,
            lineSpacing: TaskRowLayout.noteLineSpacing,
            textColor: .secondaryLabelColor,
            maximumLineCount: nil,
            allowsFileDrops: false
        )
    }
}

private struct TaskTitleTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var isComposing: Bool

    let isFocused: Bool
    let isEditable: Bool
    let style: TaskTextViewStyle
    let selectionBehavior: TaskFocusSelectionRequest?
    let consumeSelectionBehavior: () -> Void
    let focus: () -> Void
    let clearFocusIfCurrent: () -> Void
    let onKeyDown: (NSEvent, NSTextView) -> Bool
    let onCommand: (Selector, NSTextView, NSEvent?) -> Bool

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
        textView.minimumMeasuredHeight = style.lineHeight
        textView.maximumMeasuredHeight = style.maximumHeight
        textView.minSize = NSSize(width: 0, height: style.lineHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.setAllowsFileDrops(style.allowsFileDrops)
        return textView
    }

    func updateNSView(_ textView: SelfSizingTextView, context: Context) {
        context.coordinator.parent = self
        textView.onKeyDown = onKeyDown
        textView.onMouseDown = { [weak coordinator = context.coordinator] in
            coordinator?.focusFromMouseDown()
        }
        textView.minimumMeasuredHeight = style.lineHeight
        textView.maximumMeasuredHeight = style.maximumHeight
        textView.minSize = NSSize(width: 0, height: style.lineHeight)
        textView.setAllowsFileDrops(style.allowsFileDrops)

        var needsStyleUpdate = textView.appliedStyleID != style.id
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

        if selectionBehavior == nil || !isFocused {
            textView.appliedSelectionRequestID = nil
        }

        if isFocused && isEditable {
            focus(textView, selectionRequest: selectionBehavior)
        } else if textView.window?.firstResponder === textView {
            textView.window?.makeFirstResponder(nil)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SelfSizingTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.enclosingScrollView?.contentSize.width ?? nsView.bounds.width
        guard width > 0 else {
            return CGSize(width: proposal.width ?? 0, height: style.lineHeight)
        }

        return CGSize(width: width, height: nsView.measuredHeight(fitting: width))
    }

    private func focus(_ textView: SelfSizingTextView, selectionRequest: TaskFocusSelectionRequest?) {
        if let window = textView.window {
            if window.firstResponder !== textView {
                window.makeFirstResponder(textView)
            }
            applySelectionIfNeeded(to: textView, selectionRequest: selectionRequest)
        } else {
            DispatchQueue.main.async {
                if self.isFocused {
                    textView.window?.makeFirstResponder(textView)
                    self.applySelectionIfNeeded(to: textView, selectionRequest: selectionRequest)
                }
            }
        }
    }

    @MainActor
    private func applySelectionIfNeeded(
        to textView: SelfSizingTextView,
        selectionRequest: TaskFocusSelectionRequest?
    ) {
        guard textView.window?.firstResponder === textView,
              let selectionRequest,
              textView.appliedSelectionRequestID != selectionRequest.id else {
            return
        }

        textView.appliedSelectionRequestID = selectionRequest.id
        selectionRequest.behavior.apply(to: textView)
        consumeSelectionBehavior()
    }

    private func applyStyle(to textView: SelfSizingTextView) {
        let selectedRange = textView.selectedRange()
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = style.lineSpacing
        paragraphStyle.lineBreakMode = .byWordWrapping

        textView.font = style.font
        textView.textColor = style.textColor
        textView.defaultParagraphStyle = paragraphStyle
        textView.typingAttributes = [
            .font: style.font,
            .foregroundColor: style.textColor,
            .paragraphStyle: paragraphStyle
        ]

        let range = NSRange(location: 0, length: (textView.string as NSString).length)
        if range.length > 0 {
            textView.textStorage?.setAttributes(textView.typingAttributes, range: range)
        }

        textView.setSelectedRangeIfNeeded(selectedRange.clamped(to: textView.string))
        textView.appliedStyleID = style.id
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TaskTitleTextView

        init(_ parent: TaskTitleTextView) {
            self.parent = parent
        }

        func textDidBeginEditing(_ notification: Notification) {
            guard parent.isEditable else {
                parent.clearFocusIfCurrent()
                return
            }

            parent.focus()
        }

        @MainActor
        func focusFromMouseDown() {
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
                    self.parent.focus(textView, selectionRequest: self.parent.selectionBehavior)
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

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard let textView = textView as? SelfSizingTextView else {
                return false
            }

            return parent.onCommand(commandSelector, textView, textView.keyDownEventForCommand)
        }
    }

    final class SelfSizingTextView: NSTextView {
        var appliedStyleID: String?
        var minimumMeasuredHeight = TaskRowLayout.titleLineHeight
        var maximumMeasuredHeight: CGFloat?
        var onKeyDown: ((NSEvent, NSTextView) -> Bool)?
        var onMouseDown: (() -> Void)?
        var appliedSelectionRequestID: UUID?
        private(set) var keyDownEventForCommand: NSEvent?
        private var allowsFileDrops = false

        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: measuredHeight(fitting: bounds.width))
        }

        override func keyDown(with event: NSEvent) {
            if onKeyDown?(event, self) == true {
                return
            }

            keyDownEventForCommand = event
            defer {
                keyDownEventForCommand = nil
            }
            super.keyDown(with: event)
        }

        override func mouseDown(with event: NSEvent) {
            if isEditable {
                onMouseDown?()
            }

            super.mouseDown(with: event)
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            allowsFileDrops && !filePaths(from: sender).isEmpty ? .copy : []
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            allowsFileDrops && !filePaths(from: sender).isEmpty ? .copy : []
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let paths = filePaths(from: sender)
            guard allowsFileDrops, isEditable, !paths.isEmpty else {
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
                return minimumMeasuredHeight
            }

            textContainer.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            layoutManager.ensureLayout(for: textContainer)

            let usedHeight = layoutManager.usedRect(for: textContainer).height + textContainerInset.height * 2
            let measuredHeight = max(minimumMeasuredHeight, ceil(usedHeight))
            return min(measuredHeight, maximumMeasuredHeight ?? measuredHeight)
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

        func setAllowsFileDrops(_ allowsFileDrops: Bool) {
            guard self.allowsFileDrops != allowsFileDrops else {
                return
            }

            self.allowsFileDrops = allowsFileDrops
            if allowsFileDrops {
                registerForDraggedTypes([.fileURL])
            } else {
                unregisterDraggedTypes()
            }
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
    func taskRowHitArea(_ focusTitle: @escaping (NSPoint) -> Void) -> some View {
        background {
            TaskRowClickHandler(onClick: focusTitle)
        }
    }

    func collectionChipStyle() -> some View {
        font(.caption)
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

private struct TaskRowClickHandler: NSViewRepresentable {
    let onClick: (NSPoint) -> Void

    func makeNSView(context: Context) -> ClickView {
        let view = ClickView()
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: ClickView, context: Context) {
        nsView.onClick = onClick
    }

    final class ClickView: NSView {
        var onClick: (NSPoint) -> Void = { _ in }

        override var acceptsFirstResponder: Bool {
            false
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }

        override func mouseDown(with event: NSEvent) {
            onClick(event.locationInWindow)
        }
    }
}
