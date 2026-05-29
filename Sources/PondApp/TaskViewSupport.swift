import AppKit
import SwiftUI
import TaskCore
import UniformTypeIdentifiers

enum TaskFocusField: Hashable {
    case title(String)
    case collection(String)
    case note(String)
}

extension TaskFocusField {
    var itemID: String? {
        switch self {
        case .title(let id), .collection(let id), .note(let id):
            id
        }
    }
}

enum TaskFocusDirection {
    case up
    case down
}

enum TaskFocusSelectionBehavior {
    case moveInsertionPointToEnd
    case nearestInsertionPoint(toWindowPoint: NSPoint)
    case range(NSRange)

    @MainActor
    func applyToCurrentTextField() {
        guard let fieldEditor = NSApp.keyWindow?.firstResponder as? NSTextView else {
            return
        }

        apply(to: fieldEditor)
    }

    @MainActor
    func apply(to textView: NSTextView) {
        switch self {
        case .moveInsertionPointToEnd:
            let length = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(location: length, length: 0))
        case .nearestInsertionPoint(let windowPoint):
            let location = textView.nearestInsertionIndex(toWindowPoint: windowPoint)
            textView.setSelectedRange(NSRange(location: location, length: 0).clamped(to: textView.string))
        case .range(let range):
            textView.setSelectedRange(range.clamped(to: textView.string))
        }
    }
}

struct TaskFocusSelectionRequest {
    let id = UUID()
    let behavior: TaskFocusSelectionBehavior
}

extension NSRange {
    func clamped(to string: String) -> NSRange {
        let length = (string as NSString).length
        let clampedLocation = min(location, length)
        let clampedLength = min(self.length, length - clampedLocation)
        return NSRange(location: clampedLocation, length: clampedLength)
    }
}

private extension NSTextView {
    func nearestInsertionIndex(toWindowPoint windowPoint: NSPoint) -> Int {
        guard let layoutManager, let textContainer else {
            return characterIndexForInsertion(at: convert(windowPoint, from: nil))
        }

        layoutManager.ensureLayout(for: textContainer)

        var point = convert(windowPoint, from: nil)
        if let nearestLine = nearestLineFragmentRect(to: point, layoutManager: layoutManager, textContainer: textContainer) {
            point.y = nearestLine.midY
        }

        return characterIndexForInsertion(at: point)
    }

    func nearestLineFragmentRect(
        to point: NSPoint,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> NSRect? {
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        guard glyphRange.length > 0 else {
            return nil
        }

        let origin = textContainerOrigin
        var nearestRect: NSRect?
        var nearestDistance = CGFloat.greatestFiniteMagnitude
        var glyphIndex = glyphRange.location

        while glyphIndex < NSMaxRange(glyphRange) {
            var lineRange = NSRange()
            let rect = layoutManager
                .lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineRange)
                .offsetBy(dx: origin.x, dy: origin.y)
            let distance = verticalDistance(from: point.y, to: rect)

            if distance < nearestDistance {
                nearestDistance = distance
                nearestRect = rect
            }

            let nextGlyphIndex = NSMaxRange(lineRange)
            guard nextGlyphIndex > glyphIndex else {
                break
            }

            glyphIndex = nextGlyphIndex
        }

        return nearestRect
    }

    func verticalDistance(from y: CGFloat, to rect: NSRect) -> CGFloat {
        if y < rect.minY {
            return rect.minY - y
        }

        if y > rect.maxY {
            return y - rect.maxY
        }

        return 0
    }
}

enum KeyCode {
    static let backspace: UInt16 = 51
    static let d: UInt16 = 2
    static let end: UInt16 = 119
    static let escape: UInt16 = 53
    static let n: UInt16 = 45
    static let r: UInt16 = 15
    static let tab: UInt16 = 48
    static let returnKey: UInt16 = 36
    static let keypadEnter: UInt16 = 76
    static let pageUp: UInt16 = 116
    static let pageDown: UInt16 = 121
    static let arrowLeft: UInt16 = 123
    static let arrowRight: UInt16 = 124
    static let arrowDown: UInt16 = 125
    static let arrowUp: UInt16 = 126
}

enum SidebarLayout {
    static let minimumWidth: CGFloat = 160
    static let maximumWidth: CGFloat = minimumWidth * 3
}

enum TaskRowLayout {
    static let collectionControlWidth: CGFloat = 80
    static let collectionControlHorizontalPadding: CGFloat = 8
    static let collectionControlContentWidth = collectionControlWidth - (collectionControlHorizontalPadding * 2)
    static let rowVerticalPadding: CGFloat = 10
    static let rowMinHeight: CGFloat = 44

    static var titleFont: NSFont {
        NSFont.systemFont(ofSize: NSFont.systemFontSize)
    }

    static var titleLineHeight: CGFloat {
        titleFont.pointSize * 1.25
    }

