import Darwin
import Foundation

public enum TodoStoreError: LocalizedError, Equatable {
    case invalidTitle
    case invalidCollection
    case invalidID(String)
    case missingState
    case missingTarget
    case targetConflict
    case noMatchingTodos
    case notFound(String)
    case collectionNotFound(String)
    case ambiguousID(String, [String])
    case duplicateID(String)
    case fileLockFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidTitle:
            "Todo title cannot be empty."
        case .invalidCollection:
            "Collection name cannot be empty."
        case .invalidID(let id):
            "Todo id '\(id)' is invalid."
        case .missingState:
            "At least one todo state is required."
        case .missingTarget:
            "Command requires --collection or at least one id."
        case .targetConflict:
            "Use either --collection or ids, not both."
        case .noMatchingTodos:
            "No matching todos."
        case .notFound(let id):
            "No todo matches '\(id)'."
        case .collectionNotFound(let name):
            "No collection matches '\(name)'."
        case .ambiguousID(let id, let matches):
            "Todo id '\(id)' is ambiguous: \(matches.joined(separator: ", "))."
        case .duplicateID(let id):
            "Todo id '\(id)' already exists."
        case .fileLockFailed(let reason):
            "Could not lock todo store: \(reason)"
        }
    }
}

public final class TodoStore: @unchecked Sendable {
    public static let defaultCollection = "Inbox"

    public let fileURL: URL

    private let lockURL: URL

    public init(fileURL: URL = TodoStore.defaultStoreURL()) {
        self.fileURL = fileURL
        self.lockURL = fileURL.appendingPathExtension("lock")
    }

    public static func makeID(existing: Set<String> = []) -> String {
        var id: String

        repeat {
            id = UUID().uuidString
                .replacingOccurrences(of: "-", with: "")
                .prefix(8)
                .lowercased()
        } while existing.contains(id)

        return id
    }

    public static func defaultStoreURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["SMOL_TODO_STORE"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }

