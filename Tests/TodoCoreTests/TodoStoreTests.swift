import XCTest
@testable import TodoCore

final class TodoStoreTests: XCTestCase {
    func testAddFilterAndSetByIDPrefix() throws {
        let store = makeStore()
        let first = try store.add(title: "Write app", collection: "Inbox")
        _ = try store.add(title: "Ship CLI", collection: "Work")

        XCTAssertEqual(try store.items(status: .undone).count, 2)

        let prefix = String(first.id.prefix(4))
        let changed = try store.setCompletion(isDone: true, ids: [prefix])

        XCTAssertEqual(changed.map(\.id), [first.id])
        XCTAssertEqual(try store.items(status: .done).map(\.id), [first.id])
        XCTAssertEqual(try store.items(status: .undone).count, 1)
    }

    func testSetByCollection() throws {
        let store = makeStore()
        let first = try store.add(title: "One", collection: "Inbox")
        let second = try store.add(title: "Two", collection: "Inbox")
        _ = try store.add(title: "Three", collection: "Work")

        let changed = try store.setCompletion(isDone: true, collection: "Inbox")

        XCTAssertEqual(Set(changed.map(\.id)), Set([first.id, second.id]))
        XCTAssertEqual(try store.items(status: .done, collection: "Inbox").count, 2)
        XCTAssertEqual(try store.items(status: .undone).count, 1)
    }

    func testSetLockByIDPrefix() throws {
        let store = makeStore()
        let item = try store.add(title: "One", collection: "Inbox")

        let locked = try store.setLock(isLocked: true, ids: [String(item.id.prefix(4))])

        XCTAssertEqual(locked.map(\.id), [item.id])
        XCTAssertEqual(try store.items(ids: [item.id]).map(\.isLocked), [true])

        try store.setLock(isLocked: false, ids: [item.id])

        XCTAssertEqual(try store.items(ids: [item.id]).map(\.isLocked), [false])
    }

    func testSetStateUpdatesCompletionAndLockTogether() throws {
        let store = makeStore()
        let item = try store.add(title: "One", collection: "Inbox")

        let changed = try store.setState(isDone: true, isLocked: true, ids: [String(item.id.prefix(4))])

        XCTAssertEqual(changed.map(\.id), [item.id])
        XCTAssertEqual(changed.map(\.isDone), [true])
        XCTAssertEqual(changed.map(\.isLocked), [true])
    }

    func testSetStateRequiresAState() throws {
        let store = makeStore()
        let item = try store.add(title: "One")

        XCTAssertThrowsError(try store.setState(ids: [item.id])) { error in
            XCTAssertEqual(error as? TodoStoreError, .missingState)
        }
    }

    func testEmptyCollectionIsIncludedInSummaries() throws {
        let store = makeStore()

        try store.createCollection(name: "Personal")

        XCTAssertEqual(
            try store.collectionSummaries(),
            [TodoCollectionSummary(name: "Personal", totalCount: 0, undoneCount: 0)]
        )
    }

    func testLegacyStoreBuildsCollectionsFromItems() throws {
        let store = makeStore()
        let date = Date(timeIntervalSince1970: 0)
        let item = TodoItem(
            id: "feedbeef",
            title: "Legacy",
            collection: "Legacy",
            createdAt: date,
            updatedAt: date
        )

        try writeLegacyStore(items: [item], to: store.fileURL)

        XCTAssertEqual(
            try store.collectionSummaries(),
            [TodoCollectionSummary(name: "Legacy", totalCount: 1, undoneCount: 1)]
        )
        XCTAssertEqual(try store.items(ids: [item.id]).map(\.isLocked), [false])
    }

    func testRenameCollectionMovesItems() throws {
        let store = makeStore()
        let item = try store.add(title: "One", collection: "Inbox")

        try store.renameCollection(from: "Inbox", to: "Database")

        let current = try XCTUnwrap(try store.items(ids: [item.id]).first)
        XCTAssertEqual(current.collection, "Database")
        XCTAssertEqual(
            try store.collectionSummaries(),
            [TodoCollectionSummary(name: "Database", totalCount: 1, undoneCount: 1)]
        )
    }

    func testRenameCollectionMergesExistingCollection() throws {
        let store = makeStore()
        _ = try store.add(title: "One", collection: "Inbox")
        _ = try store.add(title: "Two", collection: "Work")

        try store.renameCollection(from: "Inbox", to: "Work")

        XCTAssertEqual(Set(try store.items().map(\.collection)), ["Work"])
        XCTAssertEqual(
            try store.collectionSummaries(),
            [TodoCollectionSummary(name: "Work", totalCount: 2, undoneCount: 2)]
        )
    }

