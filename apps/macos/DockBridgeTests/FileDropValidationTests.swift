import XCTest
@testable import DockBridge

final class FileDropValidationTests: XCTestCase {
    func testRejectsMovingLocalItemIntoSameDirectory() {
        let source = URL(fileURLWithPath: "/tmp/project/readme.txt")
        let directory = URL(fileURLWithPath: "/tmp/project")

        XCTAssertFalse(FileDropValidation.canMoveLocalItem(from: source, to: directory))
    }

    func testRejectsMovingLocalDirectoryIntoDescendant() {
        let source = URL(fileURLWithPath: "/tmp/project")
        let directory = URL(fileURLWithPath: "/tmp/project/nested")

        XCTAssertFalse(FileDropValidation.canMoveLocalItem(from: source, to: directory))
    }

    func testAllowsMovingLocalItemIntoDifferentDirectory() {
        let source = URL(fileURLWithPath: "/tmp/project/readme.txt")
        let directory = URL(fileURLWithPath: "/tmp/archive")

        XCTAssertTrue(FileDropValidation.canMoveLocalItem(from: source, to: directory))
    }

    func testLocalMoveValidationResolvesSymlinkedAncestors() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("file-drop-ancestor-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let realDirectory = root.appendingPathComponent("real", isDirectory: true)
        let project = realDirectory.appendingPathComponent("project", isDirectory: true)
        try fileManager.createDirectory(
            at: project.appendingPathComponent("nested", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("file".utf8).write(to: project.appendingPathComponent("readme.txt"))
        try fileManager.createDirectory(
            at: realDirectory.appendingPathComponent("project-backup", isDirectory: true),
            withIntermediateDirectories: true
        )
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try fileManager.createSymbolicLink(at: alias, withDestinationURL: realDirectory)
        let source = alias.appendingPathComponent("project", isDirectory: true)

        // Both the alias spelling and the real destination path must be rejected.
        for parent in [realDirectory, alias] {
            let directory = parent.appendingPathComponent("project", isDirectory: true)
            XCTAssertFalse(FileDropValidation.canMoveLocalItem(from: source, to: directory))
            XCTAssertFalse(FileDropValidation.canMoveLocalItem(from: source, to: parent))
            XCTAssertFalse(
                FileDropValidation.canMoveLocalItem(
                    from: source,
                    to: directory.appendingPathComponent("nested", isDirectory: true)
                )
            )
            XCTAssertFalse(
                FileDropValidation.canMoveLocalItem(
                    from: source.appendingPathComponent("readme.txt"),
                    to: directory
                )
            )
            // A shared name prefix alone does not make a directory a descendant.
            XCTAssertTrue(
                FileDropValidation.canMoveLocalItem(
                    from: source,
                    to: parent.appendingPathComponent("project-backup", isDirectory: true)
                )
            )
        }
    }

    func testAllowsMovingSymlinkItselfWithSymlinkedAncestors() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("file-drop-link-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let realDirectory = root.appendingPathComponent("real", isDirectory: true)
        let target = realDirectory.appendingPathComponent("target", isDirectory: true)
        let nested = target.appendingPathComponent("nested", isDirectory: true)
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        let link = realDirectory.appendingPathComponent("link")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: target)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try fileManager.createSymbolicLink(at: alias, withDestinationURL: realDirectory)

        for source in [link, alias.appendingPathComponent("link")] {
            // Moving a link into its target (or the target's child) is not a self-move.
            XCTAssertTrue(FileDropValidation.canMoveLocalItem(from: source, to: target))
            XCTAssertTrue(FileDropValidation.canMoveLocalItem(from: source, to: nested))
            XCTAssertFalse(FileDropValidation.canMoveLocalItem(from: source, to: realDirectory))
            XCTAssertFalse(FileDropValidation.canMoveLocalItem(from: source, to: alias))
        }
    }

    func testCanUploadLocalItemRequiresExistingReadableFile() throws {
        let directory = FileManager.default.temporaryDirectory
        let fileURL = directory.appendingPathComponent("file-drop-upload-validation.txt")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data("upload".utf8))
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

        XCTAssertTrue(FileDropValidation.canUploadLocalItem(at: fileURL))
        XCTAssertFalse(
            FileDropValidation.canUploadLocalItem(
                at: directory.appendingPathComponent("missing-upload-file.txt")
            )
        )
    }

