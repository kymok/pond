import Darwin
import Foundation

public enum TaskStoreError: LocalizedError, Equatable {
    case invalidTitle
    case invalidCollection
    case invalidCollectionGroup
    case defaultCollection
    case defaultCollectionGroup
    case invalidID(String)
    case missingTarget
    case missingUpdate
    case missingNoteUpdate
    case targetConflict
    case noMatchingTasks
    case notFound(String)
    case noteNotFound(String)
    case collectionNotFound(String)
    case collectionGroupNotFound(String)
    case collectionConflict(String)
    case ambiguousID(String, [String])
    case duplicateID(String)
    case invalidNote
    case fileLockFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidTitle:
            "Task title cannot be empty."
        case .invalidCollection:
            "Collection name cannot be empty."
        case .invalidCollectionGroup:
            "Collection group name cannot be empty."
        case .defaultCollection:
            "Default collection cannot be renamed, deleted, or moved."
        case .defaultCollectionGroup:
            "Default collection group cannot be renamed or deleted."
        case .invalidID(let id):
            "Task id '\(id)' is invalid."
        case .missingTarget:
            "Command requires --collection or at least one id."
        case .missingUpdate:
            "Update requires a title, --collection, or --status/-s."
        case .missingNoteUpdate:
            "Note update requires --body."
        case .targetConflict:
            "Use either --collection or ids, not both."
        case .noMatchingTasks:
            "No matching tasks."
        case .notFound(let id):
            "No task matches '\(id)'."
        case .noteNotFound(let id):
            "No note matches '\(id)'."
        case .collectionNotFound(let name):
            "No collection matches '\(name)'."
        case .collectionGroupNotFound(let name):
            "No collection group matches '\(name)'."
        case .collectionConflict(let name):
            "Collection '\(name)' already exists."
        case .ambiguousID(let id, let matches):
            "Task id '\(id)' is ambiguous: \(matches.joined(separator: ", "))."
        case .duplicateID(let id):
            "Task id '\(id)' already exists."
        case .invalidNote:
            "Note body cannot be empty."
        case .fileLockFailed(let reason):
            "Could not lock task store: \(reason)"
        }
    }
}

public final class TaskStore: @unchecked Sendable {
    public static let defaultCollection = "DefaultCollection"
    public static let defaultCollectionGroup = "DefaultGroup"

    public let fileURL: URL

    private let lockURL: URL

    public init(fileURL: URL = TaskStore.defaultStoreURL()) {
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
            .appendingPathComponent("tasks.json", isDirectory: false)
    }

