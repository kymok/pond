import XCTest
@testable import TodoCore

final class TodoStoreTests: XCTestCase {
    func testAddDefaultsFilterAndSetStatusByIDPrefix() throws {
        let store = makeStore()
        let first = try store.add(title: "Write app", collection: "Inbox")
        _ = try store.add(title: "Ship CLI", collection: "Work")

        XCTAssertEqual(try store.items(ids: [first.id]).map(\.status), [.ready])
        XCTAssertEqual(try store.items(status: .ready).count, 2)

        let prefix = String(first.id.prefix(4))
        let changed = try store.setStatus(.completed, ids: [prefix])

        XCTAssertEqual(changed.map(\.id), [first.id])
        XCTAssertEqual(changed.map(\.status), [.completed])
        XCTAssertEqual(try store.items(status: .completed).map(\.id), [first.id])
        XCTAssertEqual(try store.items(status: .ready).count, 1)
    }

    func testSetByCollection() throws {
        let store = makeStore()
        let first = try store.add(title: "One", collection: "Inbox")
        let second = try store.add(title: "Two", collection: "Inbox")
        _ = try store.add(title: "Three", collection: "Work")

        let changed = try store.setStatus(.completed, collection: "Inbox")

        XCTAssertEqual(Set(changed.map(\.id)), Set([first.id, second.id]))
        XCTAssertEqual(try store.items(status: .completed, collection: "Inbox").count, 2)
        XCTAssertEqual(try store.items(status: .ready).count, 1)
    }

    func testSetStatusByIDPrefix() throws {
        let store = makeStore()
        let item = try store.add(title: "One", collection: "Inbox")

        let updated = try store.setStatus(.inProgress, ids: [String(item.id.prefix(4))])

        XCTAssertEqual(updated.map(\.id), [item.id])
        XCTAssertEqual(try store.items(ids: [item.id]).map(\.status), [.inProgress])

        try store.setStatus(.onHold, ids: [item.id])

        XCTAssertEqual(try store.items(ids: [item.id]).map(\.status), [.onHold])
    }

    func testSetStatusCanUseEveryStatus() throws {
        let store = makeStore()
        let item = try store.add(title: "One", collection: "Inbox")

        for status in TodoStatus.allCases {
            let changed = try store.setStatus(status, ids: [String(item.id.prefix(4))])

            XCTAssertEqual(changed.map(\.id), [item.id])
            XCTAssertEqual(changed.map(\.status), [status])
        }
    }

    func testSetPriorityCanUseEveryPriority() throws {
        let store = makeStore()
        let item = try store.add(title: "One", collection: "Inbox")

        for priority in TodoPriority.allCases {
            let changed = try store.setPriority(priority, ids: [String(item.id.prefix(4))])

            XCTAssertEqual(changed.map(\.id), [item.id])
            XCTAssertEqual(changed.map(\.priority), [priority])
        }
    }

