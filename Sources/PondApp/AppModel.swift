import AppKit
import Darwin
import Dispatch
import Observation
import OSLog
import SwiftUI
import TaskCore
import UniformTypeIdentifiers

struct TaskBulkStatusChangeRequest: Identifiable {
    let id = UUID()
    let title: String
    let ids: [String]?
    let collection: String?
    let itemCount: Int
}

struct TaskCollectionPromptEditRequest: Identifiable {
    let collection: TaskCollectionSummary

    var id: String {
        collection.name
    }
}

@MainActor
@Observable
final class TaskAppModel {
    static let allCollectionID = "__all__"
    private static let usesAutoDraftKey = "usesAutoDraft"
    private static let sidebarDragLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.kymok.pond",
        category: "SidebarDrag"
    )

    var items: [TaskItem] = []
    var collectionSummaries: [TaskCollectionSummary] = []
    var collectionGroupSummaries: [TaskCollectionGroupSummary] = []
    var selectedCollection: String
    var searchText = ""
    var showsIncompleteOnly = false
    var showsArchivedCollections = false {
        didSet {
            if !showsArchivedCollections, selectedCollectionSummary?.isArchived == true {
                selectedCollection = Self.allCollectionID
            }
        }
    }
    var usesAutoDraft: Bool {
        didSet {
            UserDefaults.standard.set(usesAutoDraft, forKey: Self.usesAutoDraftKey)
        }
    }
    var errorMessage: String?
    var cliStatus: CLIInstallStatus?
    var collectionDeletionRequest: TaskCollectionSummary?
    var bulkStatusChangeRequest: TaskBulkStatusChangeRequest?
    var collectionPromptEditRequest: TaskCollectionPromptEditRequest?
    var groupEditingRequest: String?
    private var recentlyCompletedVisibleIDs: Set<String> = []

    @ObservationIgnored private let store: TaskStore
    @ObservationIgnored private let installer: CommandLineInstaller
    @ObservationIgnored private var storeChangeMonitor: StoreChangeMonitor?
    @ObservationIgnored private var completedHideTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var hasLoadedItems = false

    init(
        store: TaskStore = TaskStore(),
        installer: CommandLineInstaller = CommandLineInstaller(),
        initialSelectedCollection: String = TaskAppModel.allCollectionID
    ) {
        self.store = store
        self.installer = installer
        selectedCollection = initialSelectedCollection
        usesAutoDraft = UserDefaults.standard.object(forKey: Self.usesAutoDraftKey) as? Bool ?? true
        reload()
        refreshCLIStatus()
        startStoreChangeMonitor()
    }

    var selectedCollectionName: String? {
        selectedCollection == Self.allCollectionID ? nil : selectedCollection
    }

    var title: String {
        selectedCollectionName ?? "All"
    }

    var collectionNames: [String] {
        visibleCollectionSummaries.map(\.displayName)
    }

    var visibleCollectionSummaries: [TaskCollectionSummary] {
        collectionSummaries.filter { !$0.isArchived }
    }

    var editableCollectionGroups: [TaskCollectionGroupSummary] {
        collectionGroups(showingArchived: false)
    }

    var visibleCollectionGroups: [TaskCollectionGroupSummary] {
        collectionGroups(showingArchived: showsArchivedCollections)
    }

    var navigableCollectionIDs: [String] {
        [Self.allCollectionID]
            + visibleCollectionGroups.flatMap { $0.collections.map(\.name) }
    }

    var selectedCollectionSummary: TaskCollectionSummary? {
        guard let selectedCollectionName else {
            return nil
        }

        return collectionSummaries.first { $0.name == selectedCollectionName }
    }

    func collectionColor(named name: String) -> TaskCollectionColor {
        collectionSummaries.first { $0.name == name }?.color ?? .gray
    }

    func collectionGroupDisplayName(_ group: String) -> String {
        group == TaskStore.defaultCollectionGroup ? "No Group" : group
    }

    func selectAdjacentCollection(offset: Int) {
        let collectionIDs = navigableCollectionIDs
        guard let currentIndex = collectionIDs.firstIndex(of: selectedCollection) else {
            selectedCollection = collectionIDs.first ?? Self.allCollectionID
            return
        }

        let nextIndex = currentIndex + offset
        guard collectionIDs.indices.contains(nextIndex) else {
            return
        }

        selectedCollection = collectionIDs[nextIndex]
    }

    var canDeleteSelectedCollection: Bool {
        selectedCollectionSummary.map { !isDefaultCollection($0) } ?? false
    }

    var visibleItems: [TaskItem] {
        items.filter { itemIsVisible($0, keepsRecentlyCompletedVisible: true) }
    }

    func itemIsVisible(_ item: TaskItem, keepsRecentlyCompletedVisible: Bool = false) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let collectionMatches = selectedCollectionName.map { $0 == item.collection } ?? true
        let statusMatches = !showsIncompleteOnly
            || item.status.isIncomplete
            || (keepsRecentlyCompletedVisible && recentlyCompletedVisibleIDs.contains(item.id))
        let searchMatches = query.isEmpty
            || item.title.localizedCaseInsensitiveContains(query)
            || item.collection.localizedCaseInsensitiveContains(query)
            || item.id.localizedCaseInsensitiveContains(query)

        return collectionMatches && statusMatches && searchMatches
    }

    var totalIncompleteCount: Int {
        collectionSummaries.reduce(0) { $0 + $1.incompleteCount }
    }

    func reload() {
        do {
            let previousStatuses = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.status) })
            let loadedItems = try store.items()
            updateRecentlyCompletedVisibility(previousStatuses: previousStatuses, loadedItems: loadedItems)
            items = loadedItems
            collectionSummaries = try store.collectionSummaries()
            collectionGroupSummaries = try store.collectionGroupSummaries()

            if selectedCollectionName != nil && !collectionSummaries.contains(where: { $0.name == selectedCollection }) {
                selectedCollection = Self.allCollectionID
            }
            if selectedCollectionSummary?.isArchived == true, !showsArchivedCollections {
                selectedCollection = Self.allCollectionID
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func createTask(
        title: String,
        collection: String? = nil,
        id: String? = nil,
        allowEmptyTitle: Bool = false,
        status: TaskStatus = .draft
    ) -> TaskItem? {
        updateStore(reloadOnError: false) {
            try store.add(
                title: title,
                collection: collection ?? selectedCollectionName ?? TaskStore.defaultCollection,
                id: id,
                allowEmptyTitle: allowEmptyTitle,
                status: status
            )
        }
    }

    func createTaskInBackground(
        title: String,
        collection: String? = nil,
        id: String? = nil,
        allowEmptyTitle: Bool = false,
        status: TaskStatus = .draft,
        disablesAnimations: Bool = false,
        completion: @escaping (TaskItem?) -> Void
    ) {
        let store = store
        let collection = collection ?? selectedCollectionName ?? TaskStore.defaultCollection

        Task { @MainActor in
            do {
                let item = try await Task.detached {
                    try store.add(
                        title: title,
                        collection: collection,
                        id: id,
                        allowEmptyTitle: allowEmptyTitle,
                        status: status
                    )
                }.value
                reload(disablesAnimations: disablesAnimations)
                completion(item)
            } catch {
                errorMessage = error.localizedDescription
                reload(disablesAnimations: disablesAnimations)
                completion(nil)
            }
        }
    }

    @discardableResult
    func createEmptyTask(id: String? = nil, collection: String? = nil) -> TaskItem? {
        createTask(title: "", collection: collection, id: id, allowEmptyTitle: true)
    }

    @discardableResult
    func createCollectionForEditing(group: String = TaskStore.defaultCollectionGroup) -> String? {
        let name = uniqueCollectionName(base: "New Collection", group: group)

        return updateStore(reloadOnError: false) {
            let createdName = try store.createCollection(name: name, group: group)
            selectedCollection = createdName
            return createdName
        }
    }

    @discardableResult
    func createCollectionGroupForEditing() -> String? {
        let name = uniqueCollectionGroupName(base: "New Group")

        return updateStore(reloadOnError: false) {
            let createdName = try store.createCollectionGroup(name: name)
            groupEditingRequest = createdName
            return createdName
        }
    }

    @discardableResult
    func createCollectionGroupAndMoveCollectionForEditing(_ collection: TaskCollectionSummary) -> String? {
        guard !isDefaultCollection(collection) else {
            return nil
        }

        let name = uniqueCollectionGroupName(base: "New Group")

        return updateStore(reloadOnError: false, ignoring: isStaleCollection) {
            let createdName = try store.createCollectionGroup(name: name)
            let moved = try store.moveCollection(name: collection.name, toGroup: createdName)
            if selectedCollection == collection.name {
                selectedCollection = moved.name
            }
            groupEditingRequest = createdName
            return createdName
        }
    }

    func clearGroupEditingRequest(_ group: String) {
        if groupEditingRequest == group {
            groupEditingRequest = nil
        }
    }

    @discardableResult
    func renameCollectionGroup(from oldName: String, to newName: String) -> String? {
        let cleanName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            reload()
            return nil
        }

        let finalName = uniqueCollectionGroupName(base: cleanName, excluding: oldName)
        let selectedReplacement = replacementSelectedCollectionName(
            whenRenamingGroup: oldName,
            to: finalName
        )

        return updateStore(disablesAnimations: true, ignoring: isStaleCollectionGroup) {
            let renamedGroup = try store.renameCollectionGroup(from: oldName, to: finalName)
            if let selectedReplacement {
                selectedCollection = selectedReplacement
            }
            return renamedGroup
        }
    }

    @discardableResult
    func deleteCollectionGroup(_ name: String) -> Bool {
        updateStore(ignoring: isStaleCollectionGroup) {
            try store.deleteCollectionGroup(name: name)
        } ?? false
    }

    func canDeleteCollectionGroup(_ name: String) -> Bool {
        name != TaskStore.defaultCollectionGroup
    }

    func isDefaultCollection(_ collection: TaskCollectionSummary) -> Bool {
        collection.name == TaskStore.defaultCollection
    }

    func moveCollection(_ collection: TaskCollectionSummary, toGroup group: String) {
        guard !isDefaultCollection(collection) else {
            return
        }

        updateStore(ignoring: isStaleCollection) {
            let finalName = uniqueCollectionName(
                base: collection.displayName,
                group: group,
                excluding: collection.name
            )
            let targetName = collectionAPIName(group: group, displayName: finalName)
            let movedName: String
            if targetName == collectionAPIName(group: group, displayName: collection.displayName) {
                movedName = try store.moveCollection(name: collection.name, toGroup: group).name
            } else {
                movedName = try store.renameCollection(from: collection.name, to: targetName)
            }

            if selectedCollection == collection.name {
                selectedCollection = movedName
            }
        }
    }

    @discardableResult
    func reorderCollection(
        name: String,
        toGroup group: String,
        after previousName: String?,
        before nextName: String?
    ) -> Bool {
        guard let collection = collectionSummaries.first(where: { $0.name == name }),
              !isDefaultCollection(collection) else {
            Self.sidebarDragLogger.info("Collection reorder skipped for invalid source '\(name, privacy: .public)'")
            return false
        }

        do {
            let sourceName = try prepareCollectionForReorder(collection, toGroup: group)
            let moved = try store.reorderCollection(
                name: sourceName,
                toGroup: group,
                after: collection.isArchived ? nil : previousName,
                before: collection.isArchived ? nil : nextName
            )
            if selectedCollection == collection.name {
                selectedCollection = moved.name
            }
            reload()
            Self.sidebarDragLogger.info(
                "Collection reorder succeeded source='\(name, privacy: .public)' result='\(moved.name, privacy: .public)' group='\(group, privacy: .public)'"
            )
            return true
        } catch {
            errorMessage = error.localizedDescription
            reload()
            Self.sidebarDragLogger.error(
                "Collection reorder failed source='\(name, privacy: .public)' group='\(group, privacy: .public)' error='\(error.localizedDescription, privacy: .public)'"
            )
            return false
        }
    }

    @discardableResult
    func reorderCollectionGroup(name: String, after previousName: String?, before nextName: String?) -> Bool {
        guard name != TaskStore.defaultCollectionGroup else {
            Self.sidebarDragLogger.info("Group reorder skipped for default group")
            return false
        }

        do {
            _ = try store.reorderCollectionGroup(name: name, after: previousName, before: nextName)
            reload()
            Self.sidebarDragLogger.info(
                "Group reorder succeeded source='\(name, privacy: .public)' after='\(previousName ?? "", privacy: .public)' before='\(nextName ?? "", privacy: .public)'"
            )
            return true
        } catch {
            errorMessage = error.localizedDescription
            reload()
            Self.sidebarDragLogger.error(
                "Group reorder failed source='\(name, privacy: .public)' after='\(previousName ?? "", privacy: .public)' before='\(nextName ?? "", privacy: .public)' error='\(error.localizedDescription, privacy: .public)'"
            )
            return false
        }
    }

    func mergeCollectionGroup(from sourceName: String, to targetName: String) {
        guard sourceName != TaskStore.defaultCollectionGroup,
              sourceName != targetName,
              let sourceGroup = collectionGroupSummaries.first(where: { $0.name == sourceName }) else {
            return
        }

        var usedDisplayNames = Set(
            collectionGroupSummaries
                .first { $0.name == targetName }?
                .collections
                .map(\.displayName) ?? []
        )
        var selectedReplacement: String?

        updateStore(ignoring: isStaleCollectionGroup) {
            for collection in sourceGroup.collections {
                let displayName = uniqueName(base: collection.displayName, usedNames: &usedDisplayNames)
                let movedName = try store.renameCollection(
                    from: collection.name,
                    to: collectionAPIName(group: targetName, displayName: displayName)
                )

                if selectedCollection == collection.name {
                    selectedReplacement = movedName
                }
            }

            let deleted = try store.deleteCollectionGroup(name: sourceName)
            if let selectedReplacement {
                selectedCollection = selectedReplacement
            }
            return deleted
        }
    }

    @discardableResult
    func renameCollection(from oldName: String, to newName: String) -> String? {
        guard oldName != TaskStore.defaultCollection else {
            reload()
            return nil
        }

        guard !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            reload()
            return nil
        }

        return updateStore(ignoring: isMissingCollection) {
            let targetName = uniqueCollectionName(
                oldName: oldName,
                requestedName: newName
            ) ?? newName
            let finalName = try store.renameCollection(from: oldName, to: targetName)
            selectedCollection = finalName
            return finalName
        }
    }

    @discardableResult
    func deleteEmptyCollection(_ name: String) -> Bool {
        guard name != TaskStore.defaultCollection else {
            reload()
            return false
        }

        return updateStore(ignoring: isInvalidCollection) {
            let deleted = try store.deleteEmptyCollection(name: name)
            if deleted && selectedCollection == name {
                selectedCollection = Self.allCollectionID
            }
            return deleted
        } ?? false
    }

    func requestDeleteSelectedCollection() {
        guard let selectedCollectionSummary else {
            return
        }

        requestDeleteCollection(selectedCollectionSummary)
    }

    func requestDeleteCollection(_ collection: TaskCollectionSummary) {
        guard !isDefaultCollection(collection) else {
            return
        }

        collectionDeletionRequest = collection
    }

    func setCollectionColor(_ collection: TaskCollectionSummary, color: TaskCollectionColor) {
        updateStore(ignoring: isStaleCollection) {
            try store.setCollectionColor(name: collection.name, color: color)
        }
    }

    func setCollectionArchived(_ collection: TaskCollectionSummary, isArchived: Bool) {
        updateStore(ignoring: isStaleCollection) {
            try store.setCollectionArchived(name: collection.name, isArchived: isArchived)
            if isArchived && selectedCollection == collection.name && !showsArchivedCollections {
                selectedCollection = Self.allCollectionID
            }
        }
    }

    func requestCollectionPromptEdit(_ collection: TaskCollectionSummary) {
        collectionPromptEditRequest = TaskCollectionPromptEditRequest(collection: collection)
    }

    func cancelCollectionPromptEdit() {
        collectionPromptEditRequest = nil
    }

    func confirmCollectionPromptEdit(_ collection: TaskCollectionSummary, promptTemplate: String) {
        collectionPromptEditRequest = nil
        setCollectionPrompt(collection, promptTemplate: promptTemplate)
    }

    func setCollectionPrompt(_ collection: TaskCollectionSummary, promptTemplate: String?) {
        updateStore(ignoring: isStaleCollection) {
            try store.setCollectionPrompt(name: collection.name, promptTemplate: promptTemplate)
        }
    }

    func canClearItems(in collection: TaskCollectionSummary) -> Bool {
        items.contains { $0.collection == collection.name }
    }

    func canClearCompletedItems(in collection: TaskCollectionSummary) -> Bool {
        items.contains { $0.collection == collection.name && $0.status == .completed }
    }

    func exportCollection(_ collection: TaskCollectionSummary) {
        do {
            let items = try store.items(collection: collection.name)
            let payload = CollectionExportPayload(
                collection: collection.name,
                exportedAt: Date(),
                items: items
            )

            CollectionExportDestination.choose(for: collection.name) { [weak self] export in
                guard let self, let export else {
                    return
                }

                do {
                    let data = try payload.encoded(as: export.format)
                    try data.write(to: export.url, options: .atomic)
                } catch {
                    self.errorMessage = error.localizedDescription
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func clearItems(in collection: TaskCollectionSummary, completedOnly: Bool = false) -> Bool {
        updateStore(ignoring: isNoMatchingTasks) {
            _ = try store.clearItems(collection: collection.name, completedOnly: completedOnly)
            return true
        } ?? false
    }

    func cancelDeleteCollection() {
        collectionDeletionRequest = nil
    }

    @discardableResult
    func confirmDeleteRequestedCollection() -> Bool {
        guard let collection = collectionDeletionRequest else {
            return false
        }

        collectionDeletionRequest = nil
        return deleteCollection(collection.name)
    }

    @discardableResult
    func deleteCollection(_ name: String) -> Bool {
        guard name != TaskStore.defaultCollection else {
            reload()
            return false
        }

        return updateStore(ignoring: isStaleCollection) {
            let deleted = try store.deleteCollection(name: name)
            if deleted {
                selectedCollection = Self.allCollectionID
            }
            return deleted
        } ?? false
    }

    func makeTaskID() -> String {
        TaskStore.makeID(existing: Set(items.map(\.id)))
    }

    func advanceStatusFromLeadingClick(_ item: TaskItem) {
        setStatus(item, status: item.status.leadingStatusClickTarget)
    }

    func setStatus(_ item: TaskItem, status: TaskStatus) {
        updateStore(reloadOnError: false, ignoring: isMissingTask) {
            try store.setStatus(status, id: item.id, ifCurrent: item)
        }
    }

    @discardableResult
    func addNote(_ item: TaskItem, body: String) -> TaskItem? {
        updateStore(reloadOnError: false, ignoring: isMissingTask) {
            try store.addNote(id: item.id, body: body, ifCurrent: item)
        }.flatMap { $0 }
    }

    func updateNote(_ item: TaskItem, note: TaskNote, body: String) {
        updateStore(reloadOnError: false, ignoring: isMissingTask) {
            try store.updateNote(id: item.id, noteID: note.id, body: body, ifCurrent: item)
        }
    }

    func deleteNote(_ item: TaskItem, note: TaskNote) {
        updateStore(reloadOnError: false, ignoring: isMissingTask) {
            try store.deleteNote(id: item.id, noteID: note.id, ifCurrent: item)
        }
    }

    var canBulkChangeVisibleStatuses: Bool {
        !visibleItems.isEmpty
    }

    func canBulkChangeStatuses(in collection: TaskCollectionSummary) -> Bool {
        items.contains { $0.collection == collection.name }
    }

    func requestBulkStatusChangeForAll() {
        requestBulkStatusChange(title: "All", items: items)
    }

    func requestBulkStatusChangeForVisibleItems() {
        requestBulkStatusChange(title: title, items: visibleItems)
    }

    func requestBulkStatusChange(for collection: TaskCollectionSummary) {
        let itemCount = items.filter { $0.collection == collection.name }.count
        guard itemCount > 0 else {
            return
        }

        bulkStatusChangeRequest = TaskBulkStatusChangeRequest(
            title: collection.name,
            ids: nil,
            collection: collection.name,
            itemCount: itemCount
        )
    }

    func cancelBulkStatusChange() {
        bulkStatusChangeRequest = nil
    }

    @discardableResult
    func confirmBulkStatusChange(_ replacements: [TaskStatus: TaskStatus]) -> Bool {
        guard let request = bulkStatusChangeRequest else {
            return false
        }

        bulkStatusChangeRequest = nil
        guard !replacements.isEmpty else {
            return true
        }

        return updateStore(ignoring: isNoMatchingTasks) {
            if let collection = request.collection {
                try store.setStatuses(replacements, collection: collection)
            } else {
                try store.setStatuses(replacements, ids: request.ids ?? [])
            }
            return true
        } ?? false
    }

    func rename(
        _ item: TaskItem,
        title: String,
        statusAfterEdit: TaskStatus? = nil
    ) {
        updateStore(reloadOnError: false, ignoring: isMissingTask) {
            try store.updateTitle(id: item.id, title: title, ifCurrent: item, statusAfterEdit: statusAfterEdit)
        }
    }

    @discardableResult
    func renameOrDeleteIfEmpty(
        _ item: TaskItem,
        title: String,
        statusAfterEdit: TaskStatus? = nil
    ) -> Bool {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return delete(item)
        }

        rename(item, title: title, statusAfterEdit: statusAfterEdit)
        return false
    }

    var autoDraftEditStatus: TaskStatus? {
        usesAutoDraft ? .draft : nil
    }

    var autoDraftConfirmationStatus: TaskStatus? {
        usesAutoDraft ? .ready : nil
    }

    func move(_ item: TaskItem, collection: String) {
        do {
            try store.move(id: item.id, collection: collection, ifCurrent: item)
            reload()
        } catch TaskStoreError.notFound {
            if item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = createEmptyTask(id: item.id, collection: collection)
                return
            }

            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reorderItem(id: String, after previousID: String?, before nextID: String?) {
        updateStore(ignoring: isMissingTask) {
            try store.reorder(id: id, after: previousID, before: nextID)
        }
    }

    @discardableResult
    func mergeItem(_ item: TaskItem, into previousItem: TaskItem, title: String) -> TaskItem? {
        updateStore(reloadOnError: false, ignoring: isMissingTask) {
            try store.mergeItem(id: item.id, intoPrevious: previousItem.id, title: title)
        }.flatMap { $0 }
    }

    @discardableResult
    func splitItem(
        _ item: TaskItem,
        firstTitle: String,
        secondTitle: String,
        secondID: String
    ) -> TaskItem? {
        updateStore(reloadOnError: false, ignoring: isMissingTask) {
            try store.splitItem(
                id: item.id,
                firstTitle: firstTitle,
                secondTitle: secondTitle,
                secondID: secondID
            )
        }
    }

    @discardableResult
    func delete(_ item: TaskItem) -> Bool {
        updateStore(reloadOnError: false, ignoring: isMissingTask) {
            try store.delete(id: item.id, ifCurrent: item)
        } ?? false
    }

    @discardableResult
    func delete(id: String) -> Bool {
        updateStore(reloadOnError: false, ignoring: isMissingTask) {
            try store.delete(id: id)
            return true
        } ?? false
    }

    func deleteVisibleItems(at offsets: IndexSet) {
        let itemsToDelete = visibleItems

        for offset in offsets {
            guard itemsToDelete.indices.contains(offset) else {
                continue
            }

            delete(itemsToDelete[offset])
        }
    }

    func refreshCLIStatus() {
        cliStatus = installer.status()
    }

    func installCLI() {
        do {
            try installer.install()
            refreshCLIStatus()
        } catch {
            errorMessage = error.localizedDescription
            refreshCLIStatus()
        }
    }

    func uninstallCLI() {
        do {
            try installer.uninstall()
            refreshCLIStatus()
        } catch {
            errorMessage = error.localizedDescription
            refreshCLIStatus()
        }
    }

    var pathHint: String {
        installer.pathHint
    }

    @discardableResult
    private func updateStore<T>(
        reloadOnError: Bool = true,
        disablesAnimations: Bool = false,
        ignoring shouldIgnoreError: (Error) -> Bool = { _ in false },
        _ update: () throws -> T
    ) -> T? {
        do {
            let result = try update()
            reload(disablesAnimations: disablesAnimations)
            return result
        } catch {
            let isIgnored = shouldIgnoreError(error)
            if !isIgnored {
                errorMessage = error.localizedDescription
            }
            if reloadOnError || isIgnored {
                reload(disablesAnimations: disablesAnimations)
            }
            return nil
        }
    }

    private func reload(disablesAnimations: Bool) {
        guard disablesAnimations else {
            reload()
            return
        }

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            reload()
        }
    }

    private func isMissingTask(_ error: Error) -> Bool {
        guard let error = error as? TaskStoreError else {
            return false
        }

        if case .notFound = error {
            return true
        }
        return false
    }

    private func isMissingCollection(_ error: Error) -> Bool {
        guard let error = error as? TaskStoreError else {
            return false
        }

        if case .collectionNotFound = error {
            return true
        }
        return false
    }

    private func isMissingCollectionGroup(_ error: Error) -> Bool {
        guard let error = error as? TaskStoreError else {
            return false
        }

        if case .collectionGroupNotFound = error {
            return true
        }
        return false
    }

    private func isInvalidCollection(_ error: Error) -> Bool {
        error as? TaskStoreError == .invalidCollection
    }

    private func isInvalidCollectionGroup(_ error: Error) -> Bool {
        error as? TaskStoreError == .invalidCollectionGroup
    }

    private func isStaleCollection(_ error: Error) -> Bool {
        isInvalidCollection(error)
            || isMissingCollection(error)
            || error as? TaskStoreError == .defaultCollection
    }

    private func isStaleCollectionGroup(_ error: Error) -> Bool {
        isInvalidCollectionGroup(error)
            || isMissingCollectionGroup(error)
            || error as? TaskStoreError == .defaultCollectionGroup
    }

    private func isNoMatchingTasks(_ error: Error) -> Bool {
        error as? TaskStoreError == .noMatchingTasks
    }

    private func uniqueCollectionName(base: String) -> String {
        uniqueCollectionName(base: base, group: TaskStore.defaultCollectionGroup)
    }

    private func prepareCollectionForReorder(_ collection: TaskCollectionSummary, toGroup group: String) throws -> String {
        let targetDisplayName = uniqueCollectionName(
            base: collection.displayName,
            group: group,
            excluding: collection.name
        )
        let targetName = collectionAPIName(group: group, displayName: targetDisplayName)
        guard targetName != collection.name else {
            return collection.name
        }

        return try store.renameCollection(from: collection.name, to: targetName)
    }

    private func uniqueCollectionName(
        base: String,
        group: String,
        excluding excludedName: String? = nil
    ) -> String {
        let existing = Set(collectionGroupSummaries
            .first { $0.name == group }?
            .collections
            .filter { $0.name != excludedName }
            .map(\.displayName) ?? [])
        guard existing.contains(base) else {
            return base
        }

        var index = 2
        while existing.contains("\(base) \(index)") {
            index += 1
        }

        return "\(base) \(index)"
    }

    private func uniqueCollectionGroupName(base: String, excluding excludedName: String? = nil) -> String {
        let existing = Set(collectionGroupSummaries
            .map(\.name)
            .filter { $0 != excludedName })
        guard existing.contains(base) else {
            return base
        }

        var index = 2
        while existing.contains("\(base) \(index)") {
            index += 1
        }

        return "\(base) \(index)"
    }

    private func uniqueCollectionName(oldName: String, requestedName: String) -> String? {
        guard let currentCollection = collectionSummaries.first(where: { $0.name == oldName }),
              let reference = collectionReference(
                from: requestedName,
                defaultGroup: currentCollection.groupName
              ) else {
            return nil
        }

        let displayName = uniqueCollectionName(
            base: reference.displayName,
            group: reference.groupName,
            excluding: oldName
        )
        return collectionAPIName(group: reference.groupName, displayName: displayName)
    }

    private func replacementSelectedCollectionName(
        whenRenamingGroup oldName: String,
        to newName: String
    ) -> String? {
        guard let selectedSummary = collectionSummaries.first(where: { $0.name == selectedCollection }),
              selectedSummary.groupName == oldName else {
            return nil
        }

        return collectionAPIName(group: newName, displayName: selectedSummary.displayName)
    }

    private func collectionReference(
        from name: String,
        defaultGroup: String
    ) -> (groupName: String, displayName: String)? {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = cleanName.split(separator: "/", omittingEmptySubsequences: false).map(String.init)

        switch parts.count {
        case 1:
            let displayName = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            return displayName.isEmpty ? nil : (defaultGroup, displayName)
        case 2:
            let groupName = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !groupName.isEmpty, !displayName.isEmpty else {
                return nil
            }
            return (groupName, displayName)
        default:
            return nil
        }
    }

    private func collectionAPIName(group: String, displayName: String) -> String {
        if group == TaskStore.defaultCollectionGroup {
            return displayName == "Inbox" ? TaskStore.defaultCollection : displayName
        }

        return "\(group)/\(displayName)"
    }

    private func uniqueName(base: String, usedNames: inout Set<String>) -> String {
        guard usedNames.contains(base) else {
            usedNames.insert(base)
            return base
        }

        var index = 2
        while usedNames.contains("\(base) \(index)") {
            index += 1
        }

        let name = "\(base) \(index)"
        usedNames.insert(name)
        return name
    }

    private func updateRecentlyCompletedVisibility(
        previousStatuses: [String: TaskStatus],
        loadedItems: [TaskItem]
    ) {
        let loadedIDs = Set(loadedItems.map(\.id))

        for id in Array(completedHideTasks.keys) where !loadedIDs.contains(id) {
            cancelCompletedHide(for: id)
        }

        for id in Array(recentlyCompletedVisibleIDs) where !loadedIDs.contains(id) {
            recentlyCompletedVisibleIDs.remove(id)
        }

        defer {
            hasLoadedItems = true
        }

        guard hasLoadedItems else {
            return
        }

        for item in loadedItems {
            if item.status == .completed, previousStatuses[item.id] != .completed {
                showCompletedItemBeforeHiding(item.id)
            } else if item.status != .completed {
                cancelCompletedHide(for: item.id)
            }
        }
    }

    private func showCompletedItemBeforeHiding(_ id: String) {
        recentlyCompletedVisibleIDs.insert(id)
        completedHideTasks[id]?.cancel()

        completedHideTasks[id] = Task { @MainActor [weak self] in
            guard !Task.isCancelled else {
                return
            }

            // Keep the item only for the removal animation; there is intentionally no extra grace delay.
            _ = withAnimation(.easeInOut(duration: 0.22)) {
                self?.recentlyCompletedVisibleIDs.remove(id)
            }
            self?.completedHideTasks[id] = nil
        }
    }

    private func cancelCompletedHide(for id: String) {
        completedHideTasks[id]?.cancel()
        completedHideTasks[id] = nil
        recentlyCompletedVisibleIDs.remove(id)
    }

    private func startStoreChangeMonitor() {
        storeChangeMonitor = StoreChangeMonitor(fileURL: store.fileURL) { [weak self] in
            Task { @MainActor [weak self] in
                self?.reload()
            }
        }
        storeChangeMonitor?.start()
    }

    private func requestBulkStatusChange(title: String, items: [TaskItem]) {
        guard !items.isEmpty else {
            return
        }

        bulkStatusChangeRequest = TaskBulkStatusChangeRequest(
            title: title,
            ids: items.map(\.id),
            collection: nil,
            itemCount: items.count
        )
    }

    private func collectionGroups(showingArchived: Bool) -> [TaskCollectionGroupSummary] {
        collectionGroupSummaries
            .map { group in
                let visibleCollections = group.collections.filter { !$0.isArchived }
                let archivedCollections = showingArchived
                    ? group.collections
                        .filter(\.isArchived)
                        .sorted(by: archivedCollectionComesBefore)
                    : []

                return TaskCollectionGroupSummary(
                    name: group.name,
                    collections: visibleCollections + archivedCollections
                )
            }
            .filter { group in
                group.name != TaskStore.defaultCollectionGroup || !group.collections.isEmpty
            }
    }

    private func archivedCollectionComesBefore(
        _ lhs: TaskCollectionSummary,
        _ rhs: TaskCollectionSummary
    ) -> Bool {
        switch lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) {
        case .orderedSame:
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        case .orderedAscending:
            true
        case .orderedDescending:
            false
        }
    }
}

