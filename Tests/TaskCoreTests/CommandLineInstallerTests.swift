import XCTest
@testable import TaskCore

final class CommandLineInstallerTests: XCTestCase {
    func testInstallCanReplaceManagedStaleSymlink() throws {
        let directory = makeDirectory()
        let linkURL = directory.appendingPathComponent("taskpond")
        let recordURL = directory.appendingPathComponent("cli-install.json")
        let oldTargetURL = try makeExecutable(named: "old-task", in: directory)
        let newTargetURL = try makeExecutable(named: "new-task", in: directory)

        try CommandLineInstaller(
            linkURL: linkURL,
            targetURL: oldTargetURL,
            recordURL: recordURL
        ).install()

        let installer = CommandLineInstaller(
            linkURL: linkURL,
            targetURL: newTargetURL,
            recordURL: recordURL
        )

        let staleStatus = installer.status()
        XCTAssertFalse(staleStatus.installed)
        XCTAssertTrue(staleStatus.canInstall)
        XCTAssertTrue(staleStatus.canUninstall)
        XCTAssertNotNil(staleStatus.conflictDescription)

        try installer.install()

        XCTAssertTrue(installer.status().installed)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path),
            newTargetURL.path
        )
    }

    func testUnmanagedSymlinkIsStillTreatedAsConflict() throws {
        let directory = makeDirectory()
        let linkURL = directory.appendingPathComponent("taskpond")
        let targetURL = try makeExecutable(named: "target-task", in: directory)
        let otherURL = try makeExecutable(named: "other-task", in: directory)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: otherURL)

        let status = CommandLineInstaller(
            linkURL: linkURL,
            targetURL: targetURL,
            recordURL: directory.appendingPathComponent("cli-install.json")
        ).status()

        XCTAssertFalse(status.installed)
        XCTAssertFalse(status.canInstall)
        XCTAssertFalse(status.canUninstall)
        XCTAssertNotNil(status.conflictDescription)
    }

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PondInstallerTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeExecutable(named name: String, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
