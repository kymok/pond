import Darwin
import Foundation

public struct CLIInstallStatus: Equatable, Sendable {
    public let linkURL: URL
    public let targetURL: URL
    public let installed: Bool
    public let conflictDescription: String?
    public let installDirectoryIsInPath: Bool
    public let canUninstall: Bool

    public var canInstall: Bool {
        !installed && (conflictDescription == nil || canUninstall)
    }
}

public enum CommandLineInstallerError: LocalizedError, Equatable {
    case missingExecutable(URL)
    case conflictingFile(URL)
    case conflictingSymlink(URL, URL)

    public var errorDescription: String? {
        switch self {
        case .missingExecutable(let url):
            "CLI executable was not found at \(url.path)."
        case .conflictingFile(let url):
            "\(url.path) already exists and is not a symlink created by Pond."
        case .conflictingSymlink(let link, let destination):
            "\(link.path) already points to \(destination.path)."
        }
    }
}

public final class CommandLineInstaller: @unchecked Sendable {
    public let linkURL: URL
    public let targetURL: URL
    public let recordURL: URL

    public init(
        linkURL: URL = CommandLineInstaller.defaultLinkURL(),
        targetURL: URL? = nil,
        recordURL: URL = TaskStore.appSupportDirectory().appendingPathComponent("cli-install.json")
    ) {
        self.linkURL = linkURL
        self.targetURL = targetURL ?? CommandLineInstaller.inferTargetURL()
        self.recordURL = recordURL
    }

    public static func defaultLinkURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/taskpond", isDirectory: false)
    }

    public static func inferTargetURL() -> URL {
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            return bundleURL
                .appendingPathComponent("Contents/Library/Helpers/taskpond", isDirectory: false)
                .standardizedFileURL
        }

        if let executableURL = Bundle.main.executableURL {
            let sibling = executableURL
                .deletingLastPathComponent()
                .appendingPathComponent("taskpond", isDirectory: false)
                .standardizedFileURL

            if FileManager.default.fileExists(atPath: sibling.path) {
                return sibling
            }
        }

        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/taskpond", isDirectory: false)
            .standardizedFileURL
    }

    public func status() -> CLIInstallStatus {
        let kind = linkKind(at: linkURL)
        let target = targetURL.standardizedFileURL
        let installed: Bool
        let conflict: String?
        let canUninstall: Bool

        switch kind {
        case .missing:
            installed = false
            conflict = nil
            canUninstall = false
        case .file:
            installed = false
            conflict = "\(linkURL.path) already exists."
            canUninstall = false
        case .symlink(let destination):
            installed = destination.standardizedFileURL == target
            canUninstall = canRemoveSymlink(destination: destination)
            conflict = installed ? nil : "\(linkURL.path) points to \(destination.path)."
        }

        return CLIInstallStatus(
            linkURL: linkURL,
            targetURL: target,
            installed: installed,
            conflictDescription: conflict,
            installDirectoryIsInPath: pathContains(linkURL.deletingLastPathComponent()),
            canUninstall: canUninstall
        )
    }

    public func install() throws {
        guard FileManager.default.isExecutableFile(atPath: targetURL.path) else {
            throw CommandLineInstallerError.missingExecutable(targetURL)
        }

        try FileManager.default.createDirectory(
            at: linkURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        switch linkKind(at: linkURL) {
        case .missing:
            try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)
            try writeRecord()
        case .file:
            throw CommandLineInstallerError.conflictingFile(linkURL)
        case .symlink(let destination):
            if destination.standardizedFileURL == targetURL.standardizedFileURL {
                try writeRecord()
            } else if canRemoveSymlink(destination: destination) {
                try FileManager.default.removeItem(at: linkURL)
                try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)
                try writeRecord()
            } else {
                throw CommandLineInstallerError.conflictingSymlink(linkURL, destination)
            }
        }
    }

    public func uninstall() throws {
        switch linkKind(at: linkURL) {
        case .missing:
            try? FileManager.default.removeItem(at: recordURL)
        case .file:
            throw CommandLineInstallerError.conflictingFile(linkURL)
        case .symlink(let destination):
            guard canRemoveSymlink(destination: destination) else {
                throw CommandLineInstallerError.conflictingSymlink(linkURL, destination)
            }

            try FileManager.default.removeItem(at: linkURL)
            try? FileManager.default.removeItem(at: recordURL)
        }
    }

    public var pathHint: String {
        #"export PATH="$HOME/.local/bin:$PATH""#
    }

    private func canRemoveSymlink(destination: URL) -> Bool {
        if destination.standardizedFileURL == targetURL.standardizedFileURL {
            return true
        }

        guard let record = readRecord() else {
            return false
        }

        return destination.standardizedFileURL == URL(fileURLWithPath: record.targetPath).standardizedFileURL
    }

    private func writeRecord() throws {
        let record = CLIInstallRecord(
            linkPath: linkURL.path,
            targetPath: targetURL.path,
            installedAt: Date()
        )

        try FileManager.default.createDirectory(
            at: recordURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: recordURL, options: .atomic)
    }

    private func readRecord() -> CLIInstallRecord? {
        guard let data = try? Data(contentsOf: recordURL) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CLIInstallRecord.self, from: data)
    }
}

private struct CLIInstallRecord: Codable {
    var linkPath: String
    var targetPath: String
    var installedAt: Date
}

private enum LinkKind {
    case missing
    case file
    case symlink(URL)
}

private func linkKind(at url: URL) -> LinkKind {
    var info = stat()

    guard lstat(url.path, &info) == 0 else {
        return .missing
    }

    if (info.st_mode & S_IFMT) == S_IFLNK {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else {
            return .file
        }

        let destinationURL: URL
        if destination.hasPrefix("/") {
            destinationURL = URL(fileURLWithPath: destination)
        } else {
            destinationURL = url.deletingLastPathComponent().appendingPathComponent(destination)
        }

        return .symlink(destinationURL.standardizedFileURL)
    }

    return .file
}

private func pathContains(_ directory: URL) -> Bool {
    let target = directory.standardizedFileURL.path
    let entries = ProcessInfo.processInfo.environment["PATH", default: ""].split(separator: ":")

    return entries.contains { entry in
        URL(fileURLWithPath: String(entry)).standardizedFileURL.path == target
    }
}
