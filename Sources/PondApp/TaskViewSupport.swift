import AppKit
import SwiftUI
import TaskCore

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
