import Darwin
import Foundation

/// Thread- and process-safe via an exclusive file lock (see ``withFile(write:)``).
/// All stored state is immutable (`let`), so the type is genuinely `Sendable`.
public final class TaskStore: Sendable {
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
    public func reorderCollection(
        name: String,
        toGroup group: String,
        after previousName: String?,
        before nextName: String?
    ) throws -> TaskCollectionSummary {
        let cleanName = try normalizedExplicitCollection(name)
        let cleanGroup = try normalizedExplicitCollectionGroup(group)
        let cleanPreviousName = try previousName.map(normalizedExplicitCollection)
        let cleanNextName = try nextName.map(normalizedExplicitCollection)

        guard cleanName != Self.defaultCollection else {
            throw TaskStoreError.defaultCollection
        }

        return try withFile(write: true) { file in
            normalizeCollectionGroups(in: &file)
            guard collectionExists(cleanName, in: file) else {
                throw TaskStoreError.collectionNotFound(cleanName)
            }

            let targetName = collectionAPIName(groupName: cleanGroup, displayName: collectionDisplayName(cleanName))
            if cleanName != targetName {
                guard !collectionExists(targetName, in: file) else {
                    throw TaskStoreError.collectionConflict(targetName)
                }
                try renameCollectionReference(from: cleanName, to: targetName, in: &file)
            }

            try reorderCollectionInFile(
                targetName,
                toGroup: cleanGroup,
                after: cleanPreviousName,
                before: cleanNextName,
                in: &file
            )
            return collectionSummary(named: targetName, in: file)
        }
    }

    @discardableResult
    public func reorderCollectionGroup(
        name: String,
        after previousName: String?,
        before nextName: String?
    ) throws -> TaskCollectionGroupSummary {
        let cleanName = try normalizedExplicitCollectionGroup(name)
        let cleanPreviousName = try previousName.map(normalizedExplicitCollectionGroup)
        let cleanNextName = try nextName.map(normalizedExplicitCollectionGroup)

        guard cleanName != Self.defaultCollectionGroup else {
            throw TaskStoreError.defaultCollectionGroup
        }

        return try withFile(write: true) { file in
            normalizeCollectionGroups(in: &file)
            guard let sourceIndex = file.collectionGroups.firstIndex(where: { $0.name == cleanName }) else {
                throw TaskStoreError.collectionGroupNotFound(cleanName)
            }

            let group = file.collectionGroups.remove(at: sourceIndex)
            let insertionIndex: Int
            if let cleanPreviousName, cleanPreviousName != cleanName {
                guard let previousIndex = file.collectionGroups.firstIndex(where: { $0.name == cleanPreviousName }) else {
                    throw TaskStoreError.collectionGroupNotFound(cleanPreviousName)
                }
                insertionIndex = previousIndex + 1
            } else if let cleanNextName, cleanNextName != cleanName {
                guard let nextIndex = file.collectionGroups.firstIndex(where: { $0.name == cleanNextName }) else {
                    throw TaskStoreError.collectionGroupNotFound(cleanNextName)
                }
                insertionIndex = cleanNextName == Self.defaultCollectionGroup ? nextIndex + 1 : nextIndex
            } else {
                insertionIndex = file.collectionGroups.count
            }

            file.collectionGroups.insert(group, at: min(insertionIndex, file.collectionGroups.count))
            normalizeCollectionGroups(in: &file)
            return collectionGroupSummary(named: cleanName, in: file)
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

            if try applyNoteUpdate(input, noteID: nil, to: &file.items[index]) {
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

        return try PondJSON.persistedDecoder.decode(TaskFile.self, from: data)
    }

    private func writeFile(_ file: TaskFile) throws {
        let data = try PondJSON.persistedEncoder.encode(file)
        try data.write(to: fileURL, options: .atomic)
    }
}

