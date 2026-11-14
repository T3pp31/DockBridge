import CoreTransferable
import XCTest
@testable import DockBridge

final class FileDropValidationTests: XCTestCase {
    func testLocalFileExportAllowsAccessingOriginalURL() {
        let url = URL(fileURLWithPath: "/tmp/DockBridge drag/大きな archive.bin", isDirectory: false)
        let payload = LocalFileDragPayload(url: url, isDirectory: false)

        let exportedFile = payload.exportedFile

        XCTAssertEqual(exportedFile.file, url)
        XCTAssertFalse(exportedFile.file.hasDirectoryPath)
        XCTAssertTrue(exportedFile.allowAccessingOriginalFile, "External drops must not stage a full copy")
    }

    func testLocalDirectoryExportAllowsAccessingOriginalURL() {
        let url = URL(fileURLWithPath: "/tmp/DockBridge drag/ディレクトリ", isDirectory: true)
        let payload = LocalFileDragPayload(url: url, isDirectory: true)

        let exportedFile = payload.exportedFile

        XCTAssertEqual(exportedFile.file, url)
        XCTAssertTrue(exportedFile.file.hasDirectoryPath)
        XCTAssertTrue(exportedFile.allowAccessingOriginalFile, "Directory trees must not be copied before a drop")
    }

    func testLocalDragPayloadCodableRoundTripPreservesInternalDropData() throws {
        for isDirectory in [false, true] {
            let url = URL(fileURLWithPath: "/tmp/DockBridge drag/日本語 item", isDirectory: isDirectory)
            let payload = LocalFileDragPayload(url: url, isDirectory: isDirectory)

            let data = try JSONEncoder().encode(payload)
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(Set(fields.keys), Set(["path", "isDirectory"]))

            let decoded = try JSONDecoder().decode(LocalFileDragPayload.self, from: data)
            XCTAssertEqual(decoded, payload)
            XCTAssertEqual(decoded.url, url)
            XCTAssertEqual(decoded.isDirectory, isDirectory)
        }
    }

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
            .appendingPathComponent("file-drop-upload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("upload.txt")
        try Data("upload".utf8).write(to: fileURL)

        XCTAssertTrue(FileDropValidation.canUploadLocalItem(at: fileURL))
        XCTAssertTrue(FileDropValidation.canUploadLocalItem(at: directory))
        XCTAssertFalse(
            FileDropValidation.canUploadLocalItem(
                at: directory.appendingPathComponent("missing-upload-file.txt")
            )
        )
    }

    func testCanUploadLocalItemRejectsExistingUnreadableFile() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("file-drop-unreadable-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("unreadable.txt")
        try Data("upload".utf8).write(to: fileURL)
        try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path)

        XCTAssertTrue(fileManager.fileExists(atPath: fileURL.path))
        XCTAssertFalse(FileDropValidation.canUploadLocalItem(at: fileURL))
        XCTAssertFalse(FileDropValidation.canUploadExternalItem(at: fileURL))
    }

    func testCanUploadLocalItemFollowsSymlinksAndRejectsDanglingLinks() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("file-drop-upload-links-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("upload.txt")
        let folderURL = directory.appendingPathComponent("folder", isDirectory: true)
        try Data("upload".utf8).write(to: fileURL)
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)

        for target in [fileURL, folderURL] {
            let link = directory.appendingPathComponent(target.lastPathComponent + "-link")
            try fileManager.createSymbolicLink(at: link, withDestinationURL: target)
            XCTAssertTrue(FileDropValidation.canUploadLocalItem(at: link))
            XCTAssertTrue(FileDropValidation.canUploadExternalItem(at: link))

            try fileManager.removeItem(at: target)
            XCTAssertFalse(FileDropValidation.canUploadLocalItem(at: link))
            XCTAssertFalse(FileDropValidation.canUploadExternalItem(at: link))
        }
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
