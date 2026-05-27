import Darwin
import Dispatch
import SwiftUI
import TodoCore

@MainActor
final class TodoAppModel: ObservableObject {
    static let allCollectionID = "__all__"

    @Published var items: [TodoItem] = []
    @Published var collectionSummaries: [TodoCollectionSummary] = []
    @Published var selectedCollection = TodoAppModel.allCollectionID
    @Published var searchText = ""
    @Published var showsUndoneOnly = false
    @Published var errorMessage: String?
    @Published var cliStatus: CLIInstallStatus?
    @Published var collectionDeletionRequest: TodoCollectionSummary?

    private let store: TodoStore
    private let installer: CommandLineInstaller
    private var storeChangeMonitor: StoreChangeMonitor?

    init(store: TodoStore = TodoStore(), installer: CommandLineInstaller = CommandLineInstaller()) {
        self.store = store
        self.installer = installer
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
        collectionSummaries.map(\.name)
    }

    var selectedCollectionSummary: TodoCollectionSummary? {
        guard let selectedCollectionName else {
            return nil
        }

        return collectionSummaries.first { $0.name == selectedCollectionName }
    }

    var canDeleteSelectedCollection: Bool {
        selectedCollectionSummary != nil
    }

    var visibleItems: [TodoItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        return items.filter { item in
            let collectionMatches = selectedCollectionName.map { $0 == item.collection } ?? true
            let statusMatches = !showsUndoneOnly || !item.isDone
            let searchMatches = query.isEmpty
                || item.title.localizedCaseInsensitiveContains(query)
                || item.collection.localizedCaseInsensitiveContains(query)
                || item.id.localizedCaseInsensitiveContains(query)

            return collectionMatches && statusMatches && searchMatches
        }
    }

    var totalUndoneCount: Int {
        collectionSummaries.reduce(0) { $0 + $1.undoneCount }
    }

    var selectedUndoneCount: Int {
        selectedCollectionSummary?.undoneCount ?? totalUndoneCount
    }

    var titlebarDescription: String {
        guard selectedUndoneCount > 0 else {
            return ""
        }

        let itemLabel = selectedUndoneCount == 1 ? "todo" : "todos"
        return "\(selectedUndoneCount) undone \(itemLabel)"
    }