    func testCanUploadExternalItemRequiresFileURL() throws {
        let directory = FileManager.default.temporaryDirectory
        let fileURL = directory.appendingPathComponent("file-drop-external-upload-validation.txt")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data("upload".utf8))
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

        XCTAssertTrue(FileDropValidation.canUploadExternalItem(at: fileURL))
        XCTAssertFalse(
            FileDropValidation.canUploadExternalItem(
                at: URL(string: "https://example.com/not-a-local-file.txt")!
            )
        )
    }

    func testRejectsSpoofedLocalPayloadNotInDisplayedItems() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-drop-spoof-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let displayedFile = directory.appendingPathComponent("visible.txt")
        FileManager.default.createFile(atPath: displayedFile.path, contents: Data("visible".utf8))

        let spoofedFile = directory.appendingPathComponent("secret.txt")
        FileManager.default.createFile(atPath: spoofedFile.path, contents: Data("secret".utf8))

        let displayedItem = LocalFileItem(url: displayedFile)
        let spoofedPayload = LocalFileDragPayload(url: spoofedFile, isDirectory: false)

        XCTAssertTrue(
            FileDropValidation.isDisplayedLocalItem(
                LocalFileDragPayload(url: displayedFile, isDirectory: false),
                in: [displayedItem]
            )
        )
        XCTAssertFalse(
            FileDropValidation.isDisplayedLocalItem(spoofedPayload, in: [displayedItem])
        )
    }

    func testRejectsSpoofedRemotePayloadNotInDisplayedItems() {
        let displayedItem = RemoteFileRecord(
            name: "visible.txt",
            path: "/remote/visible.txt",
            isDirectory: false,
            isSymlink: false,
            size: 10,
            modifiedAtSecs: nil,
            permissions: nil,
            uid: nil,
            gid: nil,
            symlinkTarget: nil,
            symlinkTargetIsDir: nil
        )
        let spoofedPayload = RemoteFileDragPayload(path: "/remote/secret.txt", isDirectory: false)

        XCTAssertTrue(
            FileDropValidation.isDisplayedRemoteItem(
                RemoteFileDragPayload(path: "/remote/visible.txt", isDirectory: false),
                in: [displayedItem]
            )
        )
        XCTAssertFalse(
            FileDropValidation.isDisplayedRemoteItem(spoofedPayload, in: [displayedItem])
        )
    }

    func testRejectsMovingRemoteItemIntoSameDirectory() {
        XCTAssertFalse(
            FileDropValidation.canMoveRemoteItem(
                from: "/var/www/index.html",
                to: "/var/www"
            )
        )
    }

    func testRejectsMovingRemoteDirectoryIntoDescendant() {
        XCTAssertFalse(
            FileDropValidation.canMoveRemoteItem(
                from: "/var/www",
                to: "/var/www/public"
            )
        )
    }

    func testAllowsMovingRemoteItemIntoDifferentDirectory() {
        XCTAssertTrue(
            FileDropValidation.canMoveRemoteItem(
                from: "/var/www/index.html",
                to: "/var/backup"
            )
        )
    }

    func testDestinationDirectoryOnlyForFolders() throws {
        let directory = FileManager.default.temporaryDirectory
        let fileURL = directory.appendingPathComponent("file-drop-validation-file.txt")
        let folderURL = directory.appendingPathComponent("file-drop-validation-folder", isDirectory: true)

        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: fileURL.path, contents: Data())

        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: folderURL)
        }

        let file = LocalFileItem(url: fileURL)
        let folder = LocalFileItem(url: folderURL)

        XCTAssertNil(FileDropValidation.destinationDirectory(forLocalDropOn: file))
        XCTAssertEqual(
            FileDropValidation.destinationDirectory(forLocalDropOn: folder)?.standardizedFileURL,
            folder.url.standardizedFileURL
        )
    }
}
