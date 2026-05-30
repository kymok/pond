import AppKit
import Foundation
import TaskCore
import UniformTypeIdentifiers

enum CollectionExportFormat: String, CaseIterable {
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

struct CollectionExportDestination {
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

    static func safeFilename(_ name: String) -> String {
        let unsafeCharacters = CharacterSet(charactersIn: "/:")
            .union(.newlines)
            .union(.controlCharacters)
        let filename = name.components(separatedBy: unsafeCharacters).joined(separator: "-")
        return filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Collection" : filename
    }

    static func url(_ url: URL, withExtension fileExtension: String) -> URL {
        guard url.pathExtension.localizedCaseInsensitiveCompare(fileExtension) != .orderedSame else {
            return url
        }

        return url.deletingPathExtension().appendingPathExtension(fileExtension)
    }
}

final class CollectionExportAccessoryView: NSView {
    static let height: CGFloat = 56

    override var intrinsicContentSize: NSSize {
        NSSize(width: 420, height: Self.height)
    }
}

struct CollectionExportPayload: Encodable {
    var collection: String
    var exportedAt: Date
    var items: [TaskItem]

    func encoded(as format: CollectionExportFormat) throws -> Data {
        switch format {
        case .json:
            return try PondJSON.exportEncoder(pretty: true).encode(self)

        case .jsonl:
            let encoder = PondJSON.exportEncoder(pretty: false)
            let lines = try items.map { item in
                let data = try encoder.encode(item)
                return String(decoding: data, as: UTF8.self)
            }
            return Data((lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")).utf8)
        }
    }
}