    static var titleLineSpacing: CGFloat {
        max(0, titleLineHeight - NSLayoutManager().defaultLineHeight(for: titleFont))
    }

    static var titleFirstLineCenterY: CGFloat {
        titleLineHeight / 2
    }

    static var noteFont: NSFont {
        NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    }

    static var noteLineHeight: CGFloat {
        noteFont.pointSize * 1.25
    }

    static var noteLineSpacing: CGFloat {
        max(0, noteLineHeight - NSLayoutManager().defaultLineHeight(for: noteFont))
    }
}

extension TaskCollectionColor {
    var swiftUIColor: Color {
        Color(nsColor: swatchNSColor)
    }

    fileprivate var swatchNSColor: NSColor {
        switch self {
        case .gray:
            .secondaryLabelColor
        case .red:
            .systemRed
        case .orange:
            .systemOrange
        case .yellow:
            .systemYellow
        case .green:
            .systemGreen
        case .blue:
            .systemBlue
        case .purple:
            .systemPurple
        }
    }

    fileprivate func swatchImage(diameter: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: diameter, height: diameter))
        image.lockFocus()

        let inset = diameter >= 10 ? 1.0 : 0.0
        let circlePath = NSBezierPath(
            ovalIn: NSRect(
                x: inset,
                y: inset,
                width: diameter - (inset * 2),
                height: diameter - (inset * 2)
            )
        )
        swatchNSColor.setFill()
        circlePath.fill()
        NSColor.separatorColor.withAlphaComponent(0.45).setStroke()
        circlePath.lineWidth = 0.75
        circlePath.stroke()

        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}

