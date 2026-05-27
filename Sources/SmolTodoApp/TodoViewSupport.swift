import AppKit

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

enum KeyCode {
    static let backspace: UInt16 = 51
    static let returnKey: UInt16 = 36
    static let keypadEnter: UInt16 = 76
    static let arrowDown: UInt16 = 125
    static let arrowUp: UInt16 = 126
}

enum SidebarLayout {
    static let width: CGFloat = 160
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
        NSLayoutManager().defaultLineHeight(for: titleFont)
    }

    static var titleLineSpacing: CGFloat {
        titleLineHeight * 0.5
    }

    static var titleFirstLineCenterY: CGFloat {
        titleLineHeight / 2
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
