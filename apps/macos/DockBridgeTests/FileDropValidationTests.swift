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
            size: 10,
            modifiedAtSecs: nil
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
