import Darwin
import Dispatch
import Foundation

final class StoreChangeMonitor: @unchecked Sendable {
    let directoryURL: URL
    let onChange: @Sendable () -> Void
    let queue = DispatchQueue(label: "Pond.store-change-monitor")
    var source: DispatchSourceFileSystemObject?
    var pendingChange: DispatchWorkItem?

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

    func scheduleChange() {
        pendingChange?.cancel()

        let change = DispatchWorkItem { [onChange] in
            onChange()
        }
        pendingChange = change

        // Atomic writes can emit several directory events; reload once after the burst settles.
        queue.asyncAfter(deadline: .now() + .milliseconds(100), execute: change)
    }
}
