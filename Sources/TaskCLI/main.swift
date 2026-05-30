import Foundation
import TaskCore

@main
struct TaskCommand {
    static func main() {
        do {
            try run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            writeError(error.localizedDescription)
            exit(1)
        }
    }

    private static func run(_ arguments: [String]) throws {
        guard let command = arguments.first else {
            printUsage()
            return
        }

        switch command {
        case "item":
            try item(Array(arguments.dropFirst()))
        case "collection":
            try collection(Array(arguments.dropFirst()))
        case "-h", "--help", "help":
            printUsage()
        default:
            throw CLIError.unknownCommand(command)
        }
    }

    private static func item(_ arguments: [String]) throws {
        guard let subcommand = arguments.first else {
            throw CLIError.expectedItemSubcommand
        }

        switch subcommand {
        case "create":
            try itemCreate(Array(arguments.dropFirst()))
        case "get":
            try itemGet(Array(arguments.dropFirst()))
        case "update":
            try itemUpdate(Array(arguments.dropFirst()))
        case "note":
            try itemNote(Array(arguments.dropFirst()))
        case "delete":
            try itemDelete(Array(arguments.dropFirst()))
        case "-h", "--help", "help":
            printUsage()
        default:
            throw CLIError.unknownItemSubcommand(subcommand)
        }
    }

    private static func collection(_ arguments: [String]) throws {
        guard let subcommand = arguments.first else {
            throw CLIError.expectedCollectionSubcommand
        }

        switch subcommand {
        case "list":
            try collectionList(Array(arguments.dropFirst()))
        case "create":
            try collectionCreate(Array(arguments.dropFirst()))
        case "rename":
            try collectionRename(Array(arguments.dropFirst()))
        case "color":
            try collectionColor(Array(arguments.dropFirst()))
        case "delete":
            try collectionDelete(Array(arguments.dropFirst()))
        case "clear":
            try collectionClear(Array(arguments.dropFirst()))
        case "-h", "--help", "help":
            printUsage()
        default:
            throw CLIError.unknownCollectionSubcommand(subcommand)
        }
    }

    private static func itemCreate(_ arguments: [String]) throws {
        var parser = ArgumentScanner(arguments)
        let input = try parser.takeCreateInput()
        let item = try TaskStore().add(
            title: input.title,
            collection: input.collection ?? TaskStore.defaultCollection
        )

        try printItems([item])
    }

    private static func itemGet(_ arguments: [String]) throws {
        var parser = ArgumentScanner(arguments)
        let input = try parser.takeGetInput()
        let items = try TaskStore().items(
            status: input.status,
            collection: input.target.collection,
            ids: input.target.ids
        )

        try printItems(items)
    }

    private static func itemUpdate(_ arguments: [String]) throws {
        var parser = ArgumentScanner(arguments)
        let input = try parser.takeUpdateInput()
        let item = try TaskStore().update(
            id: input.id,
            title: input.title,
            collection: input.collection,
            status: input.status
        )

        try printItems([item])
    }

    private static func itemNote(_ arguments: [String]) throws {
        guard let subcommand = arguments.first else {
            throw CLIError.expectedNoteSubcommand
        }

        switch subcommand {
        case "add":
            try itemNoteAdd(Array(arguments.dropFirst()))
        case "update":
            try itemNoteUpdate(Array(arguments.dropFirst()))
        case "delete":
            try itemNoteDelete(Array(arguments.dropFirst()))
        case "-h", "--help", "help":
            printUsage()
        default:
            throw CLIError.unknownNoteSubcommand(subcommand)
        }
    }

    private static func itemNoteAdd(_ arguments: [String]) throws {
        var parser = ArgumentScanner(arguments)
        let input = try parser.takeNoteAddInput()
        let item = try TaskStore().addNote(
            id: input.itemID,
            body: input.body
        )

        try printItems([item])
    }

    private static func itemNoteUpdate(_ arguments: [String]) throws {
        var parser = ArgumentScanner(arguments)
        let input = try parser.takeNoteUpdateInput()
        let item = try TaskStore().updateNote(
            id: input.itemID,
            body: input.body
        )

        try printItems([item])
    }

