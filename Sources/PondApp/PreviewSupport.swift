import SwiftUI
import TaskCore

#if DEBUG
@MainActor
private enum PondPreviewData {
    static let designCollection = "Projects/Design"

    static func model(storeName: String, selectedCollection: String = TaskAppModel.allCollectionID) -> TaskAppModel {
        let storeURL = previewDirectory
            .appendingPathComponent(storeName, isDirectory: true)
            .appendingPathComponent("tasks.json", isDirectory: false)
        let store = TaskStore(fileURL: storeURL)
        let seedError = Result { try resetAndSeed(store, storeURL: storeURL) }.failure
        let model = TaskAppModel(
            store: store,
            installer: previewInstaller(named: storeName),
            initialSelectedCollection: selectedCollection
        )

        if let seedError {
            model.errorMessage = "Preview data could not be loaded: \(seedError.localizedDescription)"
        }

        return model
    }

    private static var previewDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PondPreviews", isDirectory: true)
    }

    private static func previewInstaller(named name: String) -> CommandLineInstaller {
        let directory = previewDirectory.appendingPathComponent(name, isDirectory: true)
        return CommandLineInstaller(
            linkURL: directory.appendingPathComponent("taskpond-link", isDirectory: false),
            targetURL: directory.appendingPathComponent("taskpond-preview", isDirectory: false),
            recordURL: directory.appendingPathComponent("cli-install.json", isDirectory: false)
        )
    }

    private static func resetAndSeed(_ store: TaskStore, storeURL: URL) throws {
        try? FileManager.default.removeItem(at: storeURL)
        try? FileManager.default.removeItem(at: storeURL.appendingPathExtension("lock"))

        let inbox = try store.createCollection(name: "Inbox")
        let waiting = try store.createCollection(name: "Waiting")
        try store.createCollectionGroup(name: "Projects")
        let design = try store.createCollection(name: "Design", group: "Projects")
        let release = try store.createCollection(name: "Release", group: "Projects")

        try store.setCollectionColor(name: inbox, color: .blue)
        try store.setCollectionColor(name: design, color: .purple)
        try store.setCollectionColor(name: release, color: .green)
        try store.setCollectionColor(name: waiting, color: .orange)

        let animation = try store.add(
            title: "Tune row insertion animation",
            collection: design,
            id: "preview1",
            status: .inProgress
        )
        try store.addNote(
            id: animation.id,
            body: "Preview data uses a temporary task store so drag tests do not touch real tasks."
        )

        try store.add(
            title: "Drag this task above or below another row",
            collection: design,
            id: "preview2",
            status: .ready
        )
        try store.add(
            title: "Check drop target spacing",
            collection: design,
            id: "preview3",
            status: .onHold
        )
        try store.add(
            title: "Verify completed row fade",
            collection: design,
            id: "preview4",
            status: .completed
        )
        try store.add(
            title: "Confirm file drop creates a readable title",
            collection: inbox,
            id: "preview5",
            status: .ready
        )
        try store.add(
            title: "Waiting on preview feedback",
            collection: waiting,
            id: "preview6",
            status: .ready
        )
        try store.add(
            title: "Prepare release notes",
            collection: release,
            id: "preview7",
            status: .draft
        )
    }
}

#Preview("Pond") {
    ContentView()
        .environmentObject(PondPreviewData.model(storeName: "content"))
        .frame(width: 920, height: 620)
}

#Preview("Task List D&D") {
    NavigationStack {
        DetailView()
    }
    .environmentObject(PondPreviewData.model(
        storeName: "detail",
        selectedCollection: PondPreviewData.designCollection
    ))
    .environmentObject(TaskDragState())
    .frame(width: 640, height: 520)
}

private extension Result {
    var failure: Failure? {
        guard case .failure(let error) = self else {
            return nil
        }

        return error
    }
}
#endif
