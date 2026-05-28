import Darwin
import Dispatch
import SwiftUI
import TodoCore

struct TodoBulkStatusChangeRequest: Identifiable {
    let id = UUID()
    let title: String
    let ids: [String]?
    let collection: String?
    let itemCount: Int
}

struct TodoAssigneeEditRequest: Identifiable {
    let item: TodoItem

    var id: String {
        item.id
    }
}

@MainActor
final class TodoAppModel: ObservableObject {
    static let allCollectionID = "__all__"
    private static let usesAutoDraftKey = "usesAutoDraft"

    @Published var items: [TodoItem] = []
    @Published var collectionSummaries: [TodoCollectionSummary] = []
    @Published var selectedCollection: String
    @Published var searchText = ""
    @Published var showsIncompleteOnly = false
    @Published var showsArchivedCollections = false {
        didSet {
            if !showsArchivedCollections, selectedCollectionSummary?.isArchived == true {
                selectedCollection = Self.allCollectionID
            }
        }
    }
    @Published var usesAutoDraft: Bool {
        didSet {
            UserDefaults.standard.set(usesAutoDraft, forKey: Self.usesAutoDraftKey)
        }
    }
    @Published var errorMessage: String?
    @Published var cliStatus: CLIInstallStatus?
    @Published var collectionDeletionRequest: TodoCollectionSummary?
    @Published var bulkStatusChangeRequest: TodoBulkStatusChangeRequest?
    @Published var assigneeEditRequest: TodoAssigneeEditRequest?
    @Published private var recentlyCompletedVisibleIDs: Set<String> = []

    private let store: TodoStore
    private let installer: CommandLineInstaller
    private var storeChangeMonitor: StoreChangeMonitor?
    private var completedHideTasks: [String: Task<Void, Never>] = [:]
    private var hasLoadedItems = false

    init(
        store: TodoStore = TodoStore(),
        installer: CommandLineInstaller = CommandLineInstaller(),
        initialSelectedCollection: String = TodoAppModel.allCollectionID
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
        visibleCollectionSummaries.map(\.name)
    }

    var visibleCollectionSummaries: [TodoCollectionSummary] {
        collectionSummaries.filter { !$0.isArchived }
    }

    var archivedCollectionSummaries: [TodoCollectionSummary] {
        collectionSummaries.filter(\.isArchived)
    }

    var selectedCollectionSummary: TodoCollectionSummary? {
        guard let selectedCollectionName else {
            return nil
        }

        return collectionSummaries.first { $0.name == selectedCollectionName }
    }

    func collectionColor(named name: String) -> TodoCollectionColor {
        collectionSummaries.first { $0.name == name }?.color ?? .gray
    }

    var canDeleteSelectedCollection: Bool {
        selectedCollectionSummary != nil
    }

    var visibleItems: [TodoItem] {
        items.filter { itemIsVisible($0, keepsRecentlyCompletedVisible: true) }
    }