    private static func itemNoteDelete(_ arguments: [String]) throws {
        var parser = ArgumentScanner(arguments)
        let input = try parser.takeNoteDeleteInput()
        let item = try TaskStore().deleteNote(id: input.itemID)

        try printItems([item])
    }

    private static func itemDelete(_ arguments: [String]) throws {
        var parser = ArgumentScanner(arguments)
        let target = try parser.takeTarget(allowEmpty: false)
        let items = try TaskStore().delete(ids: target.ids, collection: target.collection)

        try printItems(items)
    }

    private static func collectionList(_ arguments: [String]) throws {
        var parser = ArgumentScanner(arguments)
        try parser.rejectRemainingArguments()
        let collections = try TaskStore().collectionSummaries()
        try printCollections(collections)
    }

    private static func collectionCreate(_ arguments: [String]) throws {
        var parser = ArgumentScanner(arguments)
        let name = try parser.takeCollectionName()
        let store = TaskStore()
        let collection = try store.createCollection(name: name)

        try printCollection(named: collection, in: store)
    }

    private static func collectionRename(_ arguments: [String]) throws {
        var parser = ArgumentScanner(arguments)
        let input = try parser.takeRenameInput()
        let store = TaskStore()
        let collection = try store.renameCollection(from: input.oldName, to: input.newName)

        try printCollection(named: collection, in: store)
    }

    private static func collectionColor(_ arguments: [String]) throws {
        var parser = ArgumentScanner(arguments)
        let input = try parser.takeColorInput()
        let collection = try TaskStore().setCollectionColor(name: input.name, color: input.color)

        try printCollections([collection])
    }

    private static func collectionDelete(_ arguments: [String]) throws {
        var parser = ArgumentScanner(arguments)
        let name = try parser.takeCollectionName()
        let store = TaskStore()
        let collection = try collectionSummary(named: name, in: store)
        _ = try store.deleteCollection(name: name)

        try printCollections([collection])
    }

    private static func collectionClear(_ arguments: [String]) throws {
        var parser = ArgumentScanner(arguments)
        let input = try parser.takeClearInput()
        let items = try TaskStore().clearItems(
            collection: input.name,
            completedOnly: input.completedOnly
        )

        try printItems(items)
    }

    private static func printItems(_ items: [TaskItem]) throws {
        try printJSON(items.map { ItemOutput(item: $0) })
    }

    private static func printCollections(_ collections: [TaskCollectionSummary]) throws {
        try printJSON(collections.map { CollectionOutput(collection: $0) })
    }

    private static func printCollection(named name: String, in store: TaskStore) throws {
        try printCollections([try collectionSummary(named: name, in: store)])
    }

    private static func collectionSummary(named name: String, in store: TaskStore) throws -> TaskCollectionSummary {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let collection = try store.collectionSummaries().first(where: { $0.name == cleanName }) else {
            throw TaskStoreError.collectionNotFound(cleanName)
        }

        return collection
    }

