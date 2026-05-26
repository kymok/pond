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
        case "add":
            try add(Array(arguments.dropFirst()))
        case "get":
            try get(Array(arguments.dropFirst()))
        case "set":
            try set(Array(arguments.dropFirst()))
        case "delete":
            try delete(Array(arguments.dropFirst()))
        case "-h", "--help", "help":
            printUsage()
        default:
            throw CLIError.unknownCommand(command)
        }
    }

    private static func add(_ arguments: [String]) throws {
        var parser = ArgumentScanner(arguments)
        let input = try parser.takeAddInput()
        let item = try TodoStore().add(
            title: input.title,
            collection: input.collection ?? TodoStore.defaultCollection
        )

        printItems([item])
    }

    private static func get(_ arguments: [String]) throws {
        var parser = ArgumentScanner(arguments)
        let status = parser.takeCompletionFilterIfPresent()
        let target = try parser.takeTarget(allowEmpty: true)
        let items = try TodoStore().items(
            status: status,
            collection: target.collection,
            ids: target.ids
        )

        printItems(items)
    }

    private static func set(_ arguments: [String]) throws {
        var parser = ArgumentScanner(arguments)
        let input = try parser.takeSetInput()
        let items = try TodoStore().setState(
            isDone: input.status?.isDone,
            isLocked: input.lockState?.isLocked,
            ids: input.target.ids,
            collection: input.target.collection
        )

        printItems(items)
    }

    private static func delete(_ arguments: [String]) throws {
        var parser = ArgumentScanner(arguments)
        let target = try parser.takeTarget(allowEmpty: false)
        let items = try TodoStore().delete(ids: target.ids, collection: target.collection)

        printItems(items)
    }

    private static func printItems(_ items: [TodoItem]) {
        for item in items {
            let state = item.isDone ? "done" : "undone"
            let lock = item.isLocked ? "locked" : "unlocked"
            let title = item.title
                .replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
            print("\(item.id)\t\(state)\t\(lock)\t\(item.collection)\t\(title)")
        }
    }

    private static func printUsage() {
        print(
            """
            todo add [--collection <collection>] <title...>
            todo get [done|undone] [--collection <collection> | <id...>]
            todo set <done|undone|locked|unlocked>... <--collection <collection> | <id...>>
            todo delete <--collection <collection> | <id...>>
            """
        )
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
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

private struct SetInput {
    var status: TodoCompletionFilter?
    var lockState: TodoLockState?
    var target: Target
}

private struct ArgumentScanner {
    private var arguments: [String]

    init(_ arguments: [String]) {
        self.arguments = arguments
    }

    mutating func takeCompletionFilterIfPresent() -> TodoCompletionFilter? {
        guard let first = arguments.first, let status = TodoCompletionFilter(rawValue: first) else {
            return nil
        }

        arguments.removeFirst()
        return status
    }

    mutating func takeSetInput() throws -> SetInput {
        var status: TodoCompletionFilter?
        var lockState: TodoLockState?

        while let argument = arguments.first {
            if let nextStatus = TodoCompletionFilter(rawValue: argument) {
                guard status == nil else {
                    throw CLIError.duplicateCompletionState
                }
                status = nextStatus
                arguments.removeFirst()
                continue
            }

            if let nextLockState = TodoLockState(rawValue: argument) {
                guard lockState == nil else {
                    throw CLIError.duplicateLockState
                }
                lockState = nextLockState
                arguments.removeFirst()
                continue
            }

            break
        }

        guard status != nil || lockState != nil else {
            throw CLIError.expectedSetState
        }

        return SetInput(
            status: status,
            lockState: lockState,
            target: try takeTarget(allowEmpty: false)
        )
    }

    mutating func takeAddInput() throws -> AddInput {
        var collection: String?
        var titleParts: [String] = []

        while let argument = arguments.first {
            arguments.removeFirst()

            switch argument {
            case "--":
                titleParts.append(contentsOf: arguments)
                arguments.removeAll()
            case "--collection":
                guard collection == nil else {
                    throw CLIError.duplicateCollectionFlag
                }
                guard let value = arguments.first else {
                    throw CLIError.missingCollection
                }
                arguments.removeFirst()
                collection = value
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

        return AddInput(title: titleParts.joined(separator: " "), collection: collection)
    }

    mutating func takeTarget(allowEmpty: Bool) throws -> Target {
        var collection: String?
        var ids: [String] = []

        while let argument = arguments.first {
            arguments.removeFirst()

            switch argument {
            case "--collection":
                guard collection == nil else {
                    throw CLIError.duplicateCollectionFlag
                }
                guard let value = arguments.first else {
                    throw CLIError.missingCollection
                }
                arguments.removeFirst()
                collection = value
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
}

private enum TodoLockState: String {
    case locked
    case unlocked

    var isLocked: Bool {
        self == .locked
    }
}

private enum CLIError: LocalizedError, Equatable {
    case unknownCommand(String)
    case unknownOption(String)
    case expectedSetState
    case duplicateCompletionState
    case duplicateLockState
    case missingTitle
    case missingCollection
    case duplicateCollectionFlag

    var errorDescription: String? {
        switch self {
        case .unknownCommand(let command):
            "Unknown command '\(command)'."
        case .unknownOption(let option):
            "Unknown option '\(option)'."
        case .expectedSetState:
            "Expected 'done', 'undone', 'locked', or 'unlocked'."
        case .duplicateCompletionState:
            "Completion state can only be specified once."
        case .duplicateLockState:
            "Lock state can only be specified once."
        case .missingTitle:
            "Add requires a title."
        case .missingCollection:
            "Expected a collection name after --collection."
        case .duplicateCollectionFlag:
            "--collection can only be specified once."
        }
    }
}