    func testDeleteCollectionRemovesItemsAndSummary() throws {
        let store = makeStore()
        let inbox = try store.add(title: "One", collection: "Inbox")
        let work = try store.add(title: "Two", collection: "Work")
        try store.createCollection(name: "Empty")

        let deleted = try store.deleteCollection(name: "Inbox")

        XCTAssertTrue(deleted)
        let remainingItems = try store.items()
        XCTAssertEqual(remainingItems.map(\.id), [work.id])
        XCTAssertFalse(remainingItems.contains { $0.id == inbox.id })
        XCTAssertEqual(
            try store.collectionSummaries(),
            [
                TodoCollectionSummary(name: "Empty", totalCount: 0, undoneCount: 0),
                TodoCollectionSummary(name: "Work", totalCount: 1, undoneCount: 1)
            ]
        )
    }

    func testDeleteCollectionRemovesEmptyCollection() throws {
        let store = makeStore()
        try store.createCollection(name: "Empty")

        let deleted = try store.deleteCollection(name: "Empty")

        XCTAssertTrue(deleted)
        XCTAssertEqual(try store.collectionSummaries(), [])
    }

    func testDeleteCollectionRequiresExistingCollection() throws {
        let store = makeStore()

        XCTAssertThrowsError(try store.deleteCollection(name: "Missing")) { error in
            XCTAssertEqual(error as? TodoStoreError, .collectionNotFound("Missing"))
        }
    }

    func testEmptyCollectionNamesAreRejected() throws {
        let store = makeStore()
        try store.createCollection(name: "Inbox")

        XCTAssertThrowsError(try store.createCollection(name: "   ")) { error in
            XCTAssertEqual(error as? TodoStoreError, .invalidCollection)
        }
        XCTAssertThrowsError(try store.renameCollection(from: "Inbox", to: "\n")) { error in
            XCTAssertEqual(error as? TodoStoreError, .invalidCollection)
        }
        XCTAssertThrowsError(try store.deleteCollection(name: " ")) { error in
            XCTAssertEqual(error as? TodoStoreError, .invalidCollection)
        }
    }

    func testCollectionAndIDTargetsConflict() throws {
        let store = makeStore()
        let item = try store.add(title: "One")

        XCTAssertThrowsError(try store.setCompletion(isDone: true, ids: [item.id], collection: "Inbox")) { error in
            XCTAssertEqual(error as? TodoStoreError, .targetConflict)
        }
    }

    func testDeleteByIDsReturnsDeletedItems() throws {
        let store = makeStore()
        let first = try store.add(title: "One", collection: "Inbox")
        let second = try store.add(title: "Two", collection: "Inbox")

        let deleted = try store.delete(ids: [String(first.id.prefix(4))])

        XCTAssertEqual(deleted.map(\.id), [first.id])
        XCTAssertEqual(try store.items().map(\.id), [second.id])
    }

    func testDeleteByCollectionLeavesEmptyCollection() throws {
        let store = makeStore()
        let first = try store.add(title: "One", collection: "Inbox")
        let second = try store.add(title: "Two", collection: "Inbox")
        let work = try store.add(title: "Three", collection: "Work")

        let deleted = try store.delete(collection: "Inbox")

        XCTAssertEqual(Set(deleted.map(\.id)), Set([first.id, second.id]))
        XCTAssertEqual(try store.items().map(\.id), [work.id])
        XCTAssertEqual(
            try store.collectionSummaries(),
            [
                TodoCollectionSummary(name: "Inbox", totalCount: 0, undoneCount: 0),
                TodoCollectionSummary(name: "Work", totalCount: 1, undoneCount: 1)
            ]
        )
    }

    func testClearUnlockedItemsKeepsLockedItems() throws {
        let store = makeStore()
        let unlocked = try store.add(title: "Unlocked", collection: "Inbox")
        let locked = try store.add(title: "Locked", collection: "Inbox")
        try store.setLock(isLocked: true, ids: [locked.id])

        let deleted = try store.clearUnlockedItems(collection: "Inbox")

        XCTAssertEqual(deleted.map(\.id), [unlocked.id])
        XCTAssertEqual(try store.items(collection: "Inbox").map(\.id), [locked.id])
    }

