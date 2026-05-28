import XCTest
@testable import TaskCore

final class TaskStoreTests: XCTestCase {
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

        for status in TaskStatus.allCases {
            let changed = try store.setStatus(status, ids: [String(item.id.prefix(4))])

            XCTAssertEqual(changed.map(\.id), [item.id])
            XCTAssertEqual(changed.map(\.status), [status])
        }
    }

    func testDraftStatusIsPersistedAndIncomplete() throws {
        let store = makeStore()
        let item = try store.add(title: "One", collection: "Inbox", status: .draft)

        XCTAssertEqual(try store.items(status: .draft).map(\.id), [item.id])
        XCTAssertEqual(
            try store.collectionSummaries(),
            [TaskCollectionSummary(name: "Inbox", totalCount: 1, incompleteCount: 1)]
        )

        let json = try XCTUnwrap(String(data: Data(contentsOf: store.fileURL), encoding: .utf8))
        XCTAssertTrue(json.contains(#""status" : "draft""#))
    }

    func testReadyDisplayNameIsReady() {
        XCTAssertEqual(TaskStatus.ready.displayName, "Ready")
    }

    func testPromptTemplateReplacesKnownVariablesAndPreservesUnknownVariables() {
        let template = TaskPromptTemplate("Run {{cliCommand}} for {{ collectionName }} and keep {{unknown}}.")

        XCTAssertEqual(
            template.evaluated(
                variables: [
                    "cliCommand": "taskpond item get --collection Inbox",
                    "collectionName": "Inbox"
                ]
            ),
            "Run taskpond item get --collection Inbox for Inbox and keep {{unknown}}."
        )
    }

    func testAddedItemsHaveRandomAlphanumericVersions() throws {
        let store = makeStore()
        let item = try store.add(title: "One", collection: "Inbox")

        XCTAssertEqual(item.version.count, 12)
        XCTAssertTrue(item.version.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains))
    }

    func testStatusOrderPutsDraftBeforeReady() {
        XCTAssertEqual(Array(TaskStatus.allCases.prefix(2)), [.draft, .ready])
        XCTAssertEqual(Array(TaskStatus.allCases.suffix(3)), [.onHold, .rejected, .aborted])
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
            status: .onHold
        )

        XCTAssertEqual(updated.id, item.id)
        XCTAssertNotEqual(updated.version, item.version)
        XCTAssertEqual(updated.title, "Two")
        XCTAssertEqual(updated.collection, "Work")
        XCTAssertEqual(updated.status, .onHold)

        let persisted = try XCTUnwrap(try store.items(ids: [item.id]).first)
        XCTAssertEqual(persisted.id, item.id)
        XCTAssertEqual(persisted.version, updated.version)
        XCTAssertEqual(persisted.title, "Two")
        XCTAssertEqual(persisted.collection, "Work")
        XCTAssertEqual(persisted.status, .onHold)
    }

    func testUpdatePreservesVersionWhenFieldsAlreadyMatch() throws {
        let store = makeStore()
        let item = try store.add(title: "One", collection: "Inbox")

        let updated = try store.update(
            id: item.id,
            title: "Two",
            collection: "Work",
            status: .ready
        )
        let repeated = try store.update(
            id: item.id,
            title: "Two",
            collection: "Work",
            status: .ready
        )

        XCTAssertEqual(repeated.version, updated.version)
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
            [TaskCollectionSummary(name: "Personal", totalCount: 0, incompleteCount: 0)]
        )
    }

    func testCollectionColorIsPersisted() throws {
        let store = makeStore()
        try store.createCollection(name: "Personal")

        let updated = try store.setCollectionColor(name: "Personal", color: .blue)

        XCTAssertEqual(updated.color, .blue)
        XCTAssertEqual(
            try store.collectionSummaries(),
            [TaskCollectionSummary(name: "Personal", totalCount: 0, incompleteCount: 0, color: .blue)]
        )

        let reloadedStore = TaskStore(fileURL: store.fileURL)
        XCTAssertEqual(try reloadedStore.collectionSummaries().map(\.color), [.blue])
    }

    func testRenameCollectionCarriesColor() throws {
        let store = makeStore()
        try store.createCollection(name: "Inbox")
        try store.setCollectionColor(name: "Inbox", color: .green)

        try store.renameCollection(from: "Inbox", to: "Personal")

        XCTAssertEqual(
            try store.collectionSummaries(),
            [TaskCollectionSummary(name: "Personal", totalCount: 0, incompleteCount: 0, color: .green)]
        )
    }

    func testCollectionArchiveStatusIsPersisted() throws {
        let store = makeStore()
        try store.createCollection(name: "Inbox")

        let archived = try store.setCollectionArchived(name: "Inbox", isArchived: true)

        XCTAssertTrue(archived.isArchived)
        XCTAssertEqual(
            try store.collectionSummaries(),
            [TaskCollectionSummary(name: "Inbox", totalCount: 0, incompleteCount: 0, isArchived: true)]
        )

        let reloadedStore = TaskStore(fileURL: store.fileURL)
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
            [TaskCollectionSummary(name: "Personal", totalCount: 0, incompleteCount: 0, isArchived: true)]
        )
    }

    func testCollectionPromptIsPersisted() throws {
        let store = makeStore()
        try store.createCollection(name: "Inbox")

        let updated = try store.setCollectionPrompt(
            name: "Inbox",
            promptTemplate: "Run {{cliCommand}} for {{collectionName}}."
        )

        XCTAssertEqual(updated.promptTemplate, "Run {{cliCommand}} for {{collectionName}}.")
        XCTAssertEqual(
            try store.collectionSummaries(),
            [
                TaskCollectionSummary(
                    name: "Inbox",
                    totalCount: 0,
                    incompleteCount: 0,
                    promptTemplate: "Run {{cliCommand}} for {{collectionName}}."
                )
            ]
        )

        let reloadedStore = TaskStore(fileURL: store.fileURL)
        XCTAssertEqual(
            try reloadedStore.collectionSummaries().map(\.promptTemplate),
            ["Run {{cliCommand}} for {{collectionName}}."]
        )

        let json = try XCTUnwrap(String(data: Data(contentsOf: store.fileURL), encoding: .utf8))
        XCTAssertTrue(json.contains(#""collectionPrompts""#))
        XCTAssertTrue(json.contains(#""Inbox" : "Run {{cliCommand}} for {{collectionName}}.""#))
    }

    func testBlankCollectionPromptRemovesOverride() throws {
        let store = makeStore()
        try store.createCollection(name: "Inbox")
        try store.setCollectionPrompt(name: "Inbox", promptTemplate: "Custom")

        let updated = try store.setCollectionPrompt(name: "Inbox", promptTemplate: " \n ")

        XCTAssertNil(updated.promptTemplate)
        XCTAssertEqual(try store.collectionSummaries().map(\.promptTemplate), [nil])

        let json = try XCTUnwrap(String(data: Data(contentsOf: store.fileURL), encoding: .utf8))
        XCTAssertFalse(json.contains("Custom"))
    }

    func testRenameCollectionCarriesPromptUnlessTargetHasPrompt() throws {
        let store = makeStore()
        try store.createCollection(name: "Inbox")
        try store.setCollectionPrompt(name: "Inbox", promptTemplate: "Inbox Prompt")

        try store.renameCollection(from: "Inbox", to: "Personal")

        XCTAssertEqual(
            try store.collectionSummaries(),
            [
                TaskCollectionSummary(
                    name: "Personal",
                    totalCount: 0,
                    incompleteCount: 0,
                    promptTemplate: "Inbox Prompt"
                )
            ]
        )

        try store.createCollection(name: "Work")
        try store.setCollectionPrompt(name: "Work", promptTemplate: "Work Prompt")
        try store.renameCollection(from: "Personal", to: "Work")

        XCTAssertEqual(
            try store.collectionSummaries(),
            [
                TaskCollectionSummary(
                    name: "Work",
                    totalCount: 0,
                    incompleteCount: 0,
                    promptTemplate: "Work Prompt"
                )
            ]
        )
    }

    func testDeletingCollectionsRemovesPromptMetadata() throws {
        let store = makeStore()
        try store.createCollection(name: "Empty")
        try store.setCollectionPrompt(name: "Empty", promptTemplate: "Empty Prompt")

        XCTAssertTrue(try store.deleteEmptyCollection(name: "Empty"))

        var json = try XCTUnwrap(String(data: Data(contentsOf: store.fileURL), encoding: .utf8))
        XCTAssertFalse(json.contains("Empty Prompt"))

        _ = try store.add(title: "One", collection: "Work")
        try store.setCollectionPrompt(name: "Work", promptTemplate: "Work Prompt")

        XCTAssertTrue(try store.deleteCollection(name: "Work"))

        json = try XCTUnwrap(String(data: Data(contentsOf: store.fileURL), encoding: .utf8))
        XCTAssertFalse(json.contains("Work Prompt"))
    }

    func testLegacyStoreBuildsCollectionsFromItems() throws {
        let store = makeStore()
        let date = Date(timeIntervalSince1970: 0)
        let completedLocked = LegacyTaskItem(
            id: "feedbeef",
            title: "Done locked",
            collection: "Legacy",
            isDone: true,
            isLocked: true,
            createdAt: date,
            updatedAt: date
        )
        let locked = LegacyTaskItem(
            id: "cafebabe",
            title: "Locked",
            collection: "Legacy",
            isDone: false,
            isLocked: true,
            createdAt: date,
            updatedAt: date
        )
        let ready = LegacyTaskItem(
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
            [TaskCollectionSummary(name: "Legacy", totalCount: 3, incompleteCount: 2)]
        )
        XCTAssertEqual(try store.collectionSummaries().map(\.color), [.gray])

        let statuses = Dictionary(uniqueKeysWithValues: try store.items().map { ($0.id, $0.status) })
        XCTAssertEqual(statuses["feedbeef"], .completed)
        XCTAssertEqual(statuses["cafebabe"], .inProgress)
        XCTAssertEqual(statuses["deadbeef"], .ready)
        let json = try XCTUnwrap(String(data: Data(contentsOf: store.fileURL), encoding: .utf8))
        XCTAssertTrue(json.contains(#""version" : 6"#))
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
        try store.createCollection(name: TaskStore.defaultCollection)
        try store.createCollection(name: "Archive")

        XCTAssertEqual(
            try store.collectionSummaries().map(\.name),
            [TaskStore.defaultCollection, "Archive", "Zoo"]
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
        XCTAssertTrue(json.contains(#""version" : 6"#))
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
            [TaskCollectionSummary(name: "Database", totalCount: 1, incompleteCount: 1)]
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
            [TaskCollectionSummary(name: "Work", totalCount: 2, incompleteCount: 2)]
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
                TaskCollectionSummary(name: "Empty", totalCount: 0, incompleteCount: 0),
                TaskCollectionSummary(name: "Work", totalCount: 1, incompleteCount: 1)
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
            XCTAssertEqual(error as? TaskStoreError, .collectionNotFound("Missing"))
        }
    }

    func testEmptyCollectionNamesAreRejected() throws {
        let store = makeStore()
        try store.createCollection(name: "Inbox")

        XCTAssertThrowsError(try store.createCollection(name: "   ")) { error in
            XCTAssertEqual(error as? TaskStoreError, .invalidCollection)
        }
        XCTAssertThrowsError(try store.renameCollection(from: "Inbox", to: "\n")) { error in
            XCTAssertEqual(error as? TaskStoreError, .invalidCollection)
        }
        XCTAssertThrowsError(try store.deleteCollection(name: " ")) { error in
            XCTAssertEqual(error as? TaskStoreError, .invalidCollection)
        }
    }

    func testCollectionAndIDTargetsConflict() throws {
        let store = makeStore()
        let item = try store.add(title: "One")

        XCTAssertThrowsError(try store.setStatus(.completed, ids: [item.id], collection: "Inbox")) { error in
            XCTAssertEqual(error as? TaskStoreError, .targetConflict)
        }
    }

    func testEmptyCollectionTargetIsRejectedForMutations() throws {
        let store = makeStore()
        _ = try store.add(title: "One", collection: "Inbox")

        XCTAssertThrowsError(try store.setStatus(.completed, collection: " ")) { error in
            XCTAssertEqual(error as? TaskStoreError, .invalidCollection)
        }

        XCTAssertThrowsError(try store.delete(collection: "")) { error in
            XCTAssertEqual(error as? TaskStoreError, .invalidCollection)
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
                TaskCollectionSummary(name: "Inbox", totalCount: 0, incompleteCount: 0),
                TaskCollectionSummary(name: "Work", totalCount: 1, incompleteCount: 1)
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
            XCTAssertEqual(error as? TaskStoreError, .duplicateID("feedbeef"))
        }
    }

    func testAddRejectsEmptyTitleUnlessAllowed() throws {
        let store = makeStore()

        XCTAssertThrowsError(try store.add(title: " \n\t ")) { error in
            XCTAssertEqual(error as? TaskStoreError, .invalidTitle)
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

    func testRejectedStatusIsPersistedAndShownAsCollectionIndicator() throws {
        let store = makeStore()
        let item = try store.add(title: "One", collection: "Inbox")

        try store.setStatus(.rejected, ids: [item.id])

        XCTAssertEqual(try store.items(status: .rejected).map(\.id), [item.id])
        XCTAssertEqual(try store.collectionSummaries().first?.statusIndicator, .rejected)

        let json = try XCTUnwrap(String(data: Data(contentsOf: store.fileURL), encoding: .utf8))
        XCTAssertTrue(json.contains(#""status" : "rejected""#))
    }

    func testNotesCanBeAddedUpdatedDeletedAndPersistVersions() throws {
        let store = makeStore()
        let item = try store.add(title: "One", collection: "Inbox")

        let withNote = try store.addNote(
            id: item.id,
            body: " Looks good "
        )
        let note = try XCTUnwrap(withNote.notes.first)

        XCTAssertEqual(note.body, "Looks good")
        XCTAssertEqual(note.version.count, 12)
        XCTAssertNotEqual(withNote.version, item.version)

        let updated = try store.updateNote(
            id: item.id,
            noteID: note.id,
            body: "Updated"
        )
        let updatedNote = try XCTUnwrap(updated.notes.first)

        XCTAssertEqual(updatedNote.body, "Updated")
        XCTAssertNotEqual(updatedNote.version, note.version)

        let json = try XCTUnwrap(String(data: Data(contentsOf: store.fileURL), encoding: .utf8))
        XCTAssertFalse(json.contains(#""author""#))
        XCTAssertFalse(json.contains(#""title" : "Decision""#))
        XCTAssertFalse(json.contains(#""notes""#))
        XCTAssertTrue(json.contains(#""note""#))

        let unchanged = try store.updateNote(
            id: item.id,
            noteID: note.id,
            body: "Updated"
        )

        XCTAssertEqual(unchanged.notes.first?.version, updatedNote.version)

        let reloadedStore = TaskStore(fileURL: store.fileURL)
        XCTAssertEqual(try reloadedStore.items(ids: [item.id]).first?.notes.first?.body, "Updated")

        let withoutNote = try reloadedStore.deleteNote(id: item.id)
        XCTAssertEqual(withoutNote.notes, [])
    }

    private func makeStore() -> TaskStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PondTests-\(UUID().uuidString)", isDirectory: true)
        return TaskStore(fileURL: directory.appendingPathComponent("tasks.json"))
    }

    private func writeLegacyStore(items: [LegacyTaskItem], to fileURL: URL) throws {
        let file = LegacyTaskFile(
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

    private struct LegacyTaskFile: Encodable {
        var version: Int
        var items: [LegacyTaskItem]
    }

    private struct LegacyTaskItem: Encodable {
        var id: String
        var title: String
        var collection: String
        var isDone: Bool
        var isLocked: Bool
        var createdAt: Date
        var updatedAt: Date
    }
}
