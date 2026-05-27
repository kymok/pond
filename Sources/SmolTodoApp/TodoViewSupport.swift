import AppKit
import SwiftUI
import TodoCore

enum TodoFocusField: Hashable {
    case title(String)
    case collection(String)
}

extension TodoFocusField {
    var itemID: String? {
        switch self {
        case .title(let id), .collection(let id):
            id
        }
    }
}

enum TodoFocusDirection {
    case up
    case down
}

enum TodoFocusSelectionBehavior {
    case moveInsertionPointToEnd
    case selectAll
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
        case .selectAll:
            textView.selectAll(nil)
        case .range(let range):
            textView.setSelectedRange(range.clamped(to: textView.string))
        }
    }
}

extension NSRange {
    func clamped(to string: String) -> NSRange {
        let length = (string as NSString).length
        let clampedLocation = min(location, length)
        let clampedLength = min(self.length, length - clampedLocation)
        return NSRange(location: clampedLocation, length: clampedLength)
    }
}

enum KeyCode {
    static let backspace: UInt16 = 51
    static let escape: UInt16 = 53
    static let returnKey: UInt16 = 36
    static let keypadEnter: UInt16 = 76
    static let arrowDown: UInt16 = 125
    static let arrowUp: UInt16 = 126
}

enum SidebarLayout {
    static let minimumWidth: CGFloat = 160
    static let maximumWidth: CGFloat = minimumWidth * 3
}

enum TodoRowLayout {
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
}

extension TodoCollectionColor {
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
    let color: TodoCollectionColor
    var size: CGFloat = 10

    var body: some View {
        Image(nsImage: color.swatchImage(diameter: size))
            .renderingMode(.original)
            .resizable()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

extension TodoStatus {
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
        }
    }

    var iconColor: Color {
        switch self {
        case .ready:
            .secondary
        case .draft:
            .secondary
        case .inProgress:
            .blue.opacity(0.7)
        case .completed:
            .green.opacity(0.7)
        case .onHold:
            .orange
        case .aborted:
            .red
        }
    }

    var symbolRenderingMode: SymbolRenderingMode {
        self == .draft ? .hierarchical : .monochrome
    }

    var dimsTitle: Bool {
        self == .inProgress || self == .completed
    }

    var leadingStatusClickTarget: TodoStatus {
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

struct TodoStatusIcon: View {
    let status: TodoStatus
    var font: Font = .body

    var body: some View {
        Image(systemName: status.systemImage)
            .font(font)
            .symbolRenderingMode(status.symbolRenderingMode)
            .foregroundStyle(status.iconColor)
    }
}

struct TodoStatusLabel: View {
    let status: TodoStatus

    var body: some View {
        Label {
            Text(status.displayName)
        } icon: {
            TodoStatusIcon(status: status)
        }
    }
}

struct ActiveTodoTitleEdit {
    var id: String
    var title: String

    var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension NSEvent {
    var isPlainKey: Bool {
        let modifiers: ModifierFlags = [.command, .option, .control, .shift]
        return modifierFlags.intersection(modifiers).isEmpty
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

    let selectedRange = fieldEditor.selectedRange()
    guard selectedRange.length > 0 else {
        return
    }

    fieldEditor.setSelectedRange(NSRange(location: selectedRange.location + selectedRange.length, length: 0))
}

func todoExamplePrompt(cliCommand: String) -> String {
    "Run `\(cliCommand)` and complete the listed tasks. Use `todo item update [task id] --status [status]` to update task status. Skip `Draft` tasks. Mark unclear, unnatural, or clearly unrelated tasks as `on-hold`. Mark tasks as `in-progress` when started and `aborted` if they cannot be completed. Group related work into appropriate commits. Use sub-agents with separate worktrees when parallelization helps, then merge their branches into the current branch. Before finishing, run `\(cliCommand)` again because the user may add more tasks, and ensure no uncommitted changes remain."
}

@MainActor
func copyToPasteboard(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}