        return appSupportDirectory()
            .appendingPathComponent("todos.json", isDirectory: false)
    }

    public static func appSupportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SmolTodo", isDirectory: true)
    }

    public func items(
        status: TodoCompletionFilter? = nil,
        collection: String? = nil,
        ids: [String] = [],
        search: String? = nil
    ) throws -> [TodoItem] {
        try withFile(write: false) { file in
            var results: [TodoItem]

            if ids.isEmpty {
                results = file.items
            } else {
                let indexes = try ids.map { try resolveIndex($0, in: file.items) }
                results = indexes.map { file.items[$0] }
            }

            if let status {
                results = results.filter { $0.isDone == status.isDone }
            }

            if let collection = normalizedCollectionOrNil(collection) {
                results = results.filter { $0.collection == collection }
            }

            if let query = normalizedSearchOrNil(search) {
                results = results.filter {
                    $0.title.localizedCaseInsensitiveContains(query)
                        || $0.collection.localizedCaseInsensitiveContains(query)
                        || $0.id.localizedCaseInsensitiveContains(query)
                }
            }

            return results
        }
    }

    public func collectionSummaries() throws -> [TodoCollectionSummary] {
        try withFile(write: false) { file in
            let grouped = Dictionary(grouping: file.items, by: \.collection)

            return sortedCollectionNames(file.collections + grouped.keys)
                .map { name in
                    let items = grouped[name] ?? []
                    return TodoCollectionSummary(
                        name: name,
                        totalCount: items.count,
                        undoneCount: items.filter { !$0.isDone }.count
                    )
                }
        }
    }

    @discardableResult
    public func createCollection(name: String) throws -> String {
        let cleanName = try normalizedExplicitCollection(name)

        return try withFile(write: true) { file in
            addCollectionIfMissing(cleanName, to: &file)
            return cleanName
        }
    }

    @discardableResult
    public func renameCollection(from oldName: String, to newName: String) throws -> String {
        let cleanOldName = try normalizedExplicitCollection(oldName)
        let cleanNewName = try normalizedExplicitCollection(newName)

        return try withFile(write: true) { file in
            guard collectionExists(cleanOldName, in: file) else {
                throw TodoStoreError.collectionNotFound(cleanOldName)
            }

            guard cleanOldName != cleanNewName else {
                addCollectionIfMissing(cleanNewName, to: &file)
                return cleanNewName
            }

            let now = Date()
            for index in file.items.indices where file.items[index].collection == cleanOldName {
                file.items[index].collection = cleanNewName
                file.items[index].updatedAt = now
            }

            file.collections.removeAll { $0 == cleanOldName }
            addCollectionIfMissing(cleanNewName, to: &file)
            return cleanNewName
        }
    }

    @discardableResult
    public func deleteEmptyCollection(name: String) throws -> Bool {
        let cleanName = try normalizedExplicitCollection(name)

        return try withFile(write: true) { file in
            guard !file.items.contains(where: { $0.collection == cleanName }) else {
                return false
            }

            let originalCount = file.collections.count
            file.collections.removeAll { $0 == cleanName }
            return file.collections.count != originalCount
        }
    }

    @discardableResult
    public func deleteCollection(name: String) throws -> Bool {
        let cleanName = try normalizedExplicitCollection(name)

        return try withFile(write: true) { file in
            guard collectionExists(cleanName, in: file) else {
                throw TodoStoreError.collectionNotFound(cleanName)
            }

            let originalCollectionCount = file.collections.count
            let originalItemCount = file.items.count
            file.collections.removeAll { $0 == cleanName }
            file.items.removeAll { $0.collection == cleanName }
            return file.collections.count != originalCollectionCount
                || file.items.count != originalItemCount
        }
    }

    @discardableResult
    public func add(
        title: String,
        collection: String = TodoStore.defaultCollection,
        id requestedID: String? = nil,
        allowEmptyTitle: Bool = false
    ) throws -> TodoItem {
        let cleanTitle = allowEmptyTitle ? normalizedExistingTitle(title) : normalizedNewTitle(title)
        guard allowEmptyTitle || !cleanTitle.isEmpty else {
            throw TodoStoreError.invalidTitle
        }

        return try withFile(write: true) { file in
            let now = Date()
            let existingIDs = Set(file.items.map(\.id))
            let id = requestedID ?? Self.makeID(existing: existingIDs)
            guard isValidID(id) else {
                throw TodoStoreError.invalidID(id)
            }
            guard !existingIDs.contains(id) else {
                throw TodoStoreError.duplicateID(id)
            }

            let item = TodoItem(
                id: id,
                title: cleanTitle,
                collection: normalizedCollection(collection),
                createdAt: now,
                updatedAt: now
            )
            file.items.append(item)
            addCollectionIfMissing(item.collection, to: &file)
            return item
        }
    }

    @discardableResult
    public func updateTitle(id: String, title: String) throws -> TodoItem {
        return try withFile(write: true) { file in
            let index = try resolveIndex(id, in: file.items)
            file.items[index].title = normalizedExistingTitle(title)
            file.items[index].updatedAt = Date()
            return file.items[index]
        }
    }

    @discardableResult
    public func updateTitle(id: String, title: String, ifCurrent expectedItem: TodoItem) throws -> TodoItem? {
        let cleanTitle = normalizedExistingTitle(title)
        return try updateItem(id: id, ifCurrent: expectedItem) { item in
            guard item.title != cleanTitle else {
                return false
            }

            item.title = cleanTitle
            return true
        }
    }

    @discardableResult
    public func move(id: String, collection: String) throws -> TodoItem {
        try withFile(write: true) { file in
            let index = try resolveIndex(id, in: file.items)
            let cleanCollection = normalizedCollection(collection)
            file.items[index].collection = cleanCollection
            file.items[index].updatedAt = Date()
            addCollectionIfMissing(cleanCollection, to: &file)
            return file.items[index]
        }
    }

    @discardableResult
    public func move(id: String, collection: String, ifCurrent expectedItem: TodoItem) throws -> TodoItem? {
        let cleanCollection = normalizedCollection(collection)
        return try withFile(write: true) { file in
            let index = try resolveIndex(id, in: file.items)
            guard file.items[index] == expectedItem else {
                return nil
            }

            guard file.items[index].collection != cleanCollection else {
                addCollectionIfMissing(cleanCollection, to: &file)
                return file.items[index]
            }

            file.items[index].collection = cleanCollection
            file.items[index].updatedAt = Date()
            addCollectionIfMissing(cleanCollection, to: &file)
            return file.items[index]
        }
    }

    public func delete(id: String) throws {
        try withFile(write: true) { file in
            let index = try resolveIndex(id, in: file.items)
            file.items.remove(at: index)
        }
    }

    @discardableResult
    public func delete(ids: [String] = [], collection: String? = nil) throws -> [TodoItem] {
        let cleanCollection = try targetCollection(ids: ids, collection: collection)

        return try withFile(write: true) { file in
            let indexes = try resolveTargetIndexes(ids: ids, collection: cleanCollection, in: file)
            let deletedItems = indexes.map { file.items[$0] }

            for index in indexes.reversed() {
                file.items.remove(at: index)
            }

            return deletedItems
        }
    }

    @discardableResult
    public func clearUnlockedItems(collection: String, doneOnly: Bool = false) throws -> [TodoItem] {
        let cleanCollection = try normalizedExplicitCollection(collection)

        return try withFile(write: true) { file in
            let indexes = file.items.indices.filter { index in
                let item = file.items[index]
                return item.collection == cleanCollection
                    && !item.isLocked
                    && (!doneOnly || item.isDone)
            }

            guard !indexes.isEmpty else {
                throw TodoStoreError.noMatchingTodos
            }

            let deletedItems = indexes.map { file.items[$0] }
            for index in indexes.reversed() {
                file.items.remove(at: index)
            }

            return deletedItems
        }
    }

    @discardableResult
    public func delete(id: String, ifCurrent expectedItem: TodoItem) throws -> Bool {
        try withFile(write: true) { file in
            let index = try resolveIndex(id, in: file.items)
            guard file.items[index] == expectedItem else {
                return false
            }

            file.items.remove(at: index)
            return true
        }
    }

    @discardableResult
    public func setCompletion(isDone: Bool, ids: [String] = [], collection: String? = nil) throws -> [TodoItem] {
        try setState(isDone: isDone, ids: ids, collection: collection)
    }

    @discardableResult
    public func setCompletion(isDone: Bool, id: String, ifCurrent expectedItem: TodoItem) throws -> TodoItem? {
        try updateItem(id: id, ifCurrent: expectedItem) { item in
            guard item.isDone != isDone else {
                return false
            }

            item.isDone = isDone
            return true
        }
    }

    @discardableResult
    public func setLock(isLocked: Bool, ids: [String] = [], collection: String? = nil) throws -> [TodoItem] {
        try setState(isLocked: isLocked, ids: ids, collection: collection)
    }

    @discardableResult
    public func setState(
        isDone: Bool? = nil,
        isLocked: Bool? = nil,
        ids: [String] = [],
        collection: String? = nil
    ) throws -> [TodoItem] {
        guard isDone != nil || isLocked != nil else {
            throw TodoStoreError.missingState
        }

        let cleanCollection = try targetCollection(ids: ids, collection: collection)

        return try withFile(write: true) { file in
            let indexes = try resolveTargetIndexes(ids: ids, collection: cleanCollection, in: file)
            let now = Date()
            for index in indexes {
                if let isDone {
                    file.items[index].isDone = isDone
                }
                if let isLocked {
                    file.items[index].isLocked = isLocked
                }
                file.items[index].updatedAt = now
            }

            return indexes.map { file.items[$0] }
        }
    }

    @discardableResult
    public func setLock(isLocked: Bool, id: String, ifCurrent expectedItem: TodoItem) throws -> TodoItem? {
        try updateItem(id: id, ifCurrent: expectedItem) { item in
            guard item.isLocked != isLocked else {
                return false
            }

            item.isLocked = isLocked
            return true
        }
    }

    @discardableResult
    public func reorder(id: String, after previousID: String?, before nextID: String?) throws -> TodoItem {
        try withFile(write: true) { file in
            let sourceIndex = try resolveIndex(id, in: file.items)
            let item = file.items.remove(at: sourceIndex)

            if let previousID, previousID != id {
                let previousIndex = try resolveIndex(previousID, in: file.items)
                file.items.insert(item, at: previousIndex + 1)
            } else if let nextID, nextID != id {
                let nextIndex = try resolveIndex(nextID, in: file.items)
                file.items.insert(item, at: nextIndex)
            } else {
                file.items.append(item)
            }

            return item
        }
    }

    private func withFile<T>(write: Bool, _ body: (inout TodoFile) throws -> T) throws -> T {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw TodoStoreError.fileLockFailed(currentErrnoMessage())
        }
        defer {
            _ = Darwin.close(descriptor)
        }

        guard flock(descriptor, LOCK_EX) == 0 else {
            throw TodoStoreError.fileLockFailed(currentErrnoMessage())
        }

        var file = try readFile()
        let result = try body(&file)

        if write {
            try writeFile(file)
        }

        return result
    }

    private func updateItem(
        id: String,
        ifCurrent expectedItem: TodoItem,
        _ update: (inout TodoItem) throws -> Bool
    ) throws -> TodoItem? {
        try withFile(write: true) { file in
            let index = try resolveIndex(id, in: file.items)
            guard file.items[index] == expectedItem else {
                return nil
            }

            if try update(&file.items[index]) {
                file.items[index].updatedAt = Date()
            }

            return file.items[index]
        }
    }

    private func targetCollection(ids: [String], collection: String?) throws -> String? {
        let cleanCollection = normalizedCollectionOrNil(collection)

        if ids.isEmpty && cleanCollection == nil {
            throw TodoStoreError.missingTarget
        }

        if !ids.isEmpty && cleanCollection != nil {
            throw TodoStoreError.targetConflict
        }

        return cleanCollection
    }

    private func resolveTargetIndexes(ids: [String], collection cleanCollection: String?, in file: TodoFile) throws -> [Int] {
        let indexes: [Int]
        if let cleanCollection {
            indexes = file.items.indices.filter { file.items[$0].collection == cleanCollection }
        } else {
            indexes = try ids.map { try resolveIndex($0, in: file.items) }
        }

        let uniqueIndexes = Array(Set(indexes)).sorted()
        guard !uniqueIndexes.isEmpty else {
            throw TodoStoreError.noMatchingTodos
        }

        return uniqueIndexes
    }

    private func readFile() throws -> TodoFile {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return TodoFile()
        }

        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else {
            return TodoFile()
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TodoFile.self, from: data)
    }

    private func writeFile(_ file: TodoFile) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(file)
        try data.write(to: fileURL, options: .atomic)
    }
}

