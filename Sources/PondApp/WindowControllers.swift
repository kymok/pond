import AppKit

import SwiftUI

private let pondMainSplitViewAutosaveName = "PondMainSplitView"

@MainActor
enum PondMainWindowState {
    static let fallbackContentSize = CGSize(width: 640, height: 360)
    static let frameAutosaveName = "PondMainWindowFrame"
    static let frameDefaultsKey = "NSWindow Frame \(frameAutosaveName)"

    static var initialContentSize: CGSize {
        guard let frame = savedFrame else {
            return fallbackContentSize
        }

        return NSWindow.contentRect(forFrameRect: frame, styleMask: frameStyleMask).size
    }

    private static let frameStyleMask: NSWindow.StyleMask = [
        .titled,
        .closable,
        .miniaturizable,
        .resizable
    ]

    private static var savedFrame: CGRect? {
        guard let descriptor = UserDefaults.standard.string(forKey: frameDefaultsKey) else {
            return nil
        }

        let values = descriptor.split(separator: " ").compactMap { Double(String($0)) }
        guard values.count >= 4 else {
            return nil
        }

        let frame = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        guard frame.width > 0, frame.height > 0 else {
            return nil
        }

        return frame
    }
}

struct WindowLevelController: NSViewRepresentable {
    let alwaysOnTop: Bool

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.level = alwaysOnTop ? .floating : .normal
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        nsView.window?.level = .normal
    }
}

struct WindowStateController: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = WindowStateView(frame: .zero)
        view.coordinator = context.coordinator
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
        context.coordinator.configureWindowIfNeeded()
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?

        private weak var configuredWindow: NSWindow?
        private weak var configuredSplitView: NSSplitView?
        private var frameObserverTokens: [NSObjectProtocol] = []
        private var splitViewRetry: DispatchWorkItem?
        private var splitViewRetryCount = 0

        func configureWindowIfNeeded() {
            guard let window = view?.window else {
                retryConfigureSplitView()
                return
            }

            if configuredWindow !== window {
                removeFrameObservers()
                configuredWindow = window
                configuredSplitView = nil
                splitViewRetryCount = 0
                window.setFrameAutosaveName(PondMainWindowState.frameAutosaveName)
                restoreFrame(for: window)
                configureFrameObservers(for: window)
            }

            configureSplitViewIfNeeded(in: window.contentView)
        }

        private func restoreFrame(for window: NSWindow) {
            if let frameDescriptor = UserDefaults.standard.string(forKey: PondMainWindowState.frameDefaultsKey) {
                window.setFrame(from: frameDescriptor)
            } else {
                window.setFrameUsingName(PondMainWindowState.frameAutosaveName)
            }
        }

        private func configureFrameObservers(for window: NSWindow) {
            let center = NotificationCenter.default
            let windowNotifications: [Notification.Name] = [
                NSWindow.didMoveNotification,
                NSWindow.didResizeNotification,
                NSWindow.willCloseNotification
            ]

            frameObserverTokens = windowNotifications.map { notificationName in
                center.addObserver(forName: notificationName, object: window, queue: .main) { [weak self, weak window] _ in
                    MainActor.assumeIsolated {
                        guard let self, let window else {
                            return
                        }

                        self.saveFrame(for: window)

                        if notificationName == NSWindow.willCloseNotification {
                            self.removeFrameObservers()
                        }
                    }
                }
            }

            frameObserverTokens.append(
                center.addObserver(forName: NSApplication.willTerminateNotification, object: NSApp, queue: .main) { [weak self, weak window] _ in
                    MainActor.assumeIsolated {
                        guard let self, let window else {
                            return
                        }

                        self.saveFrame(for: window)
                    }
                }
            )
        }

        private func saveFrame(for window: NSWindow) {
            // SwiftUI windows did not consistently flush AppKit's autosave key on close.
            UserDefaults.standard.set(window.frameDescriptor, forKey: PondMainWindowState.frameDefaultsKey)
            UserDefaults.standard.synchronize()
        }

        private func removeFrameObservers() {
            let center = NotificationCenter.default
            frameObserverTokens.forEach(center.removeObserver)
            frameObserverTokens = []
        }

        private func configureSplitViewIfNeeded(in rootView: NSView?) {
            guard let splitView = rootView?.firstSubview(ofType: NSSplitView.self) else {
                retryConfigureSplitView()
                return
            }

            guard configuredSplitView !== splitView else {
                return
            }

            configuredSplitView = splitView
            splitViewRetry?.cancel()
            splitViewRetry = nil
            splitView.autosaveName = NSSplitView.AutosaveName(pondMainSplitViewAutosaveName)
        }

        private func retryConfigureSplitView() {
            guard splitViewRetryCount < 20 else {
                return
            }

            splitViewRetryCount += 1
            splitViewRetry?.cancel()

            let workItem = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.configureWindowIfNeeded()
                }
            }
            splitViewRetry = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
        }
    }

    @MainActor
    private final class WindowStateView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.configureWindowIfNeeded()
        }
    }
}

private extension NSView {
    func firstSubview<T: NSView>(ofType type: T.Type) -> T? {
        if let view = self as? T {
            return view
        }

        for subview in subviews {
            if let match = subview.firstSubview(ofType: type) {
                return match
            }
        }

        return nil
    }
}
