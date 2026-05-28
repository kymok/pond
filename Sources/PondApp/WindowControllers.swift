import AppKit

import SwiftUI

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
    private static let frameAutosaveName = "PondMainWindowFrame"
    private static let splitViewAutosaveName = "PondMainSplitView"

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
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
        private var splitViewRetry: DispatchWorkItem?
        private var splitViewRetryCount = 0

        func configureWindowIfNeeded() {
            guard let window = view?.window else {
                retryConfigureSplitView()
                return
            }

            if configuredWindow !== window {
                configuredWindow = window
                configuredSplitView = nil
                splitViewRetryCount = 0
                window.setFrameAutosaveName(WindowStateController.frameAutosaveName)
                window.setFrameUsingName(WindowStateController.frameAutosaveName)
            }

            configureSplitViewIfNeeded(in: window.contentView)
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
            splitView.autosaveName = NSSplitView.AutosaveName(WindowStateController.splitViewAutosaveName)
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