private struct TodoFile: Codable {
    var version = 2
    var collections: [String] = []
    var items: [TodoItem] = []

    private enum CodingKeys: String, CodingKey {
        case version
        case collections
        case items
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([TodoItem].self, forKey: .items) ?? []
        collections = normalizedCollectionList(
            (try container.decodeIfPresent([String].self, forKey: .collections) ?? [])
                + items.map(\.collection)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(2, forKey: .version)
        try container.encode(normalizedCollectionList(collections + items.map(\.collection)), forKey: .collections)
        try container.encode(items, forKey: .items)
    }
}

private func resolveIndex(_ id: String, in items: [TodoItem]) throws -> Int {
    if let exact = items.firstIndex(where: { $0.id == id }) {
        return exact
    }

    let matches = items.enumerated().filter { $0.element.id.hasPrefix(id) }
    guard !matches.isEmpty else {
        throw TodoStoreError.notFound(id)
    }

    guard matches.count == 1, let match = matches.first else {
        throw TodoStoreError.ambiguousID(id, matches.map(\.element.id))
    }

    return match.offset
}

private let idCharacters = Set("0123456789abcdef")

private func isValidID(_ id: String) -> Bool {
    id.count == 8 && id.allSatisfy(idCharacters.contains)
}

private func normalizedNewTitle(_ title: String) -> String {
    normalizedExistingTitle(title).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func normalizedExistingTitle(_ title: String) -> String {
    title
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\t", with: " ")
}

private func normalizedCollection(_ collection: String) -> String {
    let clean = collection.trimmingCharacters(in: .whitespacesAndNewlines)
    return clean.isEmpty ? TodoStore.defaultCollection : clean
}

private func normalizedExplicitCollection(_ collection: String) throws -> String {
    let clean = collection.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else {
        throw TodoStoreError.invalidCollection
    }

    return clean
}

private func normalizedCollectionOrNil(_ collection: String?) -> String? {
    guard let collection else {
        return nil
    }

    let clean = normalizedCollection(collection)
    return clean.isEmpty ? nil : clean
}

private func normalizedCollectionList<S: Sequence>(_ collections: S) -> [String] where S.Element == String {
    var seen: Set<String> = []
    var result: [String] = []

    for collection in collections {
        let clean = normalizedCollection(collection)
        guard !seen.contains(clean) else {
            continue
        }

        seen.insert(clean)
        result.append(clean)
    }

    return result
}

private func sortedCollectionNames<S: Sequence>(_ collections: S) -> [String] where S.Element == String {
    normalizedCollectionList(collections)
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
}

private func addCollectionIfMissing(_ collection: String, to file: inout TodoFile) {
    file.collections = normalizedCollectionList(file.collections + [collection])
}

private func collectionExists(_ collection: String, in file: TodoFile) -> Bool {
    file.collections.contains(collection)
        || file.items.contains { $0.collection == collection }
}

private func normalizedSearchOrNil(_ search: String?) -> String? {
    guard let search else {
        return nil
    }

    let clean = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return clean.isEmpty ? nil : clean
}

private func currentErrnoMessage() -> String {
    String(cString: strerror(errno))
}
