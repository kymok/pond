import AppKit
import SwiftUI
import TodoCore

struct TodoRow: View {
    @EnvironmentObject private var model: TodoAppModel

    let item: TodoItem
    let isDraft: Bool
    let isDragPlaceholder: Bool
    let focusedField: Binding<TodoFocusField?>
    let updateActiveTitleEdit: (String, String) -> Void
    let clearActiveTitleEdit: (String) -> Void
    let saveTitleChange: (TodoItem, String, TodoFocusField?) -> Void
    let moveItemToCollection: (TodoItem, String) -> Void
    let insertDraftBelow: (TodoItem, String) -> Void
    let moveFocus: (TodoItem, TodoFocusDirection, TodoFocusSelectionBehavior) -> Bool
    let deleteAndFocusPrevious: (TodoItem) -> Void
    let deleteEmptyAndMoveFocusDown: (TodoItem, TodoFocusSelectionBehavior) -> Bool

    @State private var autosaveTask: Task<Void, Never>?
    @State private var title: String
    @State private var isComposingTitle = false
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
        insertDraftBelow: @escaping (TodoItem, String) -> Void,
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
        self.insertDraftBelow = insertDraftBelow
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

            if isDraft {
                Color.clear
                    .frame(width: 24, height: 24)
                    .alignmentGuide(.top) { dimensions in
                        dimensions[VerticalAlignment.center] - TodoRowLayout.titleFirstLineCenterY
                    }
            } else {
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
                .alignmentGuide(.top) { dimensions in
                    dimensions[VerticalAlignment.center] - TodoRowLayout.titleFirstLineCenterY
                }
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
                    isComposing: $isComposingTitle,
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
                    cancelAutosave()
                    saveTitle(afterMovingFocusTo: newFocus)
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
        .onDisappear(perform: cancelAutosave)
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
            return insertDraftBelowFromTitle(event)
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

    private func insertDraftBelowFromTitle(_ event: NSEvent) -> Bool {
        guard focusedField.wrappedValue == .title(item.id), event.isPlainKey else {
            return false
        }

        if isEmptyTitle {
            return deleteEmptyAndMoveFocusDown(item, .moveInsertionPointToEnd)
        }

        insertDraftBelow(item, (NSApp.keyWindow?.firstResponder as? NSTextView)?.string ?? title)
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
    @Binding var isComposing: Bool

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
        textView.registerForDraggedTypes([.fileURL])
        return textView
    }

    func updateNSView(_ textView: SelfSizingTextView, context: Context) {
        context.coordinator.parent = self

        if !textView.hasMarkedText(), textView.string != text {
            let selectedRange = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(selectedRange.clamped(to: textView.string))
        }

        if !textView.hasMarkedText() {
            applyStyle(to: textView)
        }

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

        let textColor = isDone || isLocked ? NSColor.secondaryLabelColor : NSColor.labelColor
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

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            filePaths(from: sender).isEmpty ? super.draggingEntered(sender) : .copy
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            filePaths(from: sender).isEmpty ? super.draggingUpdated(sender) : .copy
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let paths = filePaths(from: sender)
            guard isEditable, !paths.isEmpty else {
                return super.performDragOperation(sender)
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

private extension NSRange {
    func clamped(to string: String) -> NSRange {
        let length = (string as NSString).length
        let clampedLocation = min(location, length)
        let clampedLength = min(self.length, length - clampedLocation)
        return NSRange(location: clampedLocation, length: clampedLength)
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
