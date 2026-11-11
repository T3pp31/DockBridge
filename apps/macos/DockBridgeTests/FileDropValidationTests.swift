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

    func testLocalListingPreservesDirectoryDropTargetsWhenResourceValuesFail() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-list-fallback-\(UUID().uuidString)", isDirectory: true)
        let folder = directory.appendingPathComponent("z-folder", isDirectory: false)
        let file = directory.appendingPathComponent("a-file.txt")
        let hiddenFile = directory.appendingPathComponent(".hidden")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("file".utf8).write(to: file)
        try Data().write(to: hiddenFile)

        let readableItems = try LocalFileItem.list(directory: directory, showHiddenFiles: false)
        XCTAssertEqual(readableItems.map(\.name), ["z-folder", "a-file.txt"])
        XCTAssertEqual(readableItems.last?.size, 4)
        XCTAssertNotNil(readableItems.last?.modificationDate)
        let includingHidden = try LocalFileItem.list(directory: directory, showHiddenFiles: true)
        XCTAssertEqual(Set(includingHidden.map(\.name)), ["z-folder", "a-file.txt", ".hidden"])

        var attempts: [String: Int] = [:]
        let items = try LocalFileItem.list(
            directory: directory,
            showHiddenFiles: false,
            resourceValuesProvider: { url, _ in
                attempts[url.lastPathComponent, default: 0] += 1
                throw CocoaError(.fileReadNoPermission)
            }
        )

        // Both the initial lookup and the initializer's retry must fail.
        XCTAssertEqual(attempts, ["z-folder": 2, "a-file.txt": 2])
        XCTAssertEqual(items.map(\.name), ["z-folder", "a-file.txt"])
        let folderItem = try XCTUnwrap(items.first)
        let fileItem = try XCTUnwrap(items.last)
        XCTAssertTrue(folderItem.isDirectory)
        XCTAssertFalse(fileItem.isDirectory)
        XCTAssertEqual(FileDropValidation.destinationDirectory(forLocalDropOn: folderItem), folderItem.url)
        XCTAssertNil(FileDropValidation.destinationDirectory(forLocalDropOn: fileItem))
        for item in items {
            XCTAssertEqual(item.size, 0)
            XCTAssertNil(item.modificationDate)
        }
    }

    func testLocalItemInitializerRecoversDirectoryTypeWhenResourceValuesFail() {
        let directory = FileManager.default.temporaryDirectory
        let item = LocalFileItem(url: directory, resourceValuesProvider: { _, _ in
            throw CocoaError(.fileReadNoPermission)
        })

        XCTAssertTrue(item.isDirectory)
        XCTAssertEqual(item.size, 0)
        XCTAssertNil(item.modificationDate)
    }

    func testLocalItemRecoversOnlyMissingResourceTypeAndPreservesMetadata() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-item-type-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("file.txt")
        try Data("data".utf8).write(to: file)
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        XCTAssertNil(values.isDirectory)
        XCTAssertNotNil(values.contentModificationDate)

        let missingType = LocalFileItem(url: directory, resourceValues: values)
        XCTAssertTrue(missingType.isDirectory)
        XCTAssertEqual(missingType.size, 4)
        XCTAssertEqual(missingType.modificationDate, values.contentModificationDate)

        // Explicit false is known metadata, not a reason to query the file system.
        let fileValues = try file.resourceValues(forKeys: [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
        ])
        let explicitType = LocalFileItem(url: directory, resourceValues: fileValues)
        XCTAssertFalse(explicitType.isDirectory)
        XCTAssertEqual(explicitType.size, 4)
        XCTAssertEqual(explicitType.modificationDate, fileValues.contentModificationDate)
    }

    func testLocalListingKeepsDisappearingEntryWithoutLosingReadableEntries() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-list-disappearing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disappearing = directory.appendingPathComponent("disappearing.txt")
        let readable = directory.appendingPathComponent("readable.txt")
        try Data().write(to: disappearing)
        try Data("data".utf8).write(to: readable)
        var removed = false

        let items = try LocalFileItem.list(
            directory: directory,
            showHiddenFiles: false,
            resourceValuesProvider: { url, keys in
                if url.lastPathComponent == disappearing.lastPathComponent {
                    if !removed {
                        try FileManager.default.removeItem(at: url)
                        removed = true
                    }
                    throw CocoaError(.fileNoSuchFile)
                }
                return try url.resourceValues(forKeys: keys)
            }
        )

        XCTAssertTrue(removed)
        XCTAssertEqual(items.map(\.name), ["disappearing.txt", "readable.txt"])
        let missingItem = try XCTUnwrap(items.first)
        XCTAssertFalse(missingItem.isDirectory)
        XCTAssertEqual(missingItem.size, 0)
        XCTAssertNil(missingItem.modificationDate)
        XCTAssertNil(FileDropValidation.destinationDirectory(forLocalDropOn: missingItem))
        let readableItem = try XCTUnwrap(items.last)
        XCTAssertFalse(readableItem.isDirectory)
        XCTAssertEqual(readableItem.size, 4)
        XCTAssertNotNil(readableItem.modificationDate)
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