    func testPriorityDefaultsToNormalAndPersistsPrioritized() throws {
        let store = makeStore()
        let item = try store.add(title: "One", collection: "Inbox")

        XCTAssertEqual(item.priority, .normal)
        XCTAssertEqual(try store.items().map(\.priority), [.normal])

        let prioritized = try store.setPriority(.prioritized, ids: [item.id])

        XCTAssertEqual(prioritized.map(\.priority), [.prioritized])
        XCTAssertEqual(try store.items(priority: .prioritized).map(\.id), [item.id])

        let json = try XCTUnwrap(String(data: Data(contentsOf: store.fileURL), encoding: .utf8))
        XCTAssertTrue(json.contains(#""priority" : "prioritized""#))
    }

    func testDraftStatusIsPersistedAndIncomplete() throws {
        let store = makeStore()
        let item = try store.add(title: "One", collection: "Inbox", status: .draft)

        XCTAssertEqual(try store.items(status: .draft).map(\.id), [item.id])
        XCTAssertEqual(
            try store.collectionSummaries(),
            [TodoCollectionSummary(name: "Inbox", totalCount: 1, incompleteCount: 1)]
        )

        let json = try XCTUnwrap(String(data: Data(contentsOf: store.fileURL), encoding: .utf8))
        XCTAssertTrue(json.contains(#""status" : "draft""#))
    }

    func testReadyDisplayNameIsReady() {
        XCTAssertEqual(TodoStatus.ready.displayName, "Ready")
    }

    func testAddedItemsHaveRandomAlphanumericVersions() throws {
        let store = makeStore()
        let item = try store.add(title: "One", collection: "Inbox")

        XCTAssertEqual(item.version.count, 12)
        XCTAssertTrue(item.version.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains))
    }

    func testStatusOrderPutsDraftBeforeReady() {
        XCTAssertEqual(Array(TodoStatus.allCases.prefix(2)), [.draft, .ready])
    }

    func testUpdateTitleReturnsItemToDraft() throws {
        let store = makeStore()
        let item = try store.add(title: "One", collection: "Inbox")
        try store.setStatus(.onHold, ids: [item.id])
        let current = try XCTUnwrap(try store.items(ids: [item.id]).first)

        let updated = try XCTUnwrap(try store.updateTitle(id: item.id, title: "Two", ifCurrent: current))

        XCTAssertEqual(updated.title, "Two")
        XCTAssertEqual(updated.status, .draft)
        XCTAssertNotEqual(updated.version, current.version)
        XCTAssertEqual(try store.items(ids: [item.id]).map(\.status), [.draft])
    }

    func testUpdateChangesFieldsWithoutChangingID() throws {
        let store = makeStore()
        let item = try store.add(title: "One", collection: "Inbox")

        let updated = try store.update(
            id: item.id,
            title: "Two",
            collection: "Work",
            status: .onHold,
            priority: .prioritized
        )

        XCTAssertEqual(updated.id, item.id)
        XCTAssertNotEqual(updated.version, item.version)
        XCTAssertEqual(updated.title, "Two")
        XCTAssertEqual(updated.collection, "Work")
        XCTAssertEqual(updated.status, .onHold)
        XCTAssertEqual(updated.priority, .prioritized)

        let persisted = try XCTUnwrap(try store.items(ids: [item.id]).first)
        XCTAssertEqual(persisted.id, item.id)
        XCTAssertEqual(persisted.version, updated.version)
        XCTAssertEqual(persisted.title, "Two")
        XCTAssertEqual(persisted.collection, "Work")
        XCTAssertEqual(persisted.status, .onHold)
        XCTAssertEqual(persisted.priority, .prioritized)
    }

    func testUpdatePreservesVersionWhenFieldsAlreadyMatch() throws {
        let store = makeStore()
        let item = try store.add(title: "One", collection: "Inbox")

        let updated = try store.update(
            id: item.id,
            title: "Two",
            collection: "Work",
            status: .ready,
            priority: .prioritized
        )
        let repeated = try store.update(
            id: item.id,
            title: "Two",
            collection: "Work",
            status: .ready,
            priority: .prioritized
        )

        XCTAssertEqual(repeated.version, updated.version)
    }

    func testAssignCanSetMultipleAndClearAssignees() throws {
        let store = makeStore()
        let item = try store.add(title: "One", collection: "Inbox")

        let assigned = try store.assign(id: item.id, assignees: ["  Kai  ", "Mina", "Kai", ""])

        XCTAssertEqual(assigned.assignees, ["Kai", "Mina"])
        XCTAssertNotEqual(assigned.version, item.version)
        XCTAssertEqual(try store.items(ids: [item.id]).map(\.assignees), [["Kai", "Mina"]])

        let unchanged = try store.assign(id: item.id, assignees: ["Kai", "Mina"])
        XCTAssertEqual(unchanged.version, assigned.version)

        let cleared = try store.assign(id: item.id, assignees: [])

        XCTAssertEqual(cleared.assignees, [])
        XCTAssertNotEqual(cleared.version, assigned.version)
        XCTAssertEqual(try store.items(ids: [item.id]).map(\.assignees), [[]])
    }

    func testUpdateTitleCanPreserveStatus() throws {
        let store = makeStore()
        let item = try store.add(title: "One", collection: "Inbox")
        try store.setStatus(.onHold, ids: [item.id])
        let current = try XCTUnwrap(try store.items(ids: [item.id]).first)

        let updated = try XCTUnwrap(try store.updateTitle(
            id: item.id,
            title: "Two",
            ifCurrent: current,
            statusAfterEdit: nil
        ))

        XCTAssertEqual(updated.title, "Two")
        XCTAssertEqual(updated.status, .onHold)
        XCTAssertEqual(try store.items(ids: [item.id]).map(\.status), [.onHold])
    }

    func testUpdateTitleCanSetReadyWithoutChangingTitle() throws {
        let store = makeStore()
        let item = try store.add(title: "One", collection: "Inbox", status: .draft)
        let current = try XCTUnwrap(try store.items(ids: [item.id]).first)

        let updated = try XCTUnwrap(try store.updateTitle(
            id: item.id,
            title: "One",
            ifCurrent: current,
            statusAfterEdit: .ready
        ))

        XCTAssertEqual(updated.title, "One")
        XCTAssertEqual(updated.status, .ready)
        XCTAssertEqual(try store.items(ids: [item.id]).map(\.status), [.ready])
    }

    func testTitlesCanContainNewlines() throws {
        let store = makeStore()
        let item = try store.add(title: "One", collection: "Inbox")

        let updated = try store.updateTitle(id: item.id, title: "One\nTwo")

        XCTAssertEqual(updated.title, "One\nTwo")
        XCTAssertEqual(try store.items(ids: [item.id]).map(\.title), ["One\nTwo"])
    }

    func testSetStatusesRemapsStatusesInCollection() throws {
        let store = makeStore()
        let ready = try store.add(title: "Ready", collection: "Inbox")
        let inProgress = try store.add(title: "In progress", collection: "Inbox")
        let work = try store.add(title: "Work", collection: "Work")
        try store.setStatus(.inProgress, ids: [inProgress.id])
        try store.setStatus(.onHold, ids: [work.id])

        let changed = try store.setStatuses(
            [
                .ready: .completed,
                .inProgress: .onHold,
                .completed: .completed
            ],
            collection: "Inbox"
        )

        XCTAssertEqual(Set(changed.map(\.id)), Set([ready.id, inProgress.id]))
        XCTAssertEqual(try store.items(ids: [ready.id]).map(\.status), [.completed])
        XCTAssertEqual(try store.items(ids: [inProgress.id]).map(\.status), [.onHold])
        XCTAssertEqual(try store.items(ids: [work.id]).map(\.status), [.onHold])
    }

    func testSetStatusesRemapsOnlyTargetIDs() throws {
        let store = makeStore()
        let first = try store.add(title: "One", collection: "Inbox")
        let second = try store.add(title: "Two", collection: "Inbox")

        let changed = try store.setStatuses([.ready: .completed], ids: [first.id])

        XCTAssertEqual(changed.map(\.id), [first.id])
        XCTAssertEqual(try store.items(ids: [first.id]).map(\.status), [.completed])
        XCTAssertEqual(try store.items(ids: [second.id]).map(\.status), [.ready])
    }

    func testEmptyCollectionIsIncludedInSummaries() throws {
        let store = makeStore()

        try store.createCollection(name: "Personal")

        XCTAssertEqual(
            try store.collectionSummaries(),
            [TodoCollectionSummary(name: "Personal", totalCount: 0, incompleteCount: 0)]
        )
    }

    func testCollectionColorIsPersisted() throws {
        let store = makeStore()
        try store.createCollection(name: "Personal")

        let updated = try store.setCollectionColor(name: "Personal", color: .blue)

        XCTAssertEqual(updated.color, .blue)
        XCTAssertEqual(
            try store.collectionSummaries(),
            [TodoCollectionSummary(name: "Personal", totalCount: 0, incompleteCount: 0, color: .blue)]
        )

        let reloadedStore = TodoStore(fileURL: store.fileURL)
        XCTAssertEqual(try reloadedStore.collectionSummaries().map(\.color), [.blue])
    }

    func testRenameCollectionCarriesColor() throws {
        let store = makeStore()
        try store.createCollection(name: "Inbox")
        try store.setCollectionColor(name: "Inbox", color: .green)

        try store.renameCollection(from: "Inbox", to: "Personal")

        XCTAssertEqual(
            try store.collectionSummaries(),
            [TodoCollectionSummary(name: "Personal", totalCount: 0, incompleteCount: 0, color: .green)]
        )
    }

    func testCollectionArchiveStatusIsPersisted() throws {
        let store = makeStore()
        try store.createCollection(name: "Inbox")

        let archived = try store.setCollectionArchived(name: "Inbox", isArchived: true)

        XCTAssertTrue(archived.isArchived)
        XCTAssertEqual(
            try store.collectionSummaries(),
            [TodoCollectionSummary(name: "Inbox", totalCount: 0, incompleteCount: 0, isArchived: true)]
        )

        let reloadedStore = TodoStore(fileURL: store.fileURL)
        XCTAssertEqual(try reloadedStore.collectionSummaries().map(\.isArchived), [true])

        let unarchived = try reloadedStore.setCollectionArchived(name: "Inbox", isArchived: false)
        XCTAssertFalse(unarchived.isArchived)
        XCTAssertEqual(try reloadedStore.collectionSummaries().map(\.isArchived), [false])
    }

    func testRenameCollectionCarriesArchiveStatus() throws {
        let store = makeStore()
        try store.createCollection(name: "Inbox")
        try store.setCollectionArchived(name: "Inbox", isArchived: true)

        try store.renameCollection(from: "Inbox", to: "Personal")

        XCTAssertEqual(
            try store.collectionSummaries(),
            [TodoCollectionSummary(name: "Personal", totalCount: 0, incompleteCount: 0, isArchived: true)]
        )
    }

    func testLegacyStoreBuildsCollectionsFromItems() throws {
        let store = makeStore()
        let date = Date(timeIntervalSince1970: 0)
        let completedLocked = LegacyTodoItem(
            id: "feedbeef",
            title: "Done locked",
            collection: "Legacy",
            isDone: true,
            isLocked: true,
            createdAt: date,
            updatedAt: date
        )
        let locked = LegacyTodoItem(
            id: "cafebabe",
            title: "Locked",
            collection: "Legacy",
            isDone: false,
            isLocked: true,
            createdAt: date,
            updatedAt: date
        )
        let ready = LegacyTodoItem(
            id: "deadbeef",
            title: "Ready",
            collection: "Legacy",
            isDone: false,
            isLocked: false,
            createdAt: date,
            updatedAt: date
        )

        try writeLegacyStore(items: [completedLocked, locked, ready], to: store.fileURL)

        XCTAssertEqual(
            try store.collectionSummaries(),
            [TodoCollectionSummary(name: "Legacy", totalCount: 3, incompleteCount: 2)]
        )
        XCTAssertEqual(try store.collectionSummaries().map(\.color), [.gray])

        let statuses = Dictionary(uniqueKeysWithValues: try store.items().map { ($0.id, $0.status) })
        XCTAssertEqual(statuses["feedbeef"], .completed)
        XCTAssertEqual(statuses["cafebabe"], .inProgress)
        XCTAssertEqual(statuses["deadbeef"], .ready)
        XCTAssertEqual(Set(try store.items().map(\.priority)), [.normal])

        let json = try XCTUnwrap(String(data: Data(contentsOf: store.fileURL), encoding: .utf8))
        XCTAssertTrue(json.contains(#""version" : 5"#))
        XCTAssertGreaterThan(json.components(separatedBy: #""version""#).count, 4)
    }

    func testCollectionSummariesIncludeStatusIndicator() throws {
        let store = makeStore()
        let onHold = try store.add(title: "Waiting", collection: "Inbox")
        _ = try store.add(title: "Later", collection: "Inbox")
        let aborted = try store.add(title: "Canceled", collection: "Work")

        try store.setStatus(.onHold, ids: [onHold.id])
        try store.setStatus(.aborted, ids: [aborted.id])

        let summaries = Dictionary(uniqueKeysWithValues: try store.collectionSummaries().map { ($0.name, $0) })

        XCTAssertEqual(summaries["Inbox"]?.statusIndicator, .onHold)
        XCTAssertEqual(summaries["Work"]?.statusIndicator, .aborted)
    }

    func testCollectionSummariesPutDefaultCollectionFirst() throws {
        let store = makeStore()
        try store.createCollection(name: "Zoo")
        try store.createCollection(name: TodoStore.defaultCollection)
        try store.createCollection(name: "Archive")

        XCTAssertEqual(
            try store.collectionSummaries().map(\.name),
            [TodoStore.defaultCollection, "Archive", "Zoo"]
        )
    }

    func testCollectionSummaryStatusIndicatorPrioritizesAborted() throws {
        let store = makeStore()
        let onHold = try store.add(title: "Waiting", collection: "Inbox")
        let aborted = try store.add(title: "Canceled", collection: "Inbox")

        try store.setStatus(.onHold, ids: [onHold.id])
        try store.setStatus(.aborted, ids: [aborted.id])

        XCTAssertEqual(try store.collectionSummaries().first?.statusIndicator, .aborted)
    }

    func testWrittenJSONUsesFlatStatusField() throws {
        let store = makeStore()
        let item = try store.add(title: "One", collection: "Inbox")

        try store.setStatus(.onHold, ids: [item.id])

        let json = try XCTUnwrap(String(data: Data(contentsOf: store.fileURL), encoding: .utf8))
        XCTAssertTrue(json.contains(#""version" : 5"#))
        XCTAssertTrue(json.contains(#""collectionColors""#))
        XCTAssertTrue(json.contains(#""status" : "on-hold""#))
        XCTAssertFalse(json.contains("isDone"))
        XCTAssertFalse(json.contains("isLocked"))
    }

    func testRenameCollectionMovesItems() throws {
        let store = makeStore()
        let item = try store.add(title: "One", collection: "Inbox")

        try store.renameCollection(from: "Inbox", to: "Database")

        let current = try XCTUnwrap(try store.items(ids: [item.id]).first)
        XCTAssertEqual(current.collection, "Database")
        XCTAssertEqual(
            try store.collectionSummaries(),
            [TodoCollectionSummary(name: "Database", totalCount: 1, incompleteCount: 1)]
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
            [TodoCollectionSummary(name: "Work", totalCount: 2, incompleteCount: 2)]
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
                TodoCollectionSummary(name: "Empty", totalCount: 0, incompleteCount: 0),
                TodoCollectionSummary(name: "Work", totalCount: 1, incompleteCount: 1)
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

        XCTAssertThrowsError(try store.setStatus(.completed, ids: [item.id], collection: "Inbox")) { error in
            XCTAssertEqual(error as? TodoStoreError, .targetConflict)
        }
    }

    func testEmptyCollectionTargetIsRejectedForMutations() throws {
        let store = makeStore()
        _ = try store.add(title: "One", collection: "Inbox")

        XCTAssertThrowsError(try store.setStatus(.completed, collection: " ")) { error in
            XCTAssertEqual(error as? TodoStoreError, .invalidCollection)
        }

        XCTAssertThrowsError(try store.delete(collection: "")) { error in
            XCTAssertEqual(error as? TodoStoreError, .invalidCollection)
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
                TodoCollectionSummary(name: "Inbox", totalCount: 0, incompleteCount: 0),
                TodoCollectionSummary(name: "Work", totalCount: 1, incompleteCount: 1)
            ]
        )
    }

    func testClearItemsDeletesAllItems() throws {
        let store = makeStore()
        let first = try store.add(title: "One", collection: "Inbox")
        let second = try store.add(title: "Two", collection: "Inbox")
        try store.setStatus(.inProgress, ids: [second.id])

        let deleted = try store.clearItems(collection: "Inbox")

        XCTAssertEqual(Set(deleted.map(\.id)), Set([first.id, second.id]))
        XCTAssertEqual(try store.items(collection: "Inbox"), [])
    }

    func testClearCompletedItemsOnlyDeletesCompletedItems() throws {
        let store = makeStore()
        let completed = try store.add(title: "Completed", collection: "Inbox")
        let inProgress = try store.add(title: "In progress", collection: "Inbox")
        let ready = try store.add(title: "Ready", collection: "Inbox")
        try store.setStatus(.completed, ids: [completed.id])
        try store.setStatus(.inProgress, ids: [inProgress.id])

        let deleted = try store.clearItems(collection: "Inbox", completedOnly: true)

        XCTAssertEqual(deleted.map(\.id), [completed.id])
        XCTAssertEqual(try store.items(collection: "Inbox").map(\.id), [inProgress.id, ready.id])
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
            .appendingPathComponent("PondTests-\(UUID().uuidString)", isDirectory: true)
        return TodoStore(fileURL: directory.appendingPathComponent("todos.json"))
    }

    private func writeLegacyStore(items: [LegacyTodoItem], to fileURL: URL) throws {
        let file = LegacyTodoFile(
            version: 1,
            items: items
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
        var isLocked: Bool
        var createdAt: Date
        var updatedAt: Date
    }
}