    public static func appSupportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pond", isDirectory: true)
    }

    public func items(
        status: TaskStatus? = nil,
        collection: String? = nil,
        ids: [String] = [],
        search: String? = nil
    ) throws -> [TaskItem] {
        let cleanCollection = try normalizedCollectionOrNil(collection)

        return try withFile(write: false) { file in
            var results: [TaskItem]

            if ids.isEmpty {
                results = file.items
            } else {
                let indexes = try ids.map { try resolveIndex($0, in: file.items) }
                results = indexes.map { file.items[$0] }
            }

            if let status {
                results = results.filter { $0.status == status }
            }

            if let cleanCollection {
                results = results.filter { $0.collection == cleanCollection }
            }

            if let query = normalizedSearchOrNil(search) {
                results = results.filter {
                    $0.title.localizedCaseInsensitiveContains(query)
                        || $0.collection.localizedCaseInsensitiveContains(query)
                        || $0.id.localizedCaseInsensitiveContains(query)
                        || $0.notes.contains { $0.body.localizedCaseInsensitiveContains(query) }
                }
            }

            return results
        }
    }

    public func collectionSummaries() throws -> [TaskCollectionSummary] {
        try withFile(write: false) { file in
            makeCollectionSummaries(in: file)
        }
    }

    public func collectionGroupSummaries() throws -> [TaskCollectionGroupSummary] {
        try withFile(write: false) { file in
            makeCollectionGroupSummaries(in: file)
        }
    }

    @discardableResult
    public func createCollectionGroup(name: String) throws -> String {
        let cleanName = try normalizedExplicitCollectionGroup(name)

        return try withFile(write: true) { file in
            addCollectionGroupIfMissing(cleanName, to: &file)
            return cleanName
        }
    }

    @discardableResult
    public func renameCollectionGroup(from oldName: String, to newName: String) throws -> String {
        let cleanOldName = try normalizedExplicitCollectionGroup(oldName)
        let cleanNewName = try normalizedExplicitCollectionGroup(newName)

        guard cleanOldName != Self.defaultCollectionGroup else {
            throw TaskStoreError.defaultCollectionGroup
        }

        return try withFile(write: true) { file in
            normalizeCollectionGroups(in: &file)
            guard let oldIndex = file.collectionGroups.firstIndex(where: { $0.name == cleanOldName }) else {
                throw TaskStoreError.collectionGroupNotFound(cleanOldName)
            }

            guard cleanOldName != cleanNewName else {
                return cleanNewName
            }

            let movedCollections = file.collectionGroups[oldIndex].collections
            try assertCanMoveCollections(movedCollections, toGroup: cleanNewName, in: file)
            for collection in movedCollections {
                try renameCollectionReference(
                    from: collection,
                    to: collectionAPIName(
                        groupName: cleanNewName,
                        displayName: collectionDisplayName(collection)
                    ),
                    in: &file
                )
            }

            if let currentOldIndex = file.collectionGroups.firstIndex(where: { $0.name == cleanOldName }) {
                file.collectionGroups.remove(at: currentOldIndex)
            }
            if file.collectionGroups.contains(where: { $0.name == cleanNewName }) {
                normalizeCollectionGroups(in: &file)
            } else {
                addCollectionGroupIfMissing(cleanNewName, to: &file)
            }

            normalizeCollectionGroups(in: &file)
            return cleanNewName
        }
    }

    @discardableResult
    public func deleteCollectionGroup(name: String) throws -> Bool {
        let cleanName = try normalizedExplicitCollectionGroup(name)

        guard cleanName != Self.defaultCollectionGroup else {
            throw TaskStoreError.defaultCollectionGroup
        }

        return try withFile(write: true) { file in
            normalizeCollectionGroups(in: &file)
            guard let index = file.collectionGroups.firstIndex(where: { $0.name == cleanName }) else {
                throw TaskStoreError.collectionGroupNotFound(cleanName)
            }

            let collections = file.collectionGroups[index].collections
            try assertCanMoveCollections(collections, toGroup: Self.defaultCollectionGroup, in: file)
            file.collectionGroups.remove(at: index)
            for collection in collections {
                try renameCollectionReference(
                    from: collection,
                    to: collectionAPIName(
                        groupName: Self.defaultCollectionGroup,
                        displayName: collectionDisplayName(collection)
                    ),
                    in: &file
                )
            }
            normalizeCollectionGroups(in: &file)
            return true
        }
    }

    @discardableResult
    public func createCollection(name: String, group: String = TaskStore.defaultCollectionGroup) throws -> String {
        let collection = try normalizedCollectionReference(name, defaultGroup: group)

        return try withFile(write: true) { file in
            try addCollectionIfMissing(collection.apiName, group: collection.groupName, to: &file)
            return collection.apiName
        }
    }

    @discardableResult
    public func moveCollection(name: String, toGroup group: String) throws -> TaskCollectionSummary {
        let cleanName = try normalizedExplicitCollection(name)
        let cleanGroup = try normalizedExplicitCollectionGroup(group)

        guard cleanName != Self.defaultCollection else {
            throw TaskStoreError.defaultCollection
        }

        return try withFile(write: true) { file in
            guard collectionExists(cleanName, in: file) else {
                throw TaskStoreError.collectionNotFound(cleanName)
            }

            let newName = collectionAPIName(groupName: cleanGroup, displayName: collectionDisplayName(cleanName))
            if cleanName != newName {
                guard !collectionExists(newName, in: file) else {
                    throw TaskStoreError.collectionConflict(newName)
                }
                try renameCollectionReference(from: cleanName, to: newName, in: &file)
            } else {
                try moveCollectionInFile(cleanName, toGroup: cleanGroup, in: &file)
            }
            return collectionSummary(named: newName, in: file)
        }
    }

    @discardableResult
    public func renameCollection(from oldName: String, to newName: String) throws -> String {
        let cleanOldName = try normalizedExplicitCollection(oldName)

        guard cleanOldName != Self.defaultCollection else {
            throw TaskStoreError.defaultCollection
        }

        return try withFile(write: true) { file in
            guard collectionExists(cleanOldName, in: file) else {
                throw TaskStoreError.collectionNotFound(cleanOldName)
            }

            let oldGroup = collectionGroupName(containing: cleanOldName, in: file)
                ?? collectionGroupName(forCollectionAPIName: cleanOldName)
            let target = try normalizedCollectionReference(newName, defaultGroup: oldGroup)
            let cleanNewName = target.apiName

            guard cleanOldName != cleanNewName else {
                try addCollectionIfMissing(cleanNewName, group: target.groupName, to: &file)
                return cleanNewName
            }

            guard !collectionExists(cleanNewName, in: file) else {
                throw TaskStoreError.collectionConflict(cleanNewName)
            }
            try renameCollectionReference(from: cleanOldName, to: cleanNewName, in: &file)
            return cleanNewName
        }
    }

    @discardableResult
    public func setCollectionColor(name: String, color: TaskCollectionColor) throws -> TaskCollectionSummary {
        let cleanName = try normalizedExplicitCollection(name)

        return try withFile(write: true) { file in
            guard collectionExists(cleanName, in: file) else {
                throw TaskStoreError.collectionNotFound(cleanName)
            }

            try addCollectionIfMissing(cleanName, to: &file)
            file.collectionColors[cleanName] = color

            return collectionSummary(named: cleanName, in: file)
        }
    }

    @discardableResult
    public func setCollectionArchived(name: String, isArchived: Bool) throws -> TaskCollectionSummary {
        let cleanName = try normalizedExplicitCollection(name)

        return try withFile(write: true) { file in
            guard collectionExists(cleanName, in: file) else {
                throw TaskStoreError.collectionNotFound(cleanName)
            }

            try addCollectionIfMissing(cleanName, to: &file)
            if isArchived {
                file.archivedCollections.insert(cleanName)
            } else {
                file.archivedCollections.remove(cleanName)
            }

            return collectionSummary(named: cleanName, in: file)
        }
    }

    @discardableResult
    public func setCollectionPrompt(name: String, promptTemplate: String?) throws -> TaskCollectionSummary {
        let cleanName = try normalizedExplicitCollection(name)
        let cleanPrompt = normalizedPromptTemplateOrNil(promptTemplate)

        return try withFile(write: true) { file in
            guard collectionExists(cleanName, in: file) else {
                throw TaskStoreError.collectionNotFound(cleanName)
            }

            try addCollectionIfMissing(cleanName, to: &file)
            if let cleanPrompt {
                file.collectionPrompts[cleanName] = cleanPrompt
            } else {
                file.collectionPrompts.removeValue(forKey: cleanName)
            }

            return collectionSummary(named: cleanName, in: file)
        }
    }

    @discardableResult
    public func deleteEmptyCollection(name: String) throws -> Bool {
        let cleanName = try normalizedExplicitCollection(name)

        guard cleanName != Self.defaultCollection else {
            throw TaskStoreError.defaultCollection
        }

        return try withFile(write: true) { file in
            guard !file.items.contains(where: { $0.collection == cleanName }) else {
                return false
            }

            let originalCount = file.collections.count
            file.collections.removeAll { $0 == cleanName }
            file.collectionColors.removeValue(forKey: cleanName)
            file.collectionPrompts.removeValue(forKey: cleanName)
            file.archivedCollections.remove(cleanName)
            removeCollectionFromGroups(cleanName, in: &file)
            return file.collections.count != originalCount
        }
    }

    @discardableResult
    public func deleteCollection(name: String) throws -> Bool {
        let cleanName = try normalizedExplicitCollection(name)

        guard cleanName != Self.defaultCollection else {
            throw TaskStoreError.defaultCollection
        }

        return try withFile(write: true) { file in
            guard collectionExists(cleanName, in: file) else {
                throw TaskStoreError.collectionNotFound(cleanName)
            }

            let originalCollectionCount = file.collections.count
            let originalItemCount = file.items.count
            file.collections.removeAll { $0 == cleanName }
            file.collectionColors.removeValue(forKey: cleanName)
            file.collectionPrompts.removeValue(forKey: cleanName)
            file.archivedCollections.remove(cleanName)
            removeCollectionFromGroups(cleanName, in: &file)
            file.items.removeAll { $0.collection == cleanName }
            return file.collections.count != originalCollectionCount
                || file.items.count != originalItemCount
        }
    }

    @discardableResult
    public func add(
        title: String,
        collection: String = TaskStore.defaultCollection,
        id requestedID: String? = nil,
        allowEmptyTitle: Bool = false,
        status: TaskStatus = .ready
    ) throws -> TaskItem {
        let cleanTitle = allowEmptyTitle ? normalizedExistingTitle(title) : normalizedNewTitle(title)
        let cleanCollection = try normalizedCollection(collection)
        guard allowEmptyTitle || !cleanTitle.isEmpty else {
            throw TaskStoreError.invalidTitle
        }

        return try withFile(write: true) { file in
            let now = Date()
            let existingIDs = Set(file.items.map(\.id))
            let id = requestedID ?? Self.makeID(existing: existingIDs)
            guard isValidID(id) else {
                throw TaskStoreError.invalidID(id)
            }
            guard !existingIDs.contains(id) else {
                throw TaskStoreError.duplicateID(id)
            }

            let item = TaskItem(
                id: id,
                title: cleanTitle,
                collection: cleanCollection,
                status: status,
                createdAt: now,
                updatedAt: now
            )
            file.items.append(item)
            try addCollectionIfMissing(item.collection, to: &file)
            return item
        }
    }

    @discardableResult
    public func updateTitle(
        id: String,
        title: String,
        statusAfterEdit: TaskStatus? = .draft
    ) throws -> TaskItem {
        try update(id: id, title: title, status: statusAfterEdit)
    }

    @discardableResult
    public func updateTitle(
        id: String,
        title: String,
        ifCurrent expectedItem: TaskItem,
        statusAfterEdit: TaskStatus? = .draft
    ) throws -> TaskItem? {
        try update(id: id, title: title, status: statusAfterEdit, ifCurrent: expectedItem)
    }

    @discardableResult
    public func addNote(
        id: String,
        body: String
    ) throws -> TaskItem {
        let input = try normalizedNoteInput(body: body)

        return try withFile(write: true) { file in
            let index = try resolveIndex(id, in: file.items)
            addNote(input, to: index, in: &file)
            return file.items[index]
        }
    }

    @discardableResult
    public func addNote(
        id: String,
        body: String,
        ifCurrent expectedItem: TaskItem
    ) throws -> TaskItem? {
        let input = try normalizedNoteInput(body: body)

        return try updateItem(id: id, ifCurrent: expectedItem) { item in
            appendNote(input, to: &item)
            return true
        }
    }

    @discardableResult
    public func updateNote(
        id: String,
        noteID: String,
        body: String? = nil
    ) throws -> TaskItem {
        let input = try normalizedNoteUpdate(body: body)

        return try withFile(write: true) { file in
            let index = try resolveIndex(id, in: file.items)
            if try applyNoteUpdate(input, noteID: noteID, to: &file.items[index]) {
                markItemUpdated(at: index, in: &file)
            }
            return file.items[index]
        }
    }

    @discardableResult
    public func updateNote(id: String, body: String? = nil) throws -> TaskItem {
        let input = try normalizedNoteUpdate(body: body)

        return try withFile(write: true) { file in
            let index = try resolveIndex(id, in: file.items)
            guard file.items[index].notes.first != nil else {
                throw TaskStoreError.noteNotFound(id)
            }

            if applyNoteUpdate(input, to: &file.items[index]) {
                markItemUpdated(at: index, in: &file)
            }
            return file.items[index]
        }
    }

    @discardableResult
    public func updateNote(
        id: String,
        noteID: String,
        body: String? = nil,
        ifCurrent expectedItem: TaskItem
    ) throws -> TaskItem? {
        let input = try normalizedNoteUpdate(body: body)

        return try updateItem(id: id, ifCurrent: expectedItem) { item in
            try applyNoteUpdate(input, noteID: noteID, to: &item)
        }
    }

    @discardableResult
    public func deleteNote(id: String, noteID: String) throws -> TaskItem {
        return try withFile(write: true) { file in
            let index = try resolveIndex(id, in: file.items)
            try removeNote(noteID: noteID, from: &file.items[index])
            markItemUpdated(at: index, in: &file)
            return file.items[index]
        }
    }

    @discardableResult
    public func deleteNote(id: String) throws -> TaskItem {
        return try withFile(write: true) { file in
            let index = try resolveIndex(id, in: file.items)
            guard !file.items[index].notes.isEmpty else {
                throw TaskStoreError.noteNotFound(id)
            }

            file.items[index].notes.removeAll()
            markItemUpdated(at: index, in: &file)
            return file.items[index]
        }
    }

    @discardableResult
    public func deleteNote(
        id: String,
        noteID: String,
        ifCurrent expectedItem: TaskItem
    ) throws -> TaskItem? {
        try updateItem(id: id, ifCurrent: expectedItem) { item in
            try removeNote(noteID: noteID, from: &item)
            return true
        }
    }

    @discardableResult
    public func update(
        id: String,
        title: String? = nil,
        collection: String? = nil,
        status: TaskStatus? = nil
    ) throws -> TaskItem {
        let cleanTitle = title.map(normalizedExistingTitle)
        let cleanCollection = try collection.map { try normalizedCollection($0) }
        guard cleanTitle != nil || cleanCollection != nil || status != nil else {
            throw TaskStoreError.missingUpdate
        }

        return try withFile(write: true) { file in
            let index = try resolveIndex(id, in: file.items)
            if try applyUpdate(
                title: cleanTitle,
                collection: cleanCollection,
                status: status,
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
        status: TaskStatus? = nil,
        ifCurrent expectedItem: TaskItem
    ) throws -> TaskItem? {
        let cleanTitle = title.map(normalizedExistingTitle)
        let cleanCollection = try collection.map { try normalizedCollection($0) }
        guard cleanTitle != nil || cleanCollection != nil || status != nil else {
            throw TaskStoreError.missingUpdate
        }

        return try withFile(write: true) { file in
            let index = try resolveIndex(id, in: file.items)
            guard file.items[index] == expectedItem else {
                return nil
            }

            if try applyUpdate(
                title: cleanTitle,
                collection: cleanCollection,
                status: status,
                to: index,
                in: &file
            ) {
                markItemUpdated(at: index, in: &file)
            }

            return file.items[index]
        }
    }

    @discardableResult
    public func move(id: String, collection: String) throws -> TaskItem {
        let cleanCollection = try normalizedCollection(collection)

        return try withFile(write: true) { file in
            let index = try resolveIndex(id, in: file.items)
            try addCollectionIfMissing(cleanCollection, to: &file)
            if file.items[index].collection != cleanCollection {
                file.items[index].collection = cleanCollection
                markItemUpdated(at: index, in: &file)
            }
            return file.items[index]
        }
    }

    @discardableResult
    public func move(id: String, collection: String, ifCurrent expectedItem: TaskItem) throws -> TaskItem? {
        let cleanCollection = try normalizedCollection(collection)
        return try withFile(write: true) { file in
            let index = try resolveIndex(id, in: file.items)
            guard file.items[index] == expectedItem else {
                return nil
            }

            guard file.items[index].collection != cleanCollection else {
                try addCollectionIfMissing(cleanCollection, to: &file)
                return file.items[index]
            }

            file.items[index].collection = cleanCollection
            markItemUpdated(at: index, in: &file)
            try addCollectionIfMissing(cleanCollection, to: &file)
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
    public func delete(ids: [String] = [], collection: String? = nil) throws -> [TaskItem] {
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
    public func clearItems(collection: String, completedOnly: Bool = false) throws -> [TaskItem] {
        let cleanCollection = try normalizedExplicitCollection(collection)

        return try withFile(write: true) { file in
            let indexes = file.items.indices.filter { index in
                let item = file.items[index]
                return item.collection == cleanCollection
                    && (!completedOnly || item.status == .completed)
            }

            guard !indexes.isEmpty else {
                throw TaskStoreError.noMatchingTasks
            }

            let deletedItems = indexes.map { file.items[$0] }
            for index in indexes.reversed() {
                file.items.remove(at: index)
            }

            return deletedItems
        }
    }

    @discardableResult
    public func delete(id: String, ifCurrent expectedItem: TaskItem) throws -> Bool {
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
    public func mergeItem(
        id: String,
        intoPrevious previousID: String,
        title: String
    ) throws -> TaskItem? {
        let cleanTitle = normalizedExistingTitle(title)

        return try withFile(write: true) { file in
            let sourceIndex = try resolveIndex(id, in: file.items)
            let previousIndex = try resolveIndex(previousID, in: file.items)
            guard sourceIndex != previousIndex,
                  file.items[previousIndex].status == .draft || file.items[previousIndex].status == .ready,
                  file.items[previousIndex].notes.isEmpty else {
                return nil
            }

            let now = Date()
            let sourceNotes = file.items[sourceIndex].notes
            file.items[previousIndex].title += cleanTitle
            if !sourceNotes.isEmpty {
                file.items[previousIndex].notes = sourceNotes
            }
            markItemUpdated(at: previousIndex, in: &file, now: now)
            let mergedItem = file.items[previousIndex]
            file.items.remove(at: sourceIndex)
            return mergedItem
        }
    }

    @discardableResult
    public func splitItem(
        id: String,
        firstTitle: String,
        secondTitle: String,
        secondID requestedSecondID: String? = nil
    ) throws -> TaskItem {
        let cleanFirstTitle = normalizedNewTitle(firstTitle)
        let cleanSecondTitle = normalizedNewTitle(secondTitle)
        guard !cleanFirstTitle.isEmpty, !cleanSecondTitle.isEmpty else {
            throw TaskStoreError.invalidTitle
        }

        return try withFile(write: true) { file in
            let sourceIndex = try resolveIndex(id, in: file.items)
            let existingIDs = Set(file.items.map(\.id))
            let secondID = requestedSecondID ?? Self.makeID(existing: existingIDs)
            guard isValidID(secondID) else {
                throw TaskStoreError.invalidID(secondID)
            }
            guard !existingIDs.contains(secondID) else {
                throw TaskStoreError.duplicateID(secondID)
            }

            let sourceItem = file.items[sourceIndex]
            let now = Date()
            file.items[sourceIndex].title = cleanFirstTitle
            file.items[sourceIndex].notes = []
            if file.items[sourceIndex].status == .draft {
                file.items[sourceIndex].status = .ready
            }
            markItemUpdated(at: sourceIndex, in: &file, now: now)

            let secondItem = TaskItem(
                id: secondID,
                version: TaskItem.makeVersion(existing: Set(file.items.map(\.version))),
                title: cleanSecondTitle,
                collection: sourceItem.collection,
                notes: sourceItem.notes,
                status: sourceItem.status,
                createdAt: now,
                updatedAt: now
            )
            file.items.insert(secondItem, at: sourceIndex + 1)
            return secondItem
        }
    }

    @discardableResult
    public func setStatus(
        _ status: TaskStatus,
        ids: [String] = [],
        collection: String? = nil
    ) throws -> [TaskItem] {
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
        _ replacements: [TaskStatus: TaskStatus],
        ids: [String] = [],
        collection: String? = nil
    ) throws -> [TaskItem] {
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
    public func setStatus(_ status: TaskStatus, id: String, ifCurrent expectedItem: TaskItem) throws -> TaskItem? {
        try updateItem(id: id, ifCurrent: expectedItem) { item in
            guard item.status != status else {
                return false
            }

            item.status = status
            return true
        }
    }

    @discardableResult
    public func reorder(id: String, after previousID: String?, before nextID: String?) throws -> TaskItem {
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

    private func withFile<T>(write: Bool, _ body: (inout TaskFile) throws -> T) throws -> T {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw TaskStoreError.fileLockFailed(currentErrnoMessage())
        }
        defer {
            _ = Darwin.close(descriptor)
        }

        guard flock(descriptor, LOCK_EX) == 0 else {
            throw TaskStoreError.fileLockFailed(currentErrnoMessage())
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
        ifCurrent expectedItem: TaskItem,
        _ update: (inout TaskItem) throws -> Bool
    ) throws -> TaskItem? {
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

    private func markItemUpdated(at index: Int, in file: inout TaskFile, now: Date = Date()) {
        file.items[index].updatedAt = now
        refreshVersion(at: index, in: &file.items)
    }

    private func refreshVersion(at index: Int, in items: inout [TaskItem]) {
        var existingVersions = Set(items.map(\.version))
        existingVersions.remove(items[index].version)
        items[index].version = TaskItem.makeVersion(existing: existingVersions)
    }

    private func applyUpdate(
        title: String?,
        collection: String?,
        status: TaskStatus?,
        to index: Int,
        in file: inout TaskFile
    ) throws -> Bool {
        var changed = false

        if let title, file.items[index].title != title {
            file.items[index].title = title
            changed = true
        }

        if let collection {
            try addCollectionIfMissing(collection, to: &file)
            if file.items[index].collection != collection {
                file.items[index].collection = collection
                changed = true
            }
        }

        if let status, file.items[index].status != status {
            file.items[index].status = status
            changed = true
        }

        return changed
    }

    private func addNote(_ input: NormalizedNoteInput, to index: Int, in file: inout TaskFile) {
        let now = Date()
        appendNote(input, to: &file.items[index], now: now)
        markItemUpdated(at: index, in: &file, now: now)
    }

    private func targetCollection(ids: [String], collection: String?) throws -> String? {
        let cleanCollection: String?
        if let collection {
            cleanCollection = try normalizedExplicitCollection(collection)
        } else {
            cleanCollection = nil
        }

        if ids.isEmpty && cleanCollection == nil {
            throw TaskStoreError.missingTarget
        }

        if !ids.isEmpty && cleanCollection != nil {
            throw TaskStoreError.targetConflict
        }

        return cleanCollection
    }

    private func resolveTargetIndexes(ids: [String], collection cleanCollection: String?, in file: TaskFile) throws -> [Int] {
        let indexes: [Int]
        if let cleanCollection {
            indexes = file.items.indices.filter { file.items[$0].collection == cleanCollection }
        } else {
            indexes = try ids.map { try resolveIndex($0, in: file.items) }
        }

        let uniqueIndexes = Array(Set(indexes)).sorted()
        guard !uniqueIndexes.isEmpty else {
            throw TaskStoreError.noMatchingTasks
        }

        return uniqueIndexes
    }

    private func readFile() throws -> TaskFile {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return TaskFile()
        }

        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else {
            return TaskFile()
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TaskFile.self, from: data)
    }

    private func writeFile(_ file: TaskFile) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(file)
        try data.write(to: fileURL, options: .atomic)
    }
}

private struct TaskFile: Codable {
    var version = 6
    var collections: [String] = []
    var collectionGroups: [TaskCollectionGroup] = []
    var collectionColors: [String: TaskCollectionColor] = [:]
    var collectionPrompts: [String: String] = [:]
    var archivedCollections: Set<String> = []
    var items: [TaskItem] = []
    var needsMigration = false

    private enum CodingKeys: String, CodingKey {
        case version
        case collections
        case collectionGroups
        case collectionColors
        case collectionPrompts
        case archivedCollections
        case items
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
        let itemVersionProbes = try container.decodeIfPresent([TaskItemVersionProbe].self, forKey: .items) ?? []
        items = try container.decodeIfPresent([TaskItem].self, forKey: .items) ?? []
        needsMigration = itemVersionProbes.contains { $0.version?.isEmpty ?? true }
        let rawCollections = normalizedCollectionList(
            (try container.decodeIfPresent([String].self, forKey: .collections) ?? [])
                + items.map(\.collection)
        )
        let decodedGroups = try container.decodeIfPresent([TaskCollectionGroup].self, forKey: .collectionGroups)
        let migratedCollections = migratedCollectionState(
            collections: rawCollections,
            groups: decodedGroups,
            items: &items,
            usesLegacyGroups: version < 6 || storedGroupsNeedLegacyMigration(decodedGroups)
        )
        collections = migratedCollections.collections
        collectionGroups = migratedCollections.groups
        needsMigration = needsMigration || migratedCollections.changed
        if !container.contains(.collectionGroups) {
            needsMigration = true
        }
        let rawColors = try container.decodeIfPresent([String: String].self, forKey: .collectionColors) ?? [:]
        collectionColors = normalizedCollectionColors(
            migratedCollectionMetadata(
                rawColors.compactMapValues { TaskCollectionColor(rawValue: $0) },
                renameMap: migratedCollections.renameMap
            ),
            collections: collections
        )
        let rawPrompts = try container.decodeIfPresent([String: String].self, forKey: .collectionPrompts) ?? [:]
        collectionPrompts = normalizedCollectionPrompts(
            migratedCollectionMetadata(rawPrompts, renameMap: migratedCollections.renameMap),
            collections: collections
        )
        let rawArchivedCollections = try container.decodeIfPresent([String].self, forKey: .archivedCollections) ?? []
        archivedCollections = Set(
            normalizedCollectionList(rawArchivedCollections.map { migratedCollections.renameMap[$0] ?? $0 })
                .filter { collections.contains($0) }
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let collectionNames = normalizedCollectionList(collections + items.map(\.collection))
        let groups = normalizedCollectionGroups(collectionGroups, collections: collectionNames)
        try container.encode(6, forKey: .version)
        try container.encode(collectionNames, forKey: .collections)
        try container.encode(groups, forKey: .collectionGroups)
        try container.encode(
            normalizedCollectionColors(collectionColors, collections: collectionNames),
            forKey: .collectionColors
        )
        try container.encode(
            normalizedCollectionPrompts(collectionPrompts, collections: collectionNames),
            forKey: .collectionPrompts
        )
        try container.encode(
            sortedCollectionNames(archivedCollections.filter { collectionNames.contains($0) }),
            forKey: .archivedCollections
        )
        try container.encode(items, forKey: .items)
    }
}

private struct TaskCollectionGroup: Codable, Equatable {
    var name: String
    var collections: [String]
}

private struct TaskItemVersionProbe: Decodable {
    var version: String?

    private enum CodingKeys: String, CodingKey {
        case version
    }
}

private func resolveIndex(_ id: String, in items: [TaskItem]) throws -> Int {
    if let exact = items.firstIndex(where: { $0.id == id }) {
        return exact
    }

    let matches = items.enumerated().filter { $0.element.id.hasPrefix(id) }
    guard !matches.isEmpty else {
        throw TaskStoreError.notFound(id)
    }

    guard matches.count == 1, let match = matches.first else {
        throw TaskStoreError.ambiguousID(id, matches.map(\.element.id))
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

private struct NormalizedNoteInput {
    var body: String
}

private struct NormalizedNoteUpdate {
    var body: String?
}

private func normalizedNoteInput(body: String) throws -> NormalizedNoteInput {
    let cleanBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanBody.isEmpty else {
        throw TaskStoreError.invalidNote
    }

    return NormalizedNoteInput(body: cleanBody)
}

private func normalizedNoteUpdate(body: String?) throws -> NormalizedNoteUpdate {
    guard body != nil else {
        throw TaskStoreError.missingNoteUpdate
    }

    let cleanBody = try body.map { try normalizedNoteField($0) }
    return NormalizedNoteUpdate(body: cleanBody)
}

private func normalizedNoteField(_ field: String) throws -> String {
    let cleanField = field.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanField.isEmpty else {
        throw TaskStoreError.invalidNote
    }

    return cleanField
}

private func appendNote(_ input: NormalizedNoteInput, to item: inout TaskItem, now: Date = Date()) {
    item.notes = [TaskNote(
        id: item.notes.first?.id ?? TaskStore.makeID(),
        version: TaskItem.makeVersion(),
        body: input.body,
        createdAt: now,
        updatedAt: now
    )]
}

private func applyNoteUpdate(
    _ input: NormalizedNoteUpdate,
    noteID: String,
    to item: inout TaskItem
) throws -> Bool {
    let index = try resolveNoteIndex(noteID, in: item.notes)
    var changed = false

    if let body = input.body, item.notes[index].body != body {
        item.notes[index].body = body
        changed = true
    }

    guard changed else {
        return false
    }

    item.notes[index].updatedAt = Date()
    refreshNoteVersion(at: index, in: &item.notes)
    return true
}

private func applyNoteUpdate(_ input: NormalizedNoteUpdate, to item: inout TaskItem) -> Bool {
    guard !item.notes.isEmpty else {
        return false
    }

    var changed = false
    if let body = input.body, item.notes[0].body != body {
        item.notes[0].body = body
        changed = true
    }

    guard changed else {
        return false
    }

    item.notes[0].updatedAt = Date()
    refreshNoteVersion(at: 0, in: &item.notes)
    return true
}

private func removeNote(noteID: String, from item: inout TaskItem) throws {
    let index = try resolveNoteIndex(noteID, in: item.notes)
    item.notes.remove(at: index)
}

private func resolveNoteIndex(_ id: String, in notes: [TaskNote]) throws -> Int {
    guard let index = notes.firstIndex(where: { $0.id == id }) else {
        throw TaskStoreError.noteNotFound(id)
    }

    return index
}

private func refreshNoteVersion(at index: Int, in notes: inout [TaskNote]) {
    var existingVersions = Set(notes.map(\.version))
    existingVersions.remove(notes[index].version)
    notes[index].version = TaskItem.makeVersion(existing: existingVersions)
}

private struct CollectionReference {
    var groupName: String
    var displayName: String

    var apiName: String {
        collectionAPIName(groupName: groupName, displayName: displayName)
    }
}

private func normalizedCollection(_ collection: String) throws -> String {
    let clean = collection.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else {
        return TaskStore.defaultCollection
    }

    return try normalizedCollectionReference(clean, defaultGroup: TaskStore.defaultCollectionGroup).apiName
}

private func normalizedExplicitCollection(_ collection: String) throws -> String {
    let clean = collection.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else {
        throw TaskStoreError.invalidCollection
    }

    return try normalizedCollectionReference(clean, defaultGroup: TaskStore.defaultCollectionGroup).apiName
}

private func normalizedCollectionOrNil(_ collection: String?) throws -> String? {
    guard let collection else {
        return nil
    }

    return try normalizedCollection(collection)
}

private func normalizedCollectionReference(
    _ collection: String,
    defaultGroup: String
) throws -> CollectionReference {
    let cleanDefaultGroup = try normalizedExplicitCollectionGroup(defaultGroup)
    let cleanCollection = collection.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanCollection.isEmpty else {
        throw TaskStoreError.invalidCollection
    }

    let parts = cleanCollection.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    switch parts.count {
    case 1:
        let displayName = try normalizedCollectionDisplayName(parts[0])
        return CollectionReference(groupName: cleanDefaultGroup, displayName: displayName)
    case 2:
        let groupName = try normalizedExplicitCollectionGroup(parts[0])
        let displayName = try normalizedCollectionDisplayName(parts[1])
        return CollectionReference(groupName: groupName, displayName: displayName)
    default:
        throw TaskStoreError.invalidCollection
    }
}

private func normalizedCollectionDisplayName(_ displayName: String) throws -> String {
    let clean = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty, !clean.contains("/") else {
        throw TaskStoreError.invalidCollection
    }

    return clean
}

private func collectionReferenceIfValid(_ collection: String) -> CollectionReference? {
    try? normalizedCollectionReference(collection, defaultGroup: TaskStore.defaultCollectionGroup)
}

private func collectionAPIName(groupName: String, displayName: String) -> String {
    if groupName == TaskStore.defaultCollectionGroup {
        return displayName == legacyDefaultCollection ? TaskStore.defaultCollection : displayName
    }

    return "\(groupName)/\(displayName)"
}

private func collectionDisplayName(_ collection: String) -> String {
    if collection == TaskStore.defaultCollection {
        return legacyDefaultCollection
    }

    return collectionReferenceIfValid(collection)?.displayName ?? collection
}

private func collectionGroupName(forCollectionAPIName collection: String) -> String {
    collectionReferenceIfValid(collection)?.groupName ?? TaskStore.defaultCollectionGroup
}

private func normalizedCollectionList<S: Sequence>(_ collections: S) -> [String] where S.Element == String {
    var seen: Set<String> = []
    var result: [String] = []

    for collection in collections {
        let clean = (try? normalizedCollection(collection)) ?? TaskStore.defaultCollection
        guard !seen.contains(clean) else {
            continue
        }

        seen.insert(clean)
        result.append(clean)
    }

    return result
}

private func normalizedExplicitCollectionGroup(_ group: String) throws -> String {
    let clean = group.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty, !clean.contains("/") else {
        throw TaskStoreError.invalidCollectionGroup
    }

    return clean
}

private func normalizedStoredCollectionGroup(_ group: String) throws -> String {
    let clean = try normalizedExplicitCollectionGroup(group)
    return clean == legacyDefaultCollectionGroup ? TaskStore.defaultCollectionGroup : clean
}

private let legacyDefaultCollectionGroup = "Collections"
private let legacyDefaultCollection = "Inbox"

private func normalizedCollectionGroups(
    _ groups: [TaskCollectionGroup]?,
    collections: [String]
) -> [TaskCollectionGroup] {
    var seenGroups: Set<String> = []
    var assignedCollections: Set<String> = []
    var result: [TaskCollectionGroup] = []
    let collectionNames = normalizedCollectionList(collections)
    let collectionNameSet = Set(collectionNames)

    for group in groups ?? [] {
        guard let cleanName = try? normalizedStoredCollectionGroup(group.name),
              !seenGroups.contains(cleanName)
        else {
            continue
        }

        let cleanCollections = normalizedCollectionList(
            group.collections.map { collection in
                collectionAPIName(groupName: cleanName, displayName: collectionDisplayName(collection))
            }
        )
        .filter { collectionNameSet.contains($0) && !assignedCollections.contains($0) }
        assignedCollections.formUnion(cleanCollections)
        seenGroups.insert(cleanName)
        result.append(TaskCollectionGroup(name: cleanName, collections: cleanCollections))
    }

    if !seenGroups.contains(TaskStore.defaultCollectionGroup) {
        result.insert(TaskCollectionGroup(name: TaskStore.defaultCollectionGroup, collections: []), at: 0)
        seenGroups.insert(TaskStore.defaultCollectionGroup)
    }

    let unassignedCollections = collectionNames.filter { !assignedCollections.contains($0) }
    for collection in unassignedCollections {
        let groupName = collectionGroupName(forCollectionAPIName: collection)
        if let index = result.firstIndex(where: { $0.name == groupName }) {
            result[index].collections = normalizedCollectionList(result[index].collections + [collection])
        } else {
            result.append(TaskCollectionGroup(name: groupName, collections: [collection]))
        }
    }

    return result
}

private struct MigratedCollectionState {
    var collections: [String]
    var groups: [TaskCollectionGroup]
    var renameMap: [String: String]
    var changed: Bool
}

private func migratedCollectionState(
    collections rawCollections: [String],
    groups rawGroups: [TaskCollectionGroup]?,
    items: inout [TaskItem],
    usesLegacyGroups: Bool
) -> MigratedCollectionState {
    let sourceGroups = usesLegacyGroups
        ? normalizedLegacyCollectionGroups(rawGroups, collections: rawCollections)
        : normalizedCollectionGroups(rawGroups, collections: rawCollections)
    var renameMap: [String: String] = [:]
    var migratedGroups: [TaskCollectionGroup] = []
    var changed = false

    for group in sourceGroups {
        let migratedCollections = normalizedCollectionList(group.collections.map { collection in
            let apiName = collectionAPIName(groupName: group.name, displayName: collectionDisplayName(collection))
            if collection != apiName {
                changed = true
            }
            renameMap[collection] = apiName
            return apiName
        })
        migratedGroups.append(TaskCollectionGroup(name: group.name, collections: migratedCollections))
    }

    for index in items.indices {
        let cleanCollection = (try? normalizedCollection(items[index].collection)) ?? TaskStore.defaultCollection
        let migratedCollection = renameMap[cleanCollection] ?? cleanCollection
        if items[index].collection != migratedCollection {
            items[index].collection = migratedCollection
            changed = true
        }
    }

    let collections = normalizedCollectionList(
        rawCollections.map { renameMap[$0] ?? $0 }
            + items.map(\.collection)
            + migratedGroups.flatMap(\.collections)
    )
    let groups = normalizedCollectionGroups(migratedGroups, collections: collections)
    changed = changed || collections != rawCollections || groups != normalizedCollectionGroups(rawGroups, collections: rawCollections)
    return MigratedCollectionState(
        collections: collections,
        groups: groups,
        renameMap: renameMap,
        changed: changed
    )
}

private func normalizedLegacyCollectionGroups(
    _ groups: [TaskCollectionGroup]?,
    collections: [String]
) -> [TaskCollectionGroup] {
    var seenGroups: Set<String> = []
    var assignedCollections: Set<String> = []
    var result: [TaskCollectionGroup] = []
    let collectionNames = normalizedCollectionList(collections)

    for group in groups ?? [] {
        guard let cleanName = try? normalizedStoredCollectionGroup(group.name),
              !seenGroups.contains(cleanName)
        else {
            continue
        }

        let cleanCollections = normalizedCollectionList(group.collections)
            .filter { collectionNames.contains($0) && !assignedCollections.contains($0) }
        assignedCollections.formUnion(cleanCollections)
        seenGroups.insert(cleanName)
        result.append(TaskCollectionGroup(name: cleanName, collections: cleanCollections))
    }

    if !seenGroups.contains(TaskStore.defaultCollectionGroup) {
        result.insert(TaskCollectionGroup(name: TaskStore.defaultCollectionGroup, collections: []), at: 0)
        seenGroups.insert(TaskStore.defaultCollectionGroup)
    }

    let unassignedCollections = collectionNames.filter { !assignedCollections.contains($0) }
    if let defaultIndex = result.firstIndex(where: { $0.name == TaskStore.defaultCollectionGroup }) {
        result[defaultIndex].collections = normalizedCollectionList(result[defaultIndex].collections + unassignedCollections)
    }

    return result.filter { $0.name == TaskStore.defaultCollectionGroup }
        + result.filter { $0.name != TaskStore.defaultCollectionGroup }
}

private func storedGroupsNeedLegacyMigration(_ groups: [TaskCollectionGroup]?) -> Bool {
    for group in groups ?? [] {
        guard let cleanGroup = try? normalizedStoredCollectionGroup(group.name) else {
            continue
        }

        if cleanGroup != group.name {
            return true
        }

        for collection in group.collections {
            let cleanCollection = (try? normalizedCollection(collection)) ?? TaskStore.defaultCollection
            if collectionGroupName(forCollectionAPIName: cleanCollection) != cleanGroup {
                return true
            }
        }
    }

    return false
}

private func migratedCollectionMetadata<Value>(
    _ metadata: [String: Value],
    renameMap: [String: String]
) -> [String: Value] {
    var result: [String: Value] = [:]

    for (name, value) in metadata {
        let cleanName = (try? normalizedCollection(name)) ?? TaskStore.defaultCollection
        let migratedName = renameMap[cleanName] ?? cleanName
        if result[migratedName] == nil {
            result[migratedName] = value
        }
    }

    return result
}

private func sortedCollectionNames<S: Sequence>(_ collections: S) -> [String] where S.Element == String {
    let names = normalizedCollectionList(collections)
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

    return names.filter { $0 == TaskStore.defaultCollection }
        + names.filter { $0 != TaskStore.defaultCollection }
}

private func makeCollectionSummaries(in file: TaskFile) -> [TaskCollectionSummary] {
    let grouped = Dictionary(grouping: file.items, by: \.collection)

    return sortedCollectionNames(file.collections + grouped.keys)
        .map { name in
            collectionSummary(named: name, items: grouped[name] ?? [], in: file)
        }
}

private func makeCollectionGroupSummaries(in file: TaskFile) -> [TaskCollectionGroupSummary] {
    let summariesByName = Dictionary(uniqueKeysWithValues: makeCollectionSummaries(in: file).map { ($0.name, $0) })
    return normalizedCollectionGroups(file.collectionGroups, collections: Array(summariesByName.keys))
        .map { group in
            TaskCollectionGroupSummary(
                name: group.name,
                collections: group.collections.compactMap { summariesByName[$0] }
            )
        }
}

private func collectionGroupSummary(named name: String, in file: TaskFile) -> TaskCollectionGroupSummary {
    makeCollectionGroupSummaries(in: file).first { $0.name == name }
        ?? TaskCollectionGroupSummary(name: name)
}

private func collectionSummary(named name: String, in file: TaskFile) -> TaskCollectionSummary {
    let items = file.items.filter { $0.collection == name }
    return collectionSummary(named: name, items: items, in: file)
}

private func collectionSummary(named name: String, items: [TaskItem], in file: TaskFile) -> TaskCollectionSummary {
    let groupName = collectionGroupName(containing: name, in: file)
        ?? collectionGroupName(forCollectionAPIName: name)
    return TaskCollectionSummary(
        name: name,
        displayName: collectionDisplayName(name),
        groupName: groupName,
        totalCount: items.count,
        incompleteCount: items.filter(\.status.isIncomplete).count,
        statusIndicator: collectionStatusIndicator(for: items),
        color: collectionColor(name, in: file),
        isArchived: file.archivedCollections.contains(name),
        promptTemplate: collectionPrompt(name, in: file)
    )
}

private func addCollectionIfMissing(
    _ collection: String,
    group: String? = nil,
    to file: inout TaskFile
) throws {
    let cleanCollection = try normalizedCollection(collection)
    let cleanGroup = try group.map(normalizedExplicitCollectionGroup)
        ?? collectionGroupName(forCollectionAPIName: cleanCollection)
    let collectionAlreadyExists = collectionExists(cleanCollection, in: file)
    file.collections = normalizedCollectionList(file.collections + [cleanCollection])
    if file.collectionColors[cleanCollection] == nil {
        file.collectionColors[cleanCollection] = .gray
    }

    if group != nil {
        try moveCollectionInFile(cleanCollection, toGroup: cleanGroup, in: &file)
    } else if !collectionAlreadyExists && collectionGroupName(containing: cleanCollection, in: file) == nil {
        try moveCollectionInFile(cleanCollection, toGroup: cleanGroup, in: &file)
    } else {
        normalizeCollectionGroups(in: &file)
    }
}

private func addCollectionGroupIfMissing(_ group: String, to file: inout TaskFile) {
    normalizeCollectionGroups(in: &file)
    if !file.collectionGroups.contains(where: { $0.name == group }) {
        file.collectionGroups.append(TaskCollectionGroup(name: group, collections: []))
    }
}

private func normalizeCollectionGroups(in file: inout TaskFile) {
    file.collectionGroups = normalizedCollectionGroups(file.collectionGroups, collections: file.collections + file.items.map(\.collection))
}

private func moveCollectionInFile(_ collection: String, toGroup group: String, in file: inout TaskFile) throws {
    addCollectionGroupIfMissing(group, to: &file)
    removeCollectionFromGroups(collection, in: &file)
    guard let groupIndex = file.collectionGroups.firstIndex(where: { $0.name == group }) else {
        return
    }

    file.collectionGroups[groupIndex].collections.append(collection)
    file.collectionGroups[groupIndex].collections = normalizedCollectionList(file.collectionGroups[groupIndex].collections)
    normalizeCollectionGroups(in: &file)
}

private func assertCanMoveCollections(
    _ collections: [String],
    toGroup group: String,
    in file: TaskFile
) throws {
    let moving = Set(collections)
    let existingDisplayNames = Set(
        normalizedCollectionGroups(file.collectionGroups, collections: file.collections + file.items.map(\.collection))
            .first { $0.name == group }?
            .collections
            .filter { !moving.contains($0) }
            .map(collectionDisplayName) ?? []
    )

    for collection in collections where existingDisplayNames.contains(collectionDisplayName(collection)) {
        throw TaskStoreError.collectionConflict(
            collectionAPIName(groupName: group, displayName: collectionDisplayName(collection))
        )
    }
}

private func renameCollectionReference(
    from oldName: String,
    to newName: String,
    in file: inout TaskFile
) throws {
    let cleanOldName = try normalizedExplicitCollection(oldName)
    let cleanNewName = try normalizedExplicitCollection(newName)
    let oldColor = file.collectionColors.removeValue(forKey: cleanOldName)
    let oldPrompt = file.collectionPrompts.removeValue(forKey: cleanOldName)
    let wasArchived = file.archivedCollections.remove(cleanOldName) != nil
    let newGroup = collectionGroupName(forCollectionAPIName: cleanNewName)
    for index in file.items.indices where file.items[index].collection == cleanOldName {
        file.items[index].collection = cleanNewName
    }

    file.collections.removeAll { $0 == cleanOldName }
    file.collections = normalizedCollectionList(file.collections + [cleanNewName])
    removeCollectionFromGroups(cleanOldName, in: &file)
    addCollectionGroupIfMissing(newGroup, to: &file)
    if let groupIndex = file.collectionGroups.firstIndex(where: { $0.name == newGroup }) {
        file.collectionGroups[groupIndex].collections = normalizedCollectionList(
            file.collectionGroups[groupIndex].collections + [cleanNewName]
        )
    }
    if file.collectionColors[cleanNewName] == nil {
        file.collectionColors[cleanNewName] = oldColor ?? .gray
    }
    if file.collectionPrompts[cleanNewName] == nil, let oldPrompt {
        file.collectionPrompts[cleanNewName] = oldPrompt
    }
    if wasArchived {
        file.archivedCollections.insert(cleanNewName)
    }
    normalizeCollectionGroups(in: &file)
}

private func removeCollectionFromGroups(_ collection: String, in file: inout TaskFile) {
    for index in file.collectionGroups.indices {
        file.collectionGroups[index].collections.removeAll { $0 == collection }
    }
}

private func collectionGroupName(containing collection: String, in file: TaskFile) -> String? {
    normalizedCollectionGroups(file.collectionGroups, collections: file.collections + file.items.map(\.collection))
        .first { $0.collections.contains(collection) }?
        .name
}

private func collectionStatusIndicator(for items: [TaskItem]) -> TaskStatus? {
    if items.contains(where: { $0.status == .aborted }) {
        return .aborted
    }

    if items.contains(where: { $0.status == .rejected }) {
        return .rejected
    }

    if items.contains(where: { $0.status == .onHold }) {
        return .onHold
    }

    return nil
}

private func collectionExists(_ collection: String, in file: TaskFile) -> Bool {
    file.collections.contains(collection)
        || file.items.contains { $0.collection == collection }
}

private func collectionColor(_ collection: String, in file: TaskFile) -> TaskCollectionColor {
    file.collectionColors[collection] ?? .gray
}

private func collectionPrompt(_ collection: String, in file: TaskFile) -> String? {
    file.collectionPrompts[collection]
}

private func normalizedCollectionColors(
    _ colors: [String: TaskCollectionColor],
    collections: [String]
) -> [String: TaskCollectionColor] {
    let names = normalizedCollectionList(collections)
    let nameSet = Set(names)
    var result: [String: TaskCollectionColor] = [:]

    for (name, color) in colors {
        let cleanName = (try? normalizedCollection(name)) ?? TaskStore.defaultCollection
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

private func normalizedCollectionPrompts(
    _ prompts: [String: String],
    collections: [String]
) -> [String: String] {
    let names = normalizedCollectionList(collections)
    let nameSet = Set(names)
    var result: [String: String] = [:]

    for (name, prompt) in prompts {
        let cleanName = (try? normalizedCollection(name)) ?? TaskStore.defaultCollection
        guard nameSet.contains(cleanName),
              result[cleanName] == nil,
              let cleanPrompt = normalizedPromptTemplateOrNil(prompt)
        else {
            continue
        }

        result[cleanName] = cleanPrompt
    }

    return result
}

private func normalizedPromptTemplateOrNil(_ promptTemplate: String?) -> String? {
    guard let promptTemplate else {
        return nil
    }

    return promptTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : promptTemplate
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
