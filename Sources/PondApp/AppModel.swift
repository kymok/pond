import AppKit
import Darwin
import Dispatch
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
final class TaskAppModel: ObservableObject {
    static let allCollectionID = "__all__"
    private static let usesAutoDraftKey = "usesAutoDraft"

    @Published var items: [TaskItem] = []
    @Published var collectionSummaries: [TaskCollectionSummary] = []
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
    @Published var collectionDeletionRequest: TaskCollectionSummary?
    @Published var bulkStatusChangeRequest: TaskBulkStatusChangeRequest?
    @Published var collectionPromptEditRequest: TaskCollectionPromptEditRequest?
    @Published private var recentlyCompletedVisibleIDs: Set<String> = []

    private let store: TaskStore
    private let installer: CommandLineInstaller
    private var storeChangeMonitor: StoreChangeMonitor?
    private var completedHideTasks: [String: Task<Void, Never>] = [:]
    private var hasLoadedItems = false

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
        visibleCollectionSummaries.map(\.name)
    }

    var visibleCollectionSummaries: [TaskCollectionSummary] {
        collectionSummaries.filter { !$0.isArchived }
    }

    var archivedCollectionSummaries: [TaskCollectionSummary] {
        collectionSummaries.filter(\.isArchived)
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

    var canDeleteSelectedCollection: Bool {
        selectedCollectionSummary != nil
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
    func createEmptyTask(id: String? = nil, collection: String? = nil) -> TaskItem? {
        createTask(title: "", collection: collection, id: id, allowEmptyTitle: true)
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

    func requestDeleteCollection(_ collection: TaskCollectionSummary) {
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
        updateStore(ignoring: isStaleCollection) {
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

    func addNote(_ item: TaskItem, body: String) {
        _ = withAnimation(.easeInOut(duration: 0.22)) {
            updateStore(reloadOnError: false, ignoring: isMissingTask) {
                try store.addNote(id: item.id, body: body, ifCurrent: item)
            }
        }
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

    private func isInvalidCollection(_ error: Error) -> Bool {
        error as? TaskStoreError == .invalidCollection
    }

    private func isStaleCollection(_ error: Error) -> Bool {
        isInvalidCollection(error) || isMissingCollection(error)
    }

    private func isNoMatchingTasks(_ error: Error) -> Bool {
        error as? TaskStoreError == .noMatchingTasks
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
}

struct CollectionColorMenu: View {
    @EnvironmentObject private var model: TaskAppModel

    let collection: TaskCollectionSummary

    var body: some View {
        Menu {
            Picker("", selection: colorSelection) {
                ForEach(TaskCollectionColor.allCases) { color in
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

    private var colorSelection: Binding<TaskCollectionColor> {
        Binding {
            collection.color
        } set: { color in
            model.setCollectionColor(collection, color: color)
        }
    }
}

private enum CollectionExportFormat: String, CaseIterable {
    case json = "JSON"
    case jsonl = "JSONL"

    var fileExtension: String {
        switch self {
        case .json:
            "json"
        case .jsonl:
            "jsonl"
        }
    }

    var contentType: UTType {
        switch self {
        case .json:
            .json
        case .jsonl:
            UTType(filenameExtension: "jsonl") ?? .json
        }
    }
}

private struct CollectionExportDestination {
    var url: URL
    var format: CollectionExportFormat

    @MainActor
    static func choose(
        for collectionName: String,
        completion: @escaping (CollectionExportDestination?) -> Void
    ) {
        let panel = NSSavePanel()
        panel.title = "Export Collection"
        panel.nameFieldStringValue = "\(safeFilename(collectionName)).json"
        panel.allowedContentTypes = CollectionExportFormat.allCases.map(\.contentType)
        panel.canCreateDirectories = true
        panel.minSize = NSSize(width: 640, height: 500)
        panel.maxSize = NSSize(width: 760, height: 700)

        let formatPicker = NSPopUpButton(frame: .zero, pullsDown: false)
        for format in CollectionExportFormat.allCases {
            formatPicker.addItem(withTitle: format.rawValue)
            formatPicker.lastItem?.representedObject = format.rawValue
        }

        let label = NSTextField(labelWithString: "Format:")
        let row = NSStackView(views: [label, formatPicker])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let accessoryView = CollectionExportAccessoryView(frame: NSRect(
            x: 0,
            y: 0,
            width: 420,
            height: CollectionExportAccessoryView.height
        ))
        accessoryView.addSubview(row)
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: accessoryView.centerXAnchor),
            row.centerYAnchor.constraint(equalTo: accessoryView.centerYAnchor),
            row.topAnchor.constraint(greaterThanOrEqualTo: accessoryView.topAnchor, constant: 12),
            row.bottomAnchor.constraint(lessThanOrEqualTo: accessoryView.bottomAnchor, constant: -12)
        ])
        panel.accessoryView = accessoryView
        panel.setContentSize(NSSize(width: 680, height: 540))

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK,
                  let selectedFormat = CollectionExportFormat(
                    rawValue: formatPicker.selectedItem?.representedObject as? String ?? ""
                  ),
                  let selectedURL = panel.url else {
                completion(nil)
                return
            }

            completion(CollectionExportDestination(
                url: url(selectedURL, withExtension: selectedFormat.fileExtension),
                format: selectedFormat
            ))
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    private static func safeFilename(_ name: String) -> String {
        let unsafeCharacters = CharacterSet(charactersIn: "/:")
            .union(.newlines)
            .union(.controlCharacters)
        let filename = name.components(separatedBy: unsafeCharacters).joined(separator: "-")
        return filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Collection" : filename
    }

    private static func url(_ url: URL, withExtension fileExtension: String) -> URL {
        guard url.pathExtension.localizedCaseInsensitiveCompare(fileExtension) != .orderedSame else {
            return url
        }

        return url.deletingPathExtension().appendingPathExtension(fileExtension)
    }
}

private final class CollectionExportAccessoryView: NSView {
    static let height: CGFloat = 56

    override var intrinsicContentSize: NSSize {
        NSSize(width: 420, height: Self.height)
    }
}

private struct CollectionExportPayload: Encodable {
    var collection: String
    var exportedAt: Date
    var items: [TaskItem]

    func encoded(as format: CollectionExportFormat) throws -> Data {
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(self)

        case .jsonl:
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let lines = try items.map { item in
                let data = try encoder.encode(item)
                return String(decoding: data, as: UTF8.self)
            }
            return Data((lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).utf8)
        }
    }
}

enum CollectionBulkStatusScope {
    case collection
    case visibleItems
}

struct CollectionActionMenuItems: View {
    @EnvironmentObject private var model: TaskAppModel

    let collection: TaskCollectionSummary
    var showsCLICommand = false
    var showsExport = false
    var bulkStatusScope: CollectionBulkStatusScope = .collection

    var body: some View {
        Button("Copy Prompt") {
            copyToPasteboard(examplePrompt)
        }

        Button("Edit Prompt...") {
            model.requestCollectionPromptEdit(collection)
        }

        if showsCLICommand {
            Button("Copy CLI Command") {
                copyToPasteboard(cliCommand)
            }
        }

        if showsExport {
            Button("Export Collection...") {
                model.exportCollection(collection)
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

    private var examplePrompt: String {
        taskExamplePrompt(
            template: effectivePromptTemplate,
            cliCommand: cliCommand,
            collectionName: collection.name
        )
    }

    private var effectivePromptTemplate: String {
        guard let promptTemplate = collection.promptTemplate,
              !promptTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return TaskPromptSettings.effectiveDefaultPromptTemplate
        }

        return promptTemplate
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