    func reload() {
        do {
            items = try store.items()
            collectionSummaries = try store.collectionSummaries()

            if selectedCollectionName != nil && !collectionSummaries.contains(where: { $0.name == selectedCollection }) {
                selectedCollection = Self.allCollectionID
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func createTodo(
        title: String,
        collection: String? = nil,
        id: String? = nil,
        allowEmptyTitle: Bool = false
    ) -> TodoItem? {
        do {
            let item = try store.add(
                title: title,
                collection: collection ?? selectedCollectionName ?? TodoStore.defaultCollection,
                id: id,
                allowEmptyTitle: allowEmptyTitle
            )
            reload()
            return item
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func createEmptyTodo(id: String? = nil, collection: String? = nil) -> TodoItem? {
        createTodo(title: "", collection: collection, id: id, allowEmptyTitle: true)
    }

    @discardableResult
    func createCollectionForEditing() -> String? {
        let name = uniqueCollectionName(base: "New Collection")

        do {
            let createdName = try store.createCollection(name: name)
            selectedCollection = createdName
            reload()
            return createdName
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func renameCollection(from oldName: String, to newName: String) -> String? {
        guard !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            reload()
            return nil
        }

        do {
            let finalName = try store.renameCollection(from: oldName, to: newName)
            selectedCollection = finalName
            reload()
            return finalName
        } catch TodoStoreError.collectionNotFound {
            reload()
            return nil
        } catch {
            errorMessage = error.localizedDescription
            reload()
            return nil
        }
    }

    @discardableResult
    func deleteEmptyCollection(_ name: String) -> Bool {
        do {
            let deleted = try store.deleteEmptyCollection(name: name)
            if deleted && selectedCollection == name {
                selectedCollection = Self.allCollectionID
            }
            reload()
            return deleted
        } catch TodoStoreError.invalidCollection {
            reload()
            return false
        } catch {
            errorMessage = error.localizedDescription
            reload()
            return false
        }
    }

    func requestDeleteSelectedCollection() {
        guard let selectedCollectionSummary else {
            return
        }

        requestDeleteCollection(selectedCollectionSummary)
    }

    func requestDeleteCollection(_ collection: TodoCollectionSummary) {
        collectionDeletionRequest = collection
    }

    func canClearUnlockedItems(in collection: TodoCollectionSummary) -> Bool {
        items.contains { $0.collection == collection.name && !$0.isLocked }
    }

    func canClearDoneUnlockedItems(in collection: TodoCollectionSummary) -> Bool {
        items.contains { $0.collection == collection.name && $0.isDone && !$0.isLocked }
    }

    @discardableResult
    func clearUnlockedItems(in collection: TodoCollectionSummary, doneOnly: Bool = false) -> Bool {
        do {
            _ = try store.clearUnlockedItems(collection: collection.name, doneOnly: doneOnly)
            reload()
            return true
        } catch TodoStoreError.noMatchingTodos {
            reload()
            return false
        } catch {
            errorMessage = error.localizedDescription
            reload()
            return false
        }
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
        do {
            let deleted = try store.deleteCollection(name: name)
            if deleted {
                selectedCollection = Self.allCollectionID
            }
            reload()
            return deleted
        } catch TodoStoreError.invalidCollection, TodoStoreError.collectionNotFound {
            reload()
            return false
        } catch {
            errorMessage = error.localizedDescription
            reload()
            return false
        }
    }

    func makeTodoID() -> String {
        TodoStore.makeID(existing: Set(items.map(\.id)))
    }

    func setDone(_ item: TodoItem, isDone: Bool) {
        do {
            try store.setCompletion(isDone: isDone, id: item.id, ifCurrent: item)
            reload()
        } catch TodoStoreError.notFound {
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setLocked(_ item: TodoItem, isLocked: Bool) {
        do {
            try store.setLock(isLocked: isLocked, id: item.id, ifCurrent: item)
            reload()
        } catch TodoStoreError.notFound {
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rename(_ item: TodoItem, title: String) {
        do {
            try store.updateTitle(id: item.id, title: title, ifCurrent: item)
            reload()
        } catch TodoStoreError.notFound {
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func renameOrDeleteIfEmpty(_ item: TodoItem, title: String) -> Bool {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return delete(item)
        }

        rename(item, title: title)
        return false
    }

    func move(_ item: TodoItem, collection: String) {
        do {
            try store.move(id: item.id, collection: collection, ifCurrent: item)
            reload()
        } catch TodoStoreError.notFound {
            if item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = createEmptyTodo(id: item.id, collection: collection)
                return
            }

            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reorderItem(id: String, after previousID: String?, before nextID: String?) {
        do {
            try store.reorder(id: id, after: previousID, before: nextID)
            reload()
        } catch TodoStoreError.notFound {
            reload()
        } catch {
            errorMessage = error.localizedDescription
            reload()
        }
    }

    @discardableResult
    func delete(_ item: TodoItem) -> Bool {
        do {
            let deleted = try store.delete(id: item.id, ifCurrent: item)
            reload()
            return deleted
        } catch TodoStoreError.notFound {
            reload()
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
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

    private func uniqueCollectionName(base: String) -> String {
        let existing = Set(collectionNames)
        guard existing.contains(base) else {
            return base
        }

        var index = 2
        while existing.contains("\(base) \(index)") {
            index += 1
        }

        return "\(base) \(index)"
    }

    private func startStoreChangeMonitor() {
        storeChangeMonitor = StoreChangeMonitor(fileURL: store.fileURL) { [weak self] in
            Task { @MainActor [weak self] in
                self?.reload()
            }
        }
        storeChangeMonitor?.start()
    }
}

private final class StoreChangeMonitor: @unchecked Sendable {
    private let directoryURL: URL
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "SmolTodo.store-change-monitor")
    private var source: DispatchSourceFileSystemObject?
    private var pendingChange: DispatchWorkItem?

    init(fileURL: URL, onChange: @escaping @Sendable () -> Void) {
        self.directoryURL = fileURL.deletingLastPathComponent()
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    func start() {
        guard source == nil else {
            return
        }

        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let descriptor = Darwin.open(directoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.scheduleChange()
        }
        source.setCancelHandler {
            Darwin.close(descriptor)
        }

        self.source = source
        source.resume()
    }

    func stop() {
        pendingChange?.cancel()
        pendingChange = nil
        source?.cancel()
        source = nil
    }

    private func scheduleChange() {
        pendingChange?.cancel()

        let change = DispatchWorkItem { [onChange] in
            onChange()
        }
        pendingChange = change

        // Atomic writes can emit several directory events; reload once after the burst settles.
        queue.asyncAfter(deadline: .now() + .milliseconds(100), execute: change)
    }
}