extension String {
    var shellEscaped: String {
        "'\(replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

struct CollectionColorSwatch: View {
    let color: TaskCollectionColor
    var size: CGFloat = 10

    var body: some View {
        Image(nsImage: color.swatchImage(diameter: size))
            .renderingMode(.original)
            .resizable()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

extension TaskStatus {
    var systemImage: String {
        switch self {
        case .ready:
            "circle"
        case .draft:
            "pencil.circle"
        case .inProgress:
            "play.circle.fill"
        case .completed:
            "checkmark.circle.fill"
        case .onHold:
            "smallcircle.filled.circle.fill"
        case .aborted:
            "exclamationmark.circle.fill"
        case .rejected:
            "xmark.circle.fill"
        }
    }

    var iconColor: Color {
        Color(nsColor: iconNSColor)
    }

    var iconNSColor: NSColor {
        switch self {
        case .ready:
            .secondaryLabelColor
        case .draft:
            .secondaryLabelColor
        case .inProgress:
            .systemBlue.withAlphaComponent(0.7)
        case .completed:
            .systemGreen.withAlphaComponent(0.7)
        case .onHold:
            .systemOrange
        case .aborted:
            .systemRed
        case .rejected:
            .systemRed.withAlphaComponent(0.75)
        }
    }

    var menuImage: NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: NSFont.systemFontSize, weight: .regular)
        guard let symbol = NSImage(
            systemSymbolName: systemImage,
            accessibilityDescription: displayName
        )?.withSymbolConfiguration(configuration) else {
            return NSImage(size: NSSize(width: 16, height: 16))
        }

        let image = NSImage(size: symbol.size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: symbol.size)
        symbol.draw(in: rect)
        iconNSColor.setFill()
        rect.fill(using: .sourceAtop)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    var symbolRenderingMode: SymbolRenderingMode {
        self == .draft ? .hierarchical : .monochrome
    }

    var dimsTitle: Bool {
        self == .inProgress || self == .completed
    }

    var leadingStatusClickTarget: TaskStatus {
        switch self {
        case .ready:
            .completed
        case .inProgress:
            .completed
        default:
            .ready
        }
    }
}

struct TaskStatusIcon: View {
    let status: TaskStatus
    var font: Font = .body

    var body: some View {
        Image(systemName: status.systemImage)
            .font(font)
            .symbolRenderingMode(status.symbolRenderingMode)
            .foregroundStyle(status.iconColor)
    }
}

struct TaskStatusLabel: View {
    let status: TaskStatus

    var body: some View {
        Label {
            Text(status.displayName)
        } icon: {
            TaskStatusIcon(status: status)
        }
    }
}

struct ActiveTaskTitleEdit {
    var id: String
    var title: String

    var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension TaskItem {
    var allowsTitleAndCollectionEditing: Bool {
        status != .inProgress && status != .completed
    }
}

enum TaskDragElementRole: String {
    case sourceRow
    case preview
}

struct TaskDragElementContext: Equatable {
    let role: TaskDragElementRole
    let includesMenuButton: Bool
    let showsCollection: Bool
    let titleLength: Int
    let status: String
    let collection: String
}

struct TaskDragElementMetrics: Equatable {
    let size: CGSize
    let windowFrame: CGRect?
    let screenFrame: CGRect?
}

struct TaskDragElementSnapshot: Equatable {
    let context: TaskDragElementContext
    let metrics: TaskDragElementMetrics
}

struct TaskDragMetricsProbe: NSViewRepresentable {
    let itemID: String
    let context: TaskDragElementContext
    let report: (String, TaskDragElementContext, TaskDragElementMetrics) -> Void

    func makeNSView(context: Context) -> TaskDragMetricsNSView {
        let view = TaskDragMetricsNSView(frame: .zero)
        view.itemID = itemID
        view.elementContext = self.context
        view.report = report
        view.scheduleReport()
        return view
    }

    func updateNSView(_ nsView: TaskDragMetricsNSView, context: Context) {
        nsView.itemID = itemID
        nsView.elementContext = self.context
        nsView.report = report
        nsView.scheduleReport()
    }
}

final class TaskDragMetricsNSView: NSView {
    var itemID = ""
    var elementContext: TaskDragElementContext?
    var report: ((String, TaskDragElementContext, TaskDragElementMetrics) -> Void)?

    private var lastReportedItemID = ""
    private var lastReportedContext: TaskDragElementContext?
    private var lastReportedMetrics: TaskDragElementMetrics?
    private var reportIsScheduled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleReport()
    }

    override func layout() {
        super.layout()
        scheduleReport()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scheduleReport()
    }

    func scheduleReport() {
        guard !reportIsScheduled else {
            return
        }

        reportIsScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.reportIfChanged()
        }
    }

    private func reportIfChanged() {
        reportIsScheduled = false
        guard let elementContext else {
            return
        }

        let metrics = currentMetrics()
        guard itemID != lastReportedItemID
            || elementContext != lastReportedContext
            || metrics != lastReportedMetrics else {
            return
        }

        lastReportedItemID = itemID
        lastReportedContext = elementContext
        lastReportedMetrics = metrics
        report?(itemID, elementContext, metrics)
    }

    private func currentMetrics() -> TaskDragElementMetrics {
        let windowFrame: CGRect?
        let screenFrame: CGRect?

        if let window {
            let frameInWindow = convert(bounds, to: nil)
            windowFrame = frameInWindow
            screenFrame = window.convertToScreen(frameInWindow)
        } else {
            windowFrame = nil
            screenFrame = nil
        }

        return TaskDragElementMetrics(
            size: bounds.size,
            windowFrame: windowFrame,
            screenFrame: screenFrame
        )
    }
}

@MainActor
final class TaskDragState: ObservableObject {
    @Published var draggedItemID: String?
    @Published private var provisionalItemIDs: [String]?

    private var sourceSnapshotsByItemID: [String: TaskDragElementSnapshot] = [:]

    func beginDragging(item: TaskItem, visibleItemIDs: [String], selectedCollection _: String?) {
        draggedItemID = item.id
        provisionalItemIDs = visibleItemIDs
    }

    func recordElementMetrics(
        itemID: String,
        context: TaskDragElementContext,
        metrics: TaskDragElementMetrics
    ) {
        let snapshot = TaskDragElementSnapshot(context: context, metrics: metrics)
        switch context.role {
        case .sourceRow:
            sourceSnapshotsByItemID[itemID] = snapshot
        case .preview:
            break
        }
    }

    func finishDragging(reason: String = "unspecified") {
        _ = reason
        objectWillChange.send()
        draggedItemID = nil
        provisionalItemIDs = nil
    }

    func sourceSize(for itemID: String) -> CGSize? {
        let sourceSnapshot = sourceSnapshotsByItemID[itemID]
        guard let size = sourceSnapshot?.metrics.size,
              size.width > 0,
              size.height > 0 else {
            return nil
        }

        return size
    }

    func finishDraggingAfterCurrentEvent(reason: String) {
        finishDragging(reason: reason)
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.draggedItemID != nil || self.provisionalItemIDs != nil else {
                return
            }

            self.finishDragging(reason: "\(reason).deferred")
        }
    }

    func orderedItems(_ items: [TaskItem]) -> [TaskItem] {
        let visibleIDs = items.map(\.id)
        let orderedIDs = orderedItemIDs(matching: visibleIDs)
        guard orderedIDs != visibleIDs else {
            return items
        }

        let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        return orderedIDs.compactMap { itemsByID[$0] }
    }

    @discardableResult
    func moveDraggedItem(over targetID: String, visibleItemIDs: [String]) -> Bool {
        guard let draggedItemID,
              draggedItemID != targetID,
              visibleItemIDs.contains(draggedItemID),
              visibleItemIDs.contains(targetID) else {
            return false
        }

        var orderedIDs = orderedItemIDs(matching: visibleItemIDs)
        guard let sourceIndex = orderedIDs.firstIndex(of: draggedItemID) else {
            return false
        }

        orderedIDs.remove(at: sourceIndex)
        guard let targetIndex = orderedIDs.firstIndex(of: targetID) else {
            return false
        }

        let originalTargetIndex = visibleItemIDs.firstIndex(of: targetID) ?? targetIndex
        let insertionIndex = sourceIndex < originalTargetIndex ? targetIndex + 1 : targetIndex
        orderedIDs.insert(draggedItemID, at: insertionIndex)

        guard orderedIDs != provisionalItemIDs else {
            return false
        }

        provisionalItemIDs = orderedIDs
        return true
    }

    func dropPlacement(visibleItemIDs: [String]) -> (itemID: String, previousID: String?, nextID: String?)? {
        guard let draggedItemID else {
            return nil
        }

        let orderedIDs = orderedItemIDs(matching: visibleItemIDs)
        guard let index = orderedIDs.firstIndex(of: draggedItemID) else {
            return nil
        }

        let previousID = index > 0 ? orderedIDs[index - 1] : nil
        let nextID = orderedIDs.indices.contains(index + 1) ? orderedIDs[index + 1] : nil
        return (draggedItemID, previousID, nextID)
    }

    private func orderedItemIDs(matching visibleItemIDs: [String]) -> [String] {
        guard let provisionalItemIDs,
              provisionalItemIDs.count == visibleItemIDs.count,
              Set(provisionalItemIDs) == Set(visibleItemIDs) else {
            return visibleItemIDs
        }

        return provisionalItemIDs
    }
}

enum TaskItemDrag {
    static let type = UTType(exportedAs: "dev.kymok.pond.task-item")
    static let acceptedTypes = [type]