    func itemIsVisible(_ item: TodoItem, keepsRecentlyCompletedVisible: Bool = false) -> Bool {
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
    func createTodo(
        title: String,
        collection: String? = nil,
        id: String? = nil,
        allowEmptyTitle: Bool = false,
        status: TodoStatus = .draft
    ) -> TodoItem? {
        updateStore(reloadOnError: false) {
            try store.add(
                title: title,
                collection: collection ?? selectedCollectionName ?? TodoStore.defaultCollection,
                id: id,
                allowEmptyTitle: allowEmptyTitle,
                status: status
            )
        }
    }

    func createTodoInBackground(
        title: String,
        collection: String? = nil,
        id: String? = nil,
        allowEmptyTitle: Bool = false,
        status: TodoStatus = .draft,
        completion: @escaping (TodoItem?) -> Void
    ) {
        let store = store
        let collection = collection ?? selectedCollectionName ?? TodoStore.defaultCollection

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
                reload()
                completion(item)
            } catch {
                errorMessage = error.localizedDescription
                reload()
                completion(nil)
            }
        }
    }

    @discardableResult
    func createEmptyTodo(id: String? = nil, collection: String? = nil) -> TodoItem? {
        createTodo(title: "", collection: collection, id: id, allowEmptyTitle: true)
    }

    @discardableResult
    func createCollectionForEditing() -> String? {
        let name = uniqueCollectionName(base: "New Collection")

        return updateStore(reloadOnError: false) {
            let createdName = try store.createCollection(name: name)
            selectedCollection = createdName
            return createdName
        }
    }

    @discardableResult
    func renameCollection(from oldName: String, to newName: String) -> String? {
        guard !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            reload()
            return nil
        }

        return updateStore(ignoring: isMissingCollection) {
            let finalName = try store.renameCollection(from: oldName, to: newName)
            selectedCollection = finalName
            return finalName
        }
    }

    @discardableResult
    func deleteEmptyCollection(_ name: String) -> Bool {
        updateStore(ignoring: isInvalidCollection) {
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

    func requestDeleteCollection(_ collection: TodoCollectionSummary) {
        collectionDeletionRequest = collection
    }

    func setCollectionColor(_ collection: TodoCollectionSummary, color: TodoCollectionColor) {
        updateStore(ignoring: isStaleCollection) {
            try store.setCollectionColor(name: collection.name, color: color)
        }
    }

    func setCollectionArchived(_ collection: TodoCollectionSummary, isArchived: Bool) {
        updateStore(ignoring: isStaleCollection) {
            try store.setCollectionArchived(name: collection.name, isArchived: isArchived)
            if isArchived && selectedCollection == collection.name && !showsArchivedCollections {
                selectedCollection = Self.allCollectionID
            }
        }
    }

    func canClearItems(in collection: TodoCollectionSummary) -> Bool {
        items.contains { $0.collection == collection.name }
    }

    func canClearCompletedItems(in collection: TodoCollectionSummary) -> Bool {
        items.contains { $0.collection == collection.name && $0.status == .completed }
    }

    @discardableResult
    func clearItems(in collection: TodoCollectionSummary, completedOnly: Bool = false) -> Bool {
        updateStore(ignoring: isNoMatchingTodos) {
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
        updateStore(ignoring: isStaleCollection) {
            let deleted = try store.deleteCollection(name: name)
            if deleted {
                selectedCollection = Self.allCollectionID
            }
            return deleted
        } ?? false
    }

    func makeTodoID() -> String {
        TodoStore.makeID(existing: Set(items.map(\.id)))
    }

    func advanceStatusFromLeadingClick(_ item: TodoItem) {
        setStatus(item, status: item.status.leadingStatusClickTarget)
    }

    func setStatus(_ item: TodoItem, status: TodoStatus) {
        updateStore(reloadOnError: false, ignoring: isMissingTodo) {
            try store.setStatus(status, id: item.id, ifCurrent: item)
        }
    }

    func setPriority(_ item: TodoItem, priority: TodoPriority) {
        _ = withAnimation(.easeInOut(duration: 0.22)) {
            updateStore(reloadOnError: false, ignoring: isMissingTodo) {
                try store.setPriority(priority, id: item.id, ifCurrent: item)
            }
        }
    }

    func requestAssigneeEdit(_ item: TodoItem) {
        assigneeEditRequest = TodoAssigneeEditRequest(item: item)
    }

    func cancelAssigneeEdit() {
        assigneeEditRequest = nil
    }

    @discardableResult
    func setAssignees(_ item: TodoItem, assignees: [String]) -> Bool {
        withAnimation(.easeInOut(duration: 0.22)) {
            updateStore(reloadOnError: false, ignoring: isMissingTodo) {
                let updated = try store.assign(id: item.id, assignees: assignees, ifCurrent: item)
                return updated != nil
            } ?? false
        }
    }

    func confirmAssigneeEdit(_ item: TodoItem, assignees: [String]) {
        assigneeEditRequest = nil
        setAssignees(item, assignees: assignees)
    }

    var canBulkChangeVisibleStatuses: Bool {
        !visibleItems.isEmpty
    }

    func canBulkChangeStatuses(in collection: TodoCollectionSummary) -> Bool {
        items.contains { $0.collection == collection.name }
    }

    func requestBulkStatusChangeForAll() {
        requestBulkStatusChange(title: "All", items: items)
    }

    func requestBulkStatusChangeForVisibleItems() {
        requestBulkStatusChange(title: title, items: visibleItems)
    }

    func requestBulkStatusChange(for collection: TodoCollectionSummary) {
        let itemCount = items.filter { $0.collection == collection.name }.count
        guard itemCount > 0 else {
            return
        }

        bulkStatusChangeRequest = TodoBulkStatusChangeRequest(
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
    func confirmBulkStatusChange(_ replacements: [TodoStatus: TodoStatus]) -> Bool {
        guard let request = bulkStatusChangeRequest else {
            return false
        }

        bulkStatusChangeRequest = nil
        guard !replacements.isEmpty else {
            return true
        }

        return updateStore(ignoring: isNoMatchingTodos) {
            if let collection = request.collection {
                try store.setStatuses(replacements, collection: collection)
            } else {
                try store.setStatuses(replacements, ids: request.ids ?? [])
            }
            return true
        } ?? false
    }

    func rename(
        _ item: TodoItem,
        title: String,
        statusAfterEdit: TodoStatus? = nil
    ) {
        updateStore(reloadOnError: false, ignoring: isMissingTodo) {
            try store.updateTitle(id: item.id, title: title, ifCurrent: item, statusAfterEdit: statusAfterEdit)
        }
    }

    @discardableResult
    func renameOrDeleteIfEmpty(
        _ item: TodoItem,
        title: String,
        statusAfterEdit: TodoStatus? = nil
    ) -> Bool {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return delete(item)
        }

        rename(item, title: title, statusAfterEdit: statusAfterEdit)
        return false
    }

    var autoDraftEditStatus: TodoStatus? {
        usesAutoDraft ? .draft : nil
    }

    var autoDraftConfirmationStatus: TodoStatus? {
        usesAutoDraft ? .ready : nil
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
        updateStore(ignoring: isMissingTodo) {
            try store.reorder(id: id, after: previousID, before: nextID)
        }
    }

    @discardableResult
    func delete(_ item: TodoItem) -> Bool {
        updateStore(reloadOnError: false, ignoring: isMissingTodo) {
            try store.delete(id: item.id, ifCurrent: item)
        } ?? false
    }

    @discardableResult
    func delete(id: String) -> Bool {
        updateStore(reloadOnError: false, ignoring: isMissingTodo) {
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
        ignoring shouldIgnoreError: (Error) -> Bool = { _ in false },
        _ update: () throws -> T
    ) -> T? {
        do {
            let result = try update()
            reload()
            return result
        } catch {
            let isIgnored = shouldIgnoreError(error)
            if !isIgnored {
                errorMessage = error.localizedDescription
            }
            if reloadOnError || isIgnored {
                reload()
            }
            return nil
        }
    }

    private func isMissingTodo(_ error: Error) -> Bool {
        guard let error = error as? TodoStoreError else {
            return false
        }

        if case .notFound = error {
            return true
        }
        return false
    }

    private func isMissingCollection(_ error: Error) -> Bool {
        guard let error = error as? TodoStoreError else {
            return false
        }

        if case .collectionNotFound = error {
            return true
        }
        return false
    }

    private func isInvalidCollection(_ error: Error) -> Bool {
        error as? TodoStoreError == .invalidCollection
    }

    private func isStaleCollection(_ error: Error) -> Bool {
        isInvalidCollection(error) || isMissingCollection(error)
    }

    private func isNoMatchingTodos(_ error: Error) -> Bool {
        error as? TodoStoreError == .noMatchingTodos
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

    private func updateRecentlyCompletedVisibility(
        previousStatuses: [String: TodoStatus],
        loadedItems: [TodoItem]
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

    private func requestBulkStatusChange(title: String, items: [TodoItem]) {
        guard !items.isEmpty else {
            return
        }

        bulkStatusChangeRequest = TodoBulkStatusChangeRequest(
            title: title,
            ids: items.map(\.id),
            collection: nil,
            itemCount: items.count
        )
    }
}

struct CollectionColorMenu: View {
    @EnvironmentObject private var model: TodoAppModel

    let collection: TodoCollectionSummary

    var body: some View {
        Menu {
            Picker("", selection: colorSelection) {
                ForEach(TodoCollectionColor.allCases) { color in
                    Label {
                        Text(color.displayName)
                    } icon: {
                        CollectionColorSwatch(color: color, size: 12)
                    }
                    .tag(color)
                }
            }
            .labelsHidden()
            .pickerStyle(.inline)
        } label: {
            Label {
                Text("Color")
            } icon: {
                CollectionColorSwatch(color: collection.color, size: 10)
            }
        }
    }

    private var colorSelection: Binding<TodoCollectionColor> {
        Binding {
            collection.color
        } set: { color in
            model.setCollectionColor(collection, color: color)
        }
    }
}

enum CollectionBulkStatusScope {
    case collection
    case visibleItems
}

struct CollectionActionMenuItems: View {
    @EnvironmentObject private var model: TodoAppModel

    let collection: TodoCollectionSummary
    var showsCLICommand = false
    var bulkStatusScope: CollectionBulkStatusScope = .collection

    var body: some View {
        Button("Copy Example Prompt") {
            copyToPasteboard(todoExamplePrompt(cliCommand: cliCommand))
        }

        if showsCLICommand {
            Button("Copy CLI Command") {
                copyToPasteboard(cliCommand)
            }
        }

        Divider()

        CollectionColorMenu(collection: collection)

        Divider()

        Button(collection.isArchived ? "Unarchive Collection" : "Archive Collection") {
            model.setCollectionArchived(collection, isArchived: !collection.isArchived)
        }

        Divider()

        Button("Clear All", role: .destructive) {
            model.clearItems(in: collection)
        }
        .disabled(!model.canClearItems(in: collection))

        Button("Clear Completed", role: .destructive) {
            model.clearItems(in: collection, completedOnly: true)
        }
        .disabled(!model.canClearCompletedItems(in: collection))

        Button("Bulk Change Status...") {
            requestBulkStatusChange()
        }
        .disabled(!canBulkChangeStatuses)

        Divider()

        Button("Delete Collection", role: .destructive) {
            model.requestDeleteCollection(collection)
        }
    }

    private var cliCommand: String {
        "taskpond item get --collection \(collection.name.shellEscaped)"
    }

    private var canBulkChangeStatuses: Bool {
        switch bulkStatusScope {
        case .collection:
            model.canBulkChangeStatuses(in: collection)
        case .visibleItems:
            model.canBulkChangeVisibleStatuses
        }
    }

    private func requestBulkStatusChange() {
        switch bulkStatusScope {
        case .collection:
            model.requestBulkStatusChange(for: collection)
        case .visibleItems:
            model.requestBulkStatusChangeForVisibleItems()
        }
    }
}

private final class StoreChangeMonitor: @unchecked Sendable {
    private let directoryURL: URL
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "Pond.store-change-monitor")
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
