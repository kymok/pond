import Foundation
import TodoCore

@main
struct TodoCommand {
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
        case "assign":
            try itemAssign(Array(arguments.dropFirst()))
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
        let item = try TodoStore().add(
            title: input.title,
            collection: input.collection ?? TodoStore.defaultCollection
        )

        try printItems([item])
    }

    private static func itemGet(_ arguments: [String]) throws {
        var parser = ArgumentScanner(arguments)
        let input = try parser.takeGetInput()
        let items = try TodoStore().items(
            status: input.status,
            priority: input.priority,
            collection: input.target.collection,
            ids: input.target.ids
        )

        try printItems(items)
    }

    private static func itemUpdate(_ arguments: [String]) throws {
        var parser = ArgumentScanner(arguments)
        let input = try parser.takeUpdateInput()
        let item = try TodoStore().update(
            id: input.id,
            title: input.title,
            collection: input.collection,
            status: input.status,
            priority: input.priority
        )

        try printItems([item])
    }

    private static func itemAssign(_ arguments: [String]) throws {
        var parser = ArgumentScanner(arguments)
        let input = try parser.takeAssignInput()
        let item = try TodoStore().assign(
            id: input.id,
            assignees: input.assignees
        )

        try printItems([item])
    }

    private static func itemDelete(_ arguments: [String]) throws {
        var parser = ArgumentScanner(arguments)
        let target = try parser.takeTarget(allowEmpty: false)
        let items = try TodoStore().delete(ids: target.ids, collection: target.collection)

        try printItems(items)
    }

    private static func collectionList(_ arguments: [String]) throws {
        var parser = ArgumentScanner(arguments)
        try parser.rejectRemainingArguments()
        let collections = try TodoStore().collectionSummaries()
        try printCollections(collections)
    }

    private static func collectionCreate(_ arguments: [String]) throws {
        var parser = ArgumentScanner(arguments)
        let name = try parser.takeCollectionName()
        let store = TodoStore()
        let collection = try store.createCollection(name: name)

        try printCollection(named: collection, in: store)
    }

    private static func collectionRename(_ arguments: [String]) throws {
        var parser = ArgumentScanner(arguments)
        let input = try parser.takeRenameInput()
        let store = TodoStore()
        let collection = try store.renameCollection(from: input.oldName, to: input.newName)

        try printCollection(named: collection, in: store)
    }

    private static func collectionColor(_ arguments: [String]) throws {
        var parser = ArgumentScanner(arguments)
        let input = try parser.takeColorInput()
        let collection = try TodoStore().setCollectionColor(name: input.name, color: input.color)

        try printCollections([collection])
    }

    private static func collectionDelete(_ arguments: [String]) throws {
        var parser = ArgumentScanner(arguments)
        let name = try parser.takeCollectionName()
        let store = TodoStore()
        let collection = try collectionSummary(named: name, in: store)
        _ = try store.deleteCollection(name: name)

        try printCollections([collection])
    }

    private static func collectionClear(_ arguments: [String]) throws {
        var parser = ArgumentScanner(arguments)
        let input = try parser.takeClearInput()
        let items = try TodoStore().clearItems(
            collection: input.name,
            completedOnly: input.completedOnly
        )

        try printItems(items)
    }

    private static func printItems(_ items: [TodoItem]) throws {
        try printJSON(items.map { ItemOutput(item: $0) })
    }

    private static func printCollections(_ collections: [TodoCollectionSummary]) throws {
        try printJSON(collections.map { CollectionOutput(collection: $0) })
    }

    private static func printCollection(named name: String, in store: TodoStore) throws {
        try printCollections([try collectionSummary(named: name, in: store)])
    }

    private static func collectionSummary(named name: String, in store: TodoStore) throws -> TodoCollectionSummary {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let collection = try store.collectionSummaries().first(where: { $0.name == cleanName }) else {
            throw TodoStoreError.collectionNotFound(cleanName)
        }

        return collection
    }

    private static func printUsage() {
        print(
            """
            taskpond item create [-c|--collection <collection>] <title...>
            taskpond item get [-s|--status <status>] [--priority <priority>] [-c|--collection <collection> | <id...>]
            taskpond item update <id> [-c|--collection <collection>] [-s|--status <status>] [--priority <priority>] [<title...>]
            taskpond item assign <id> (--assignee <assignee> ... | --unassign)
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
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
    var priority: String
    var assignees: [String]

    init(item: TodoItem) {
        id = item.id
        status = item.status.rawValue
        collection = item.collection
        title = item.title
        priority = item.priority.rawValue
        assignees = item.assignees
    }
}

private struct CollectionOutput: Encodable {
    var name: String
    var totalCount: Int
    var incompleteCount: Int
    var color: String
    var statusIndicator: String?

    init(collection: TodoCollectionSummary) {
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
    var status: TodoStatus?
    var priority: TodoPriority?
    var target: Target
}

private struct UpdateInput {
    var id: String
    var title: String?
    var collection: String?
    var status: TodoStatus?
    var priority: TodoPriority?
}

private struct AssignInput {
    var id: String
    var assignees: [String]
}

private struct RenameInput {
    var oldName: String
    var newName: String
}

private struct ColorInput {
    var name: String
    var color: TodoCollectionColor
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
        var status: TodoStatus?
        var priority: TodoPriority?
        var collection: String?
        var ids: [String] = []

        while let argument = arguments.first {
            arguments.removeFirst()

            switch argument {
            case "-s", "--status":
                guard status == nil else {
                    throw CLIError.duplicateStatus
                }
                status = try takeRequiredStatus()
            case "--priority":
                guard priority == nil else {
                    throw CLIError.duplicatePriority
                }
                priority = try takeRequiredPriority()
            case "--collection", "-c":
                guard collection == nil else {
                    throw CLIError.duplicateCollectionFlag
                }
                collection = try takeRequiredCollection()
            default:
                if argument.hasPrefix("-") {
                    throw CLIError.unknownOption(argument)
                }
                ids.append(argument)
            }
        }

        if collection != nil && !ids.isEmpty {
            throw TodoStoreError.targetConflict
        }

        return GetInput(status: status, priority: priority, target: Target(collection: collection, ids: ids))
    }

    mutating func takeUpdateInput() throws -> UpdateInput {
        guard let id = arguments.first else {
            throw TodoStoreError.missingTarget
        }
        arguments.removeFirst()

        var collection: String?
        var status: TodoStatus?
        var priority: TodoPriority?
        var titleParts: [String] = []

        while let argument = arguments.first {
            arguments.removeFirst()

            switch argument {
            case "--":
                titleParts.append(contentsOf: arguments)
                arguments.removeAll()
            case "--collection", "-c":
                guard collection == nil else {
                    throw CLIError.duplicateCollectionFlag
                }
                guard let value = arguments.first else {
                    throw CLIError.missingCollection
                }
                arguments.removeFirst()
                collection = value
            case "--status", "-s":
                guard status == nil else {
                    throw CLIError.duplicateStatus
                }
                status = try takeRequiredStatus()
            case "--priority":
                guard priority == nil else {
                    throw CLIError.duplicatePriority
                }
                priority = try takeRequiredPriority()
            default:
                if argument.hasPrefix("-") {
                    throw CLIError.unknownOption(argument)
                }
                titleParts.append(argument)
            }
        }

        let title = titleParts.isEmpty ? nil : titleParts.joined(separator: " ").cliUnescaped
        guard title != nil || collection != nil || status != nil || priority != nil else {
            throw TodoStoreError.missingUpdate
        }

        return UpdateInput(id: id, title: title, collection: collection, status: status, priority: priority)
    }

    mutating func takeAssignInput() throws -> AssignInput {
        guard let id = arguments.first else {
            throw TodoStoreError.missingTarget
        }
        arguments.removeFirst()

        var assignees: [String]?
        var unassigns = false

        while let argument = arguments.first {
            arguments.removeFirst()

            switch argument {
            case "--assignee":
                guard !unassigns else {
                    throw CLIError.assigneeConflict
                }
                assignees = (assignees ?? []) + [try takeRequiredAssignee()]
            case "--unassign":
                guard !unassigns else {
                    throw CLIError.duplicateUnassign
                }
                guard assignees == nil else {
                    throw CLIError.assigneeConflict
                }
                unassigns = true
                assignees = []
            default:
                if argument.hasPrefix("-") {
                    throw CLIError.unknownOption(argument)
                }
                throw CLIError.unexpectedArgument(argument)
            }
        }

        guard let assignees else {
            throw CLIError.missingAssignment
        }

        return AssignInput(id: id, assignees: assignees)
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
                guard collection == nil else {
                    throw CLIError.duplicateCollectionFlag
                }
                collection = try takeRequiredCollection()
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
                guard collection == nil else {
                    throw CLIError.duplicateCollectionFlag
                }
                collection = try takeRequiredCollection()
            default:
                if argument.hasPrefix("-") {
                    throw CLIError.unknownOption(argument)
                }
                ids.append(argument)
            }
        }

        if collection != nil && !ids.isEmpty {
            throw TodoStoreError.targetConflict
        }

        if !allowEmpty && collection == nil && ids.isEmpty {
            throw TodoStoreError.missingTarget
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

        guard let color = TodoCollectionColor(rawValue: colorValue) else {
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

    private mutating func takeRequiredStatus() throws -> TodoStatus {
        guard let value = arguments.first,
              let status = TodoStatus(rawValue: value) else {
            throw CLIError.expectedSetState
        }

        arguments.removeFirst()
        return status
    }

    private mutating func takeRequiredPriority() throws -> TodoPriority {
        guard let value = arguments.first,
              let priority = TodoPriority(rawValue: value) else {
            throw CLIError.expectedPriority
        }

        arguments.removeFirst()
        return priority
    }

    private mutating func takeRequiredAssignee() throws -> String {
        guard let value = arguments.first else {
            throw CLIError.missingAssignee
        }

        arguments.removeFirst()
        guard !value.cliUnescaped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError.emptyAssignee
        }

        return value.cliUnescaped
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
    case expectedCollectionSubcommand
    case unknownCollectionSubcommand(String)
    case unknownOption(String)
    case expectedSetState
    case expectedPriority
    case expectedCollectionColor
    case duplicateStatus
    case duplicatePriority
    case missingAssignee
    case emptyAssignee
    case duplicateUnassign
    case assigneeConflict
    case missingAssignment
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
            "Expected item subcommand 'create', 'get', 'update', 'assign', or 'delete'."
        case .unknownItemSubcommand(let subcommand):
            "Unknown item subcommand '\(subcommand)'."
        case .expectedCollectionSubcommand:
            "Expected collection subcommand 'list', 'create', 'rename', 'color', 'delete', or 'clear'."
        case .unknownCollectionSubcommand(let subcommand):
            "Unknown collection subcommand '\(subcommand)'."
        case .unknownOption(let option):
            "Unknown option '\(option)'."
        case .expectedSetState:
            "Expected 'ready', 'draft', 'in-progress', 'completed', 'on-hold', or 'aborted'."
        case .expectedPriority:
            "Expected 'normal' or 'prioritized'."
        case .expectedCollectionColor:
            "Expected 'gray', 'red', 'orange', 'yellow', 'green', 'blue', or 'purple'."
        case .duplicateStatus:
            "Todo status can only be specified once."
        case .duplicatePriority:
            "Todo priority can only be specified once."
        case .missingAssignee:
            "Expected an assignee after --assignee."
        case .emptyAssignee:
            "Assignee cannot be empty. Use --unassign to clear assignees."
        case .duplicateUnassign:
            "--unassign can only be specified once."
        case .assigneeConflict:
            "Use either --assignee or --unassign, not both."
        case .missingAssignment:
            "Assign requires --assignee or --unassign."
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
