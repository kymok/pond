import AppKit

import SwiftUI

struct FocusedTextFieldKeyHandler: View {
    let isActive: Bool
    let onKeyDown: (NSEvent, NSTextView) -> Bool

    var body: some View {
        LocalKeyDownHandler(isActive: isActive) { event in
            guard let fieldEditor = event.window?.firstResponder as? NSTextView else {
                return false
            }

            return onKeyDown(event, fieldEditor)
        }
    }
}

struct LocalKeyDownHandler: NSViewRepresentable {
    let isActive: Bool
    let onKeyDown: (NSEvent) -> Bool

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
        context.coordinator.onKeyDown = onKeyDown

        if isActive {
            context.coordinator.installMonitorIfNeeded()
        } else {
            context.coordinator.removeMonitor()
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var onKeyDown: (NSEvent) -> Bool = { _ in false }

        private var monitor: Any?

        func installMonitorIfNeeded() {
            guard monitor == nil else {
                return
            }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.handle(event) else {
                    return event
                }

                return nil
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }

            monitor = nil
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard let window = view?.window,
                  event.window === window || event.window?.sheetParent === window else {
                return false
            }

            return onKeyDown(event)
        }
    }
}