    func testClearDoneUnlockedItemsKeepsUndoneAndLockedItems() throws {
        let store = makeStore()
        let done = try store.add(title: "Done", collection: "Inbox")
        let undone = try store.add(title: "Undone", collection: "Inbox")
        let lockedDone = try store.add(title: "Locked done", collection: "Inbox")
        try store.setCompletion(isDone: true, ids: [done.id, lockedDone.id])
        try store.setLock(isLocked: true, ids: [lockedDone.id])

        let deleted = try store.clearUnlockedItems(collection: "Inbox", doneOnly: true)

        XCTAssertEqual(deleted.map(\.id), [done.id])
        XCTAssertEqual(try store.items(collection: "Inbox").map(\.id), [undone.id, lockedDone.id])
    }

    func testReorderMovesItemsInStoredOrder() throws {
        let store = makeStore()
        let first = try store.add(title: "One", id: "11111111")
        let second = try store.add(title: "Two", id: "22222222")
        let third = try store.add(title: "Three", id: "33333333")

        try store.reorder(id: third.id, after: nil, before: first.id)

        XCTAssertEqual(try store.items().map(\.id), [third.id, first.id, second.id])

        try store.reorder(id: third.id, after: second.id, before: nil)

        XCTAssertEqual(try store.items().map(\.id), [first.id, second.id, third.id])
    }

    func testAddCanUseRequestedID() throws {
        let store = makeStore()
        let item = try store.add(title: "One", collection: "Inbox", id: "feedbeef")

        XCTAssertEqual(item.id, "feedbeef")
        XCTAssertEqual(try store.items(ids: ["feedbeef"]).map(\.title), ["One"])
        XCTAssertThrowsError(try store.add(title: "Two", collection: "Inbox", id: "feedbeef")) { error in
            XCTAssertEqual(error as? TodoStoreError, .duplicateID("feedbeef"))
        }
    }

    func testAddRejectsEmptyTitleUnlessAllowed() throws {
        let store = makeStore()

        XCTAssertThrowsError(try store.add(title: " \n\t ")) { error in
            XCTAssertEqual(error as? TodoStoreError, .invalidTitle)
        }

        let item = try store.add(title: "", collection: "Inbox", id: "feedbeef", allowEmptyTitle: true)

        XCTAssertEqual(item.title, "")
        XCTAssertEqual(try store.items(ids: ["feedbeef"]).map(\.title), [""])
    }

    func testConditionalUpdateKeepsCurrentDatabaseStateOnConflict() throws {
        let store = makeStore()
        let item = try store.add(title: "One", collection: "Inbox")
        let staleItem = try XCTUnwrap(try store.items(ids: [item.id]).first)

        try store.updateTitle(id: item.id, title: "Database")

        let changed = try store.updateTitle(id: item.id, title: "Local", ifCurrent: staleItem)
        let current = try XCTUnwrap(try store.items(ids: [item.id]).first)

        XCTAssertNil(changed)
        XCTAssertEqual(current.title, "Database")
    }

    func testConditionalDeleteKeepsCurrentDatabaseStateOnConflict() throws {
        let store = makeStore()
        let item = try store.add(title: "One", collection: "Inbox")
        let staleItem = try XCTUnwrap(try store.items(ids: [item.id]).first)

        try store.move(id: item.id, collection: "Database")

        let deleted = try store.delete(id: item.id, ifCurrent: staleItem)
        let current = try XCTUnwrap(try store.items(ids: [item.id]).first)

        XCTAssertFalse(deleted)
        XCTAssertEqual(current.collection, "Database")
    }

    private func makeStore() -> TodoStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmolTodoTests-\(UUID().uuidString)", isDirectory: true)
        return TodoStore(fileURL: directory.appendingPathComponent("todos.json"))
    }

    private func writeLegacyStore(items: [TodoItem], to fileURL: URL) throws {
        let file = LegacyTodoFile(
            version: 1,
            items: items.map {
                LegacyTodoItem(
                    id: $0.id,
                    title: $0.title,
                    collection: $0.collection,
                    isDone: $0.isDone,
                    createdAt: $0.createdAt,
                    updatedAt: $0.updatedAt
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(file).write(to: fileURL)
    }

    private struct LegacyTodoFile: Encodable {
        var version: Int
        var items: [LegacyTodoItem]
    }

    private struct LegacyTodoItem: Encodable {
        var id: String
        var title: String
        var collection: String
        var isDone: Bool
        var createdAt: Date
        var updatedAt: Date
    }
}