    private static func printUsage() {
        print(
            """
            taskpond item create [-c|--collection <collection>] <title...>
            taskpond item get [-s|--status <status>] [-c|--collection <collection> | <id...>]
            taskpond item update <id> [-c|--collection <collection>] [-s|--status <status>] [<title...>]
            taskpond item note add <id> --body <body>
            taskpond item note update <id> --body <body>
            taskpond item note delete <id>
            taskpond item delete <-c|--collection <collection> | <id...>>
            taskpond collection list
            taskpond collection create <name>
            taskpond collection rename <old-name> <new-name>
            taskpond collection color <name> <gray|red|orange|yellow|green|blue|purple>
            taskpond collection delete <name>
            taskpond collection clear <name> [--completed]
            """
        )
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let data = try PondJSON.cliEncoder.encode(value)
        guard let output = String(data: data, encoding: .utf8) else {
            return
        }

        print(output)
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

private struct ItemOutput: Encodable {
    var id: String
    var status: String
    var collection: String
    var title: String
    var note: NoteOutput?

    init(item: TaskItem) {
        id = item.id
        status = item.status.rawValue
        collection = item.collection
        title = item.title
        note = item.notes.first.map { NoteOutput(note: $0) }
    }
}

private struct NoteOutput: Encodable {
    var id: String
    var version: String
    var body: String

    init(note: TaskNote) {
        id = note.id
        version = note.version
        body = note.body
    }
}

private struct CollectionOutput: Encodable {
    var name: String
    var totalCount: Int
    var incompleteCount: Int
    var color: String
    var statusIndicator: String?

    init(collection: TaskCollectionSummary) {
        name = collection.name
        totalCount = collection.totalCount
        incompleteCount = collection.incompleteCount
        color = collection.color.rawValue
        statusIndicator = collection.statusIndicator?.rawValue
    }
}

private struct Target {
    var collection: String?
    var ids: [String]
}

private struct AddInput {
    var title: String
    var collection: String?
}

private struct GetInput {
    var status: TaskStatus?
    var target: Target
}

private struct UpdateInput {
    var id: String
    var title: String?
    var collection: String?
    var status: TaskStatus?
}

private struct NoteAddInput {
    var itemID: String
    var body: String
}

private struct NoteUpdateInput {
    var itemID: String
    var body: String?
}

private struct NoteDeleteInput {
    var itemID: String
}

private struct RenameInput {
    var oldName: String
    var newName: String
}

private struct ColorInput {
    var name: String
    var color: TaskCollectionColor
}

private struct ClearInput {
    var name: String
    var completedOnly: Bool
}

private struct ArgumentScanner {
    private var arguments: [String]

    init(_ arguments: [String]) {
        self.arguments = arguments
    }

    mutating func takeGetInput() throws -> GetInput {
        var status: TaskStatus?
        var collection: String?
        var ids: [String] = []

        while let argument = arguments.first {
            arguments.removeFirst()

            switch argument {
            case "-s", "--status":
                try setStatusFlag(&status)
            case "--collection", "-c":
                try setCollectionFlag(&collection)
            default:
                if argument.hasPrefix("-") {
                    throw CLIError.unknownOption(argument)
                }
                ids.append(argument)
            }
        }

        if collection != nil && !ids.isEmpty {
            throw TaskStoreError.targetConflict
        }

        return GetInput(status: status, target: Target(collection: collection, ids: ids))
    }

    mutating func takeUpdateInput() throws -> UpdateInput {
        guard let id = arguments.first else {
            throw TaskStoreError.missingTarget
        }
        arguments.removeFirst()

        var collection: String?
        var status: TaskStatus?
        var titleParts: [String] = []

        while let argument = arguments.first {
            arguments.removeFirst()

            switch argument {
            case "--":
                titleParts.append(contentsOf: arguments)
                arguments.removeAll()
            case "--collection", "-c":
                try setCollectionFlag(&collection)
            case "--status", "-s":
                try setStatusFlag(&status)
            default:
                if argument.hasPrefix("-") {
                    throw CLIError.unknownOption(argument)
                }
                titleParts.append(argument)
            }
        }

        let title = titleParts.isEmpty ? nil : titleParts.joined(separator: " ").cliUnescaped
        guard title != nil || collection != nil || status != nil else {
            throw TaskStoreError.missingUpdate
        }

        return UpdateInput(id: id, title: title, collection: collection, status: status)
    }

    mutating func takeNoteAddInput() throws -> NoteAddInput {
        guard let itemID = arguments.first else {
            throw TaskStoreError.missingTarget
        }
        arguments.removeFirst()

        let body = try takeNoteFields(allowPartial: false)
        return NoteAddInput(
            itemID: itemID,
            body: try requireNoteField(body, missing: .missingNoteBody)
        )
    }

    mutating func takeNoteUpdateInput() throws -> NoteUpdateInput {
        guard let itemID = arguments.first else {
            throw TaskStoreError.missingTarget
        }
        arguments.removeFirst()

        let body = try takeNoteFields(allowPartial: true)
        return NoteUpdateInput(itemID: itemID, body: body)
    }

    mutating func takeNoteDeleteInput() throws -> NoteDeleteInput {
        guard let itemID = arguments.first else {
            throw TaskStoreError.missingTarget
        }
        arguments.removeFirst()

        try rejectRemainingArguments()
        return NoteDeleteInput(itemID: itemID)
    }

    mutating func takeCreateInput() throws -> AddInput {
        var collection: String?
        var titleParts: [String] = []

        while let argument = arguments.first {
            arguments.removeFirst()

            switch argument {
            case "--":
                titleParts.append(contentsOf: arguments)
                arguments.removeAll()
            case "--collection", "-c":
                try setCollectionFlag(&collection)
            default:
                if argument.hasPrefix("-") {
                    throw CLIError.unknownOption(argument)
                }
                titleParts.append(argument)
            }
        }

        guard !titleParts.isEmpty else {
            throw CLIError.missingTitle
        }

        return AddInput(title: titleParts.joined(separator: " ").cliUnescaped, collection: collection)
    }

    mutating func takeTarget(allowEmpty: Bool) throws -> Target {
        var collection: String?
        var ids: [String] = []

        while let argument = arguments.first {
            arguments.removeFirst()

            switch argument {
            case "--collection", "-c":
                try setCollectionFlag(&collection)
            default:
                if argument.hasPrefix("-") {
                    throw CLIError.unknownOption(argument)
                }
                ids.append(argument)
            }
        }

        if collection != nil && !ids.isEmpty {
            throw TaskStoreError.targetConflict
        }

        if !allowEmpty && collection == nil && ids.isEmpty {
            throw TaskStoreError.missingTarget
        }

        return Target(collection: collection, ids: ids)
    }

    mutating func takeCollectionName() throws -> String {
        guard let name = arguments.first else {
            throw CLIError.expectedCollectionName
        }

        arguments.removeFirst()
        try rejectRemainingArguments()
        return name.cliUnescaped
    }

    mutating func takeRenameInput() throws -> RenameInput {
        guard let oldName = arguments.first else {
            throw CLIError.expectedCollectionName
        }
        arguments.removeFirst()

        guard let newName = arguments.first else {
            throw CLIError.expectedCollectionName
        }
        arguments.removeFirst()

        try rejectRemainingArguments()
        return RenameInput(oldName: oldName.cliUnescaped, newName: newName.cliUnescaped)
    }

    mutating func takeColorInput() throws -> ColorInput {
        guard let name = arguments.first else {
            throw CLIError.expectedCollectionName
        }
        arguments.removeFirst()

        guard let colorValue = arguments.first else {
            throw CLIError.missingCollectionColor
        }
        arguments.removeFirst()

        guard let color = TaskCollectionColor(rawValue: colorValue) else {
            throw CLIError.expectedCollectionColor
        }

        try rejectRemainingArguments()
        return ColorInput(name: name.cliUnescaped, color: color)
    }

    mutating func takeClearInput() throws -> ClearInput {
        guard let name = arguments.first else {
            throw CLIError.expectedCollectionName
        }
        arguments.removeFirst()

        var completedOnly = false
        while let argument = arguments.first {
            arguments.removeFirst()

            switch argument {
            case "--completed":
                guard !completedOnly else {
                    throw CLIError.duplicateCompletedOnly
                }
                completedOnly = true
            default:
                if argument.hasPrefix("-") {
                    throw CLIError.unknownOption(argument)
                }
                throw CLIError.unexpectedArgument(argument)
            }
        }

        return ClearInput(name: name.cliUnescaped, completedOnly: completedOnly)
    }

    mutating func rejectRemainingArguments() throws {
        guard let argument = arguments.first else {
            return
        }

        if argument.hasPrefix("-") {
            throw CLIError.unknownOption(argument)
        }

        throw CLIError.unexpectedArgument(argument)
    }

    private mutating func takeRequiredCollection() throws -> String {
        guard let value = arguments.first else {
            throw CLIError.missingCollection
        }

        arguments.removeFirst()
        return value
    }

    private mutating func takeRequiredStatus() throws -> TaskStatus {
        guard let value = arguments.first,
              let status = TaskStatus(rawValue: value) else {
            throw CLIError.expectedSetState
        }

        arguments.removeFirst()
        return status
    }

    private mutating func setCollectionFlag(_ collection: inout String?) throws {
        guard collection == nil else {
            throw CLIError.duplicateCollectionFlag
        }
        collection = try takeRequiredCollection()
    }

    private mutating func setStatusFlag(_ status: inout TaskStatus?) throws {
        guard status == nil else {
            throw CLIError.duplicateStatus
        }
        status = try takeRequiredStatus()
    }

    private mutating func takeNoteFields(allowPartial: Bool) throws -> String? {
        var body: String?

        while let argument = arguments.first {
            arguments.removeFirst()

            switch argument {
            case "--body":
                guard body == nil else {
                    throw CLIError.duplicateNoteBody
                }
                body = try takeRequiredNoteValue(missing: .missingNoteBody)
            default:
                if argument.hasPrefix("-") {
                    throw CLIError.unknownOption(argument)
                }
                throw CLIError.unexpectedArgument(argument)
            }
        }

        if allowPartial, body == nil {
            throw TaskStoreError.missingNoteUpdate
        }

        return body
    }

    private mutating func takeRequiredNoteValue(missing error: CLIError) throws -> String {
        guard let value = arguments.first else {
            throw error
        }

        arguments.removeFirst()
        return value.cliUnescaped
    }

    private func requireNoteField(_ field: String?, missing error: CLIError) throws -> String {
        guard let field else {
            throw error
        }

        return field
    }
}

private extension String {
    var cliUnescaped: String {
        var result = ""
        var isEscaping = false

        for character in self {
            if isEscaping {
                switch character {
                case "n":
                    result += "\n"
                case "r":
                    result += "\r"
                case "t":
                    result += "\t"
                case "\\":
                    result += "\\"
                default:
                    result += "\\"
                    result.append(character)
                }

                isEscaping = false
            } else if character == "\\" {
                isEscaping = true
            } else {
                result.append(character)
            }
        }

        if isEscaping {
            result += "\\"
        }

        return result
    }
}

private enum CLIError: LocalizedError, Equatable {
    case unknownCommand(String)
    case expectedItemSubcommand
    case unknownItemSubcommand(String)
    case expectedNoteSubcommand
    case unknownNoteSubcommand(String)
    case expectedCollectionSubcommand
    case unknownCollectionSubcommand(String)
    case unknownOption(String)
    case expectedSetState
    case expectedCollectionColor
    case duplicateStatus
    case missingNoteBody
    case duplicateNoteBody
    case unexpectedArgument(String)
    case missingTitle
    case missingCollection
    case expectedCollectionName
    case missingCollectionColor
    case duplicateCollectionFlag
    case duplicateCompletedOnly

    var errorDescription: String? {
        switch self {
        case .unknownCommand(let command):
            "Unknown command '\(command)'."
        case .expectedItemSubcommand:
            "Expected item subcommand 'create', 'get', 'update', 'note', or 'delete'."
        case .unknownItemSubcommand(let subcommand):
            "Unknown item subcommand '\(subcommand)'."
        case .expectedNoteSubcommand:
            "Expected note subcommand 'add', 'update', or 'delete'."
        case .unknownNoteSubcommand(let subcommand):
            "Unknown note subcommand '\(subcommand)'."
        case .expectedCollectionSubcommand:
            "Expected collection subcommand 'list', 'create', 'rename', 'color', 'delete', or 'clear'."
        case .unknownCollectionSubcommand(let subcommand):
            "Unknown collection subcommand '\(subcommand)'."
        case .unknownOption(let option):
            "Unknown option '\(option)'."
        case .expectedSetState:
            "Expected 'ready', 'draft', 'in-progress', 'completed', 'on-hold', 'aborted', or 'rejected'."
        case .expectedCollectionColor:
            "Expected 'gray', 'red', 'orange', 'yellow', 'green', 'blue', or 'purple'."
        case .duplicateStatus:
            "Task status can only be specified once."
        case .missingNoteBody:
            "Expected a note body after --body."
        case .duplicateNoteBody:
            "--body can only be specified once."
        case .unexpectedArgument(let argument):
            "Unexpected argument '\(argument)'."
        case .missingTitle:
            "Create requires a title."
        case .missingCollection:
            "Expected a collection name after --collection or -c."
        case .expectedCollectionName:
            "Expected a collection name."
        case .missingCollectionColor:
            "Expected a collection color."
        case .duplicateCollectionFlag:
            "--collection or -c can only be specified once."
        case .duplicateCompletedOnly:
            "--completed can only be specified once."
        }
    }
}
