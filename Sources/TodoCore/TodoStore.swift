import Darwin
import Foundation

public enum TodoStoreError: LocalizedError, Equatable {
    case invalidTitle
    case invalidCollection
    case invalidID(String)
    case missingTarget
    case missingUpdate
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
        case .missingTarget:
            "Command requires --collection or at least one id."
        case .missingUpdate:
            "Update requires a title, --collection, --status/-s, or --priority."
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
        if let override = ProcessInfo.processInfo.environment["POND_STORE"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }

        return appSupportDirectory()
            .appendingPathComponent("todos.json", isDirectory: false)
    }

    public static func appSupportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pond", isDirectory: true)
    }

    public func items(
        status: TodoStatus? = nil,
        priority: TodoPriority? = nil,
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
                results = results.filter { $0.status == status }
            }

            if let priority {
                results = results.filter { $0.priority == priority }
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
                        incompleteCount: items.filter(\.status.isIncomplete).count,
                        statusIndicator: collectionStatusIndicator(for: items),
                        color: collectionColor(name, in: file),
                        isArchived: file.archivedCollections.contains(name)
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

            let newNameHadColor = file.collectionColors[cleanNewName] != nil
            let oldColor = file.collectionColors.removeValue(forKey: cleanOldName)
            let shouldArchiveNewName = file.archivedCollections.remove(cleanOldName) != nil
                || file.archivedCollections.contains(cleanNewName)
            let now = Date()
            for index in file.items.indices where file.items[index].collection == cleanOldName {
                file.items[index].collection = cleanNewName
                markItemUpdated(at: index, in: &file, now: now)
            }

            file.collections.removeAll { $0 == cleanOldName }
            addCollectionIfMissing(cleanNewName, to: &file)
            if !newNameHadColor {
                file.collectionColors[cleanNewName] = oldColor ?? .gray
            }
            if shouldArchiveNewName {
                file.archivedCollections.insert(cleanNewName)
            }
            return cleanNewName
        }
    }

    @discardableResult
    public func setCollectionColor(name: String, color: TodoCollectionColor) throws -> TodoCollectionSummary {
        let cleanName = try normalizedExplicitCollection(name)

        return try withFile(write: true) { file in
            guard collectionExists(cleanName, in: file) else {
                throw TodoStoreError.collectionNotFound(cleanName)
            }

            addCollectionIfMissing(cleanName, to: &file)
            file.collectionColors[cleanName] = color

            let items = file.items.filter { $0.collection == cleanName }
            return TodoCollectionSummary(
                name: cleanName,
                totalCount: items.count,
                incompleteCount: items.filter(\.status.isIncomplete).count,
                statusIndicator: collectionStatusIndicator(for: items),
                color: color,
                isArchived: file.archivedCollections.contains(cleanName)
            )
        }
    }

    @discardableResult
    public func setCollectionArchived(name: String, isArchived: Bool) throws -> TodoCollectionSummary {
        let cleanName = try normalizedExplicitCollection(name)

        return try withFile(write: true) { file in
            guard collectionExists(cleanName, in: file) else {
                throw TodoStoreError.collectionNotFound(cleanName)
            }

            addCollectionIfMissing(cleanName, to: &file)
            if isArchived {
                file.archivedCollections.insert(cleanName)
            } else {
                file.archivedCollections.remove(cleanName)
            }

            let items = file.items.filter { $0.collection == cleanName }
            return TodoCollectionSummary(
                name: cleanName,
                totalCount: items.count,
                incompleteCount: items.filter(\.status.isIncomplete).count,
                statusIndicator: collectionStatusIndicator(for: items),
                color: collectionColor(cleanName, in: file),
                isArchived: isArchived
            )
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
            file.collectionColors.removeValue(forKey: cleanName)
            file.archivedCollections.remove(cleanName)
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
            file.collectionColors.removeValue(forKey: cleanName)
            file.archivedCollections.remove(cleanName)
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
        allowEmptyTitle: Bool = false,
        status: TodoStatus = .ready,
        priority: TodoPriority = .normal
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
                priority: priority,
                status: status,
                createdAt: now,
                updatedAt: now
            )
            file.items.append(item)
            addCollectionIfMissing(item.collection, to: &file)
            return item
        }
    }

    @discardableResult
    public func updateTitle(
        id: String,
        title: String,
        statusAfterEdit: TodoStatus? = .draft
    ) throws -> TodoItem {
        try update(id: id, title: title, status: statusAfterEdit)
    }

    @discardableResult
    public func updateTitle(
        id: String,
        title: String,
        ifCurrent expectedItem: TodoItem,
        statusAfterEdit: TodoStatus? = .draft
    ) throws -> TodoItem? {
        try update(id: id, title: title, status: statusAfterEdit, ifCurrent: expectedItem)
    }

    @discardableResult
    public func assign(id: String, assignees: [String]) throws -> TodoItem {
        try update(id: id, assignees: assignees)
    }

    @discardableResult
    public func assign(id: String, assignees: [String], ifCurrent expectedItem: TodoItem) throws -> TodoItem? {
        try update(id: id, assignees: assignees, ifCurrent: expectedItem)
    }

    @discardableResult
    public func setPriority(_ priority: TodoPriority, id: String, ifCurrent expectedItem: TodoItem) throws -> TodoItem? {
        try update(id: id, priority: priority, ifCurrent: expectedItem)
    }

    @discardableResult
    public func update(
        id: String,
        title: String? = nil,
        collection: String? = nil,
        status: TodoStatus? = nil,
        priority: TodoPriority? = nil,
        assignees: [String]? = nil
    ) throws -> TodoItem {
        let cleanTitle = title.map(normalizedExistingTitle)
        let cleanCollection = collection.map(normalizedCollection)
        guard cleanTitle != nil || cleanCollection != nil || status != nil || priority != nil || assignees != nil else {
            throw TodoStoreError.missingUpdate
        }

        return try withFile(write: true) { file in
            let index = try resolveIndex(id, in: file.items)
            if applyUpdate(
                title: cleanTitle,
                collection: cleanCollection,
                status: status,
                priority: priority,
                assignees: assignees,
                to: index,
                in: &file
            ) {
                markItemUpdated(at: index, in: &file)
            }

            return file.items[index]
        }
    }

    @discardableResult
    public func update(
        id: String,
        title: String? = nil,
        collection: String? = nil,
        status: TodoStatus? = nil,
        priority: TodoPriority? = nil,
        assignees: [String]? = nil,
        ifCurrent expectedItem: TodoItem
    ) throws -> TodoItem? {
        let cleanTitle = title.map(normalizedExistingTitle)
        let cleanCollection = collection.map(normalizedCollection)
        guard cleanTitle != nil || cleanCollection != nil || status != nil || priority != nil || assignees != nil else {
            throw TodoStoreError.missingUpdate
        }

        return try withFile(write: true) { file in
            let index = try resolveIndex(id, in: file.items)
            guard file.items[index] == expectedItem else {
                return nil
            }

            if applyUpdate(
                title: cleanTitle,
                collection: cleanCollection,
                status: status,
                priority: priority,
                assignees: assignees,
                to: index,
                in: &file
            ) {
                markItemUpdated(at: index, in: &file)
            }

            return file.items[index]
        }
    }

    @discardableResult
    public func move(id: String, collection: String) throws -> TodoItem {
        try withFile(write: true) { file in
            let index = try resolveIndex(id, in: file.items)
            let cleanCollection = normalizedCollection(collection)
            addCollectionIfMissing(cleanCollection, to: &file)
            if file.items[index].collection != cleanCollection {
                file.items[index].collection = cleanCollection
                markItemUpdated(at: index, in: &file)
            }
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
            markItemUpdated(at: index, in: &file)
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
    public func clearItems(collection: String, completedOnly: Bool = false) throws -> [TodoItem] {
        let cleanCollection = try normalizedExplicitCollection(collection)

        return try withFile(write: true) { file in
            let indexes = file.items.indices.filter { index in
                let item = file.items[index]
                return item.collection == cleanCollection
                    && (!completedOnly || item.status == .completed)
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
    public func setStatus(
        _ status: TodoStatus,
        ids: [String] = [],
        collection: String? = nil
    ) throws -> [TodoItem] {
        let cleanCollection = try targetCollection(ids: ids, collection: collection)

        return try withFile(write: true) { file in
            let indexes = try resolveTargetIndexes(ids: ids, collection: cleanCollection, in: file)
            let now = Date()
            for index in indexes {
                guard file.items[index].status != status else {
                    continue
                }

                file.items[index].status = status
                markItemUpdated(at: index, in: &file, now: now)
            }

            return indexes.map { file.items[$0] }
        }
    }

    @discardableResult
    public func setStatuses(
        _ replacements: [TodoStatus: TodoStatus],
        ids: [String] = [],
        collection: String? = nil
    ) throws -> [TodoItem] {
        let cleanCollection = try targetCollection(ids: ids, collection: collection)
        let meaningfulReplacements = replacements.filter { oldStatus, newStatus in
            oldStatus != newStatus
        }

        return try withFile(write: true) { file in
            let targetIndexes = try resolveTargetIndexes(ids: ids, collection: cleanCollection, in: file)
            let indexes = targetIndexes.filter { meaningfulReplacements[file.items[$0].status] != nil }
            guard !indexes.isEmpty else {
                return []
            }

            let now = Date()
            for index in indexes {
                guard let replacement = meaningfulReplacements[file.items[index].status] else {
                    continue
                }

                file.items[index].status = replacement
                markItemUpdated(at: index, in: &file, now: now)
            }

            return indexes.map { file.items[$0] }
        }
    }

    @discardableResult
    public func setPriority(
        _ priority: TodoPriority,
        ids: [String] = [],
        collection: String? = nil
    ) throws -> [TodoItem] {
        let cleanCollection = try targetCollection(ids: ids, collection: collection)

        return try withFile(write: true) { file in
            let indexes = try resolveTargetIndexes(ids: ids, collection: cleanCollection, in: file)
            let now = Date()
            for index in indexes {
                guard file.items[index].priority != priority else {
                    continue
                }

                file.items[index].priority = priority
                markItemUpdated(at: index, in: &file, now: now)
            }

            return indexes.map { file.items[$0] }
        }
    }

    @discardableResult
    public func setStatus(_ status: TodoStatus, id: String, ifCurrent expectedItem: TodoItem) throws -> TodoItem? {
        try updateItem(id: id, ifCurrent: expectedItem) { item in
            guard item.status != status else {
                return false
            }

            item.status = status
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
        let needsMigration = file.needsMigration
        let result = try body(&file)

        if write || needsMigration {
            file.needsMigration = false
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
                markItemUpdated(at: index, in: &file)
            }

            return file.items[index]
        }
    }

    private func markItemUpdated(at index: Int, in file: inout TodoFile, now: Date = Date()) {
        file.items[index].updatedAt = now
        refreshVersion(at: index, in: &file.items)
    }

    private func refreshVersion(at index: Int, in items: inout [TodoItem]) {
        var existingVersions = Set(items.map(\.version))
        existingVersions.remove(items[index].version)
        items[index].version = TodoItem.makeVersion(existing: existingVersions)
    }

    private func applyUpdate(
        title: String?,
        collection: String?,
        status: TodoStatus?,
        priority: TodoPriority?,
        assignees: [String]?,
        to index: Int,
        in file: inout TodoFile
    ) -> Bool {
        var changed = false

        if let title, file.items[index].title != title {
            file.items[index].title = title
            changed = true
        }

        if let collection {
            addCollectionIfMissing(collection, to: &file)
            if file.items[index].collection != collection {
                file.items[index].collection = collection
                changed = true
            }
        }

        if let status, file.items[index].status != status {
            file.items[index].status = status
            changed = true
        }

        if let priority, file.items[index].priority != priority {
            file.items[index].priority = priority
            changed = true
        }

        if let assignees {
            let cleanAssignees = normalizedAssignees(assignees)
            if file.items[index].assignees != cleanAssignees {
                file.items[index].assignees = cleanAssignees
                changed = true
            }
        }

        return changed
    }

    private func targetCollection(ids: [String], collection: String?) throws -> String? {
        let cleanCollection: String?
        if let collection {
            cleanCollection = try normalizedExplicitCollection(collection)
        } else {
            cleanCollection = nil
        }

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
    var version = 5
    var collections: [String] = []
    var collectionColors: [String: TodoCollectionColor] = [:]
    var archivedCollections: Set<String> = []
    var items: [TodoItem] = []
    var needsMigration = false

    private enum CodingKeys: String, CodingKey {
        case version
        case collections
        case collectionColors
        case archivedCollections
        case items
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let itemVersionProbes = try container.decodeIfPresent([TodoItemVersionProbe].self, forKey: .items) ?? []
        items = try container.decodeIfPresent([TodoItem].self, forKey: .items) ?? []
        needsMigration = itemVersionProbes.contains { $0.version?.isEmpty ?? true }
        collections = normalizedCollectionList(
            (try container.decodeIfPresent([String].self, forKey: .collections) ?? [])
                + items.map(\.collection)
        )
        let rawColors = try container.decodeIfPresent([String: String].self, forKey: .collectionColors) ?? [:]
        collectionColors = normalizedCollectionColors(
            rawColors.compactMapValues { TodoCollectionColor(rawValue: $0) },
            collections: collections
        )
        let rawArchivedCollections = try container.decodeIfPresent([String].self, forKey: .archivedCollections) ?? []
        archivedCollections = Set(normalizedCollectionList(rawArchivedCollections).filter { collections.contains($0) })
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let collectionNames = normalizedCollectionList(collections + items.map(\.collection))
        try container.encode(5, forKey: .version)
        try container.encode(collectionNames, forKey: .collections)
        try container.encode(
            normalizedCollectionColors(collectionColors, collections: collectionNames),
            forKey: .collectionColors
        )
        try container.encode(
            sortedCollectionNames(archivedCollections.filter { collectionNames.contains($0) }),
            forKey: .archivedCollections
        )
        try container.encode(items, forKey: .items)
    }
}

private struct TodoItemVersionProbe: Decodable {
    var version: String?

    private enum CodingKeys: String, CodingKey {
        case version
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
}

private func normalizedAssignees(_ assignees: [String]) -> [String] {
    var seen: Set<String> = []
    return assignees.compactMap { assignee in
        let clean = assignee.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, seen.insert(clean).inserted else {
            return nil
        }

        return clean
    }
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
    let names = normalizedCollectionList(collections)
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

    return names.filter { $0 == TodoStore.defaultCollection }
        + names.filter { $0 != TodoStore.defaultCollection }
}

private func addCollectionIfMissing(_ collection: String, to file: inout TodoFile) {
    let cleanCollection = normalizedCollection(collection)
    file.collections = normalizedCollectionList(file.collections + [cleanCollection])
    if file.collectionColors[cleanCollection] == nil {
        file.collectionColors[cleanCollection] = .gray
    }
}

private func collectionStatusIndicator(for items: [TodoItem]) -> TodoStatus? {
    if items.contains(where: { $0.status == .aborted }) {
        return .aborted
    }

    if items.contains(where: { $0.status == .onHold }) {
        return .onHold
    }

    return nil
}

private func collectionExists(_ collection: String, in file: TodoFile) -> Bool {
    file.collections.contains(collection)
        || file.items.contains { $0.collection == collection }
}

private func collectionColor(_ collection: String, in file: TodoFile) -> TodoCollectionColor {
    file.collectionColors[collection] ?? .gray
}

private func normalizedCollectionColors(
    _ colors: [String: TodoCollectionColor],
    collections: [String]
) -> [String: TodoCollectionColor] {
    let names = normalizedCollectionList(collections)
    let nameSet = Set(names)
    var result: [String: TodoCollectionColor] = [:]

    for (name, color) in colors {
        let cleanName = normalizedCollection(name)
        guard nameSet.contains(cleanName), result[cleanName] == nil else {
            continue
        }

        result[cleanName] = color
    }

    for name in names where result[name] == nil {
        result[name] = .gray
    }

    return result
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