    static func itemProvider(id: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { completion in
            completion(id.data(using: .utf8), nil)
            return nil
        }
        return provider
    }

    @discardableResult
    static func loadItemID(
        from info: DropInfo,
        completion: @escaping @MainActor @Sendable (String?) -> Void
    ) -> Bool {
        guard let provider = info.itemProviders(for: acceptedTypes).first else {
            return false
        }

        provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            let itemID = data.flatMap { String(data: $0, encoding: .utf8) }
            Task { @MainActor in
                completion(itemID)
            }
        }
        return true
    }
}

extension NSEvent {
    var isPlainKey: Bool {
        let modifiers: ModifierFlags = [.command, .option, .control, .shift]
        return modifierFlags.intersection(modifiers).isEmpty
    }

    var isCommandOnlyKey: Bool {
        let exclusiveModifiers: ModifierFlags = [.option, .control, .shift]
        return modifierFlags.contains(.command)
            && modifierFlags.intersection(exclusiveModifiers).isEmpty
    }

    var isCommandOptionOnlyKey: Bool {
        let exclusiveModifiers: ModifierFlags = [.control, .shift]
        return modifierFlags.contains(.command)
            && modifierFlags.contains(.option)
            && modifierFlags.intersection(exclusiveModifiers).isEmpty
    }

    var isPlainReturnKey: Bool {
        isPlainKey && (keyCode == KeyCode.returnKey || keyCode == KeyCode.keypadEnter)
    }

    var isCommandReturnKey: Bool {
        isCommandOnlyKey && (keyCode == KeyCode.returnKey || keyCode == KeyCode.keypadEnter)
    }

    var isModifiedBackspace: Bool {
        let modifiers: ModifierFlags = [.command, .option, .control]
        return !modifierFlags.intersection(modifiers).isEmpty
    }
}

@MainActor
func moveCurrentTextFieldInsertionPointToEnd() {
    guard let fieldEditor = NSApp.keyWindow?.firstResponder as? NSTextView else {
        return
    }

    let length = (fieldEditor.string as NSString).length
    fieldEditor.setSelectedRange(NSRange(location: length, length: 0))
}

@MainActor
func selectCurrentTextFieldText() {
    guard let fieldEditor = NSApp.keyWindow?.firstResponder as? NSTextView else {
        return
    }

    fieldEditor.selectAll(nil)
}

@MainActor
func clearCurrentTextFieldSelection() {
    guard let fieldEditor = NSApp.keyWindow?.firstResponder as? NSTextView else {
        return
    }

    clearTextFieldSelection(fieldEditor)
}

@MainActor
func clearTextFieldSelection(_ textView: NSTextView) {
    let selectedRange = textView.selectedRange()
    guard selectedRange.length > 0 else {
        return
    }

    textView.setSelectedRange(NSRange(location: selectedRange.location + selectedRange.length, length: 0))
}

func taskExamplePrompt(template: String, cliCommand: String, collectionName: String) -> String {
    TaskPromptTemplate(template).evaluated(
        variables: [
            "cliCommand": cliCommand,
            "collectionName": collectionName
        ]
    )
}

@MainActor
func copyToPasteboard(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}
