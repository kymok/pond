import AppKit
import SwiftUI

@MainActor
final class SelectedCollectionPersistence: ObservableObject {
    private static let key = "selectedCollection"

    let initialSelectedCollection: String

    private let defaults: UserDefaults
    private var terminationObserver: NSObjectProtocol?
    private var selectionsByWindow: [ObjectIdentifier: () -> String?] = [:]

    init(defaults: UserDefaults = .standard, notificationCenter: NotificationCenter = .default) {
        self.defaults = defaults
        initialSelectedCollection = defaults.string(forKey: Self.key) ?? TaskAppModel.allCollectionID

        terminationObserver = notificationCenter.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveFrontmostSelection()
            }
        }
    }

    func register(window: NSWindow, model: TaskAppModel) {
        selectionsByWindow[ObjectIdentifier(window)] = { [weak model] in
            model?.selectedCollection
        }
    }

    func unregister(window: NSWindow) {
        selectionsByWindow.removeValue(forKey: ObjectIdentifier(window))
    }

    func saveFrontmostSelection() {
        var seenWindows: Set<ObjectIdentifier> = []
        let candidateWindows = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 } + NSApp.orderedWindows

        for window in candidateWindows where window.isVisible {
            let id = ObjectIdentifier(window)
            guard !seenWindows.contains(id) else {
                continue
            }

            seenWindows.insert(id)
            if let selection = selectionsByWindow[id]?() {
                defaults.set(selection, forKey: Self.key)
                return
            }
        }
    }
}

struct SelectedCollectionWindowRegistration: NSViewRepresentable {
    let model: TaskAppModel
    let persistence: SelectedCollectionPersistence

    func makeCoordinator() -> Coordinator {
        Coordinator(persistence: persistence, model: model)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
        context.coordinator.model = model
        context.coordinator.registerWindowIfNeeded()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.unregisterWindow()
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        weak var model: TaskAppModel?

        private let persistence: SelectedCollectionPersistence
        private weak var registeredWindow: NSWindow?

        init(persistence: SelectedCollectionPersistence, model: TaskAppModel) {
            self.persistence = persistence
            self.model = model
        }

        func registerWindowIfNeeded() {
            guard let window = view?.window, let model else {
                return
            }

            if registeredWindow !== window {
                unregisterWindow()
                registeredWindow = window
            }

            persistence.register(window: window, model: model)
        }

        func unregisterWindow() {
            if let registeredWindow {
                persistence.unregister(window: registeredWindow)
            }

            registeredWindow = nil
        }
    }
}
