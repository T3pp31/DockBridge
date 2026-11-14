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

        let displayedItems = FileDropValidation.DisplayedLocalItems([displayedItem])
        XCTAssertTrue(displayedItems.contains(LocalFileDragPayload(url: displayedFile, isDirectory: false)))
        XCTAssertFalse(displayedItems.contains(spoofedPayload))
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

        let displayedItems = FileDropValidation.DisplayedRemoteItems([displayedItem])
        XCTAssertTrue(displayedItems.contains(RemoteFileDragPayload(path: "/remote/visible.txt", isDirectory: false)))
        XCTAssertFalse(displayedItems.contains(spoofedPayload))
    }

    func testLocalDisplayedIndexNormalizesListingOnceAndEachPayloadOnce() {
        let directory = URL(fileURLWithPath: "/tmp/file-drop-index", isDirectory: true)
        let items = (0..<512).map {
            LocalFileItem(
                url: directory.appendingPathComponent("file-\($0)"),
                resourceValuesProvider: { _, _ in
                    throw CocoaError(.fileReadNoPermission)
                }
            )
        }
        var normalizationCount = 0
        let displayedItems = FileDropValidation.DisplayedLocalItems(
            [LocalFileItem(parentOf: directory)] + items,
            normalizePath: {
                normalizationCount += 1
                return $0.standardizedFileURL.path
            }
        )
        XCTAssertEqual(normalizationCount, items.count, "The parent row must not be indexed")

        // Include late hits, misses, and type mismatches without timing-dependent assertions.
        let payloads = (0..<128).flatMap { _ in
            [
                LocalFileDragPayload(url: items[511].url, isDirectory: false),
                LocalFileDragPayload(url: directory.appendingPathComponent("missing"), isDirectory: false),
                LocalFileDragPayload(url: items[511].url, isDirectory: true),
                LocalFileDragPayload(url: directory.deletingLastPathComponent(), isDirectory: true),
            ]
        }
        let accepted = payloads.filter { displayedItems.contains($0) }
        XCTAssertEqual(accepted, payloads.enumerated().compactMap { $0.offset % 4 == 0 ? $0.element : nil })
        XCTAssertEqual(normalizationCount, items.count + payloads.count)
        XCTAssertFalse(FileDropValidation.DisplayedLocalItems([]).contains(payloads[0]))
    }

    func testLocalDisplayedIndexRebuildObservesSymlinkTargetAndListingChanges() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("file-drop-index-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.txt")
        let second = directory.appendingPathComponent("second.txt")
        try Data().write(to: first)
        try Data().write(to: second)
        let link = directory.appendingPathComponent("link.txt")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: first)
        let items = [LocalFileItem(url: link)]
        let firstPayload = LocalFileDragPayload(url: first, isDirectory: false)
        let secondPayload = LocalFileDragPayload(url: second, isDirectory: false)
        let displayedItems = FileDropValidation.DisplayedLocalItems(items)
        XCTAssertTrue(displayedItems.contains(firstPayload))
        XCTAssertTrue(displayedItems.contains(LocalFileDragPayload(url: link, isDirectory: false)))
        XCTAssertFalse(displayedItems.contains(secondPayload))

        try fileManager.removeItem(at: link)
        try fileManager.createSymbolicLink(at: link, withDestinationURL: second)
        let nextDropItems = FileDropValidation.DisplayedLocalItems(items)
        XCTAssertFalse(nextDropItems.contains(firstPayload))
        XCTAssertTrue(nextDropItems.contains(secondPayload))
        let refreshedListing = FileDropValidation.DisplayedLocalItems([LocalFileItem(url: first)])
        XCTAssertTrue(refreshedListing.contains(firstPayload))
        XCTAssertFalse(refreshedListing.contains(secondPayload))
    }

    func testRemoteDisplayedIndexNormalizesListingOnceAndEachPayloadOnce() {
        let items = (0..<512).map { remoteItem(path: "/remote/file-\($0)") }
        let invalidItems = [remoteItem(path: "/remote/../invalid"), remoteItem(path: "/remote/null\0")]
        let parent = remoteItem(path: "/remote", isDirectory: true, name: "..")
        var normalizationCount = 0
        let displayedItems = FileDropValidation.DisplayedRemoteItems(
            [parent] + items + invalidItems,
            normalizePath: {
                normalizationCount += 1
                return try RemotePath.normalize($0)
            }
        )
        XCTAssertEqual(normalizationCount, items.count + invalidItems.count)

        let payloads = (0..<128).flatMap { _ in
            [
                RemoteFileDragPayload(path: "//remote/./file-511/", isDirectory: false),
                RemoteFileDragPayload(path: "/remote/missing", isDirectory: false),
                RemoteFileDragPayload(path: "/remote/file-511", isDirectory: true),
                RemoteFileDragPayload(path: "/remote", isDirectory: true),
                RemoteFileDragPayload(path: "/remote/../invalid", isDirectory: false),
                RemoteFileDragPayload(path: "/remote/null\0", isDirectory: false),
            ]
        }
        let accepted = payloads.filter { displayedItems.contains($0) }
        XCTAssertEqual(accepted, payloads.enumerated().compactMap { $0.offset % 6 == 0 ? $0.element : nil })
        XCTAssertEqual(normalizationCount, items.count + invalidItems.count + payloads.count)
        XCTAssertFalse(FileDropValidation.DisplayedRemoteItems([]).contains(payloads[0]))
    }

    func testDisplayedIndexesKeepDirectoryFlagInNormalizedKey() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-drop-index-file-\(UUID().uuidString)")
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-drop-index-directory-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: directoryURL)
        }
        try Data().write(to: fileURL)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let localItems = FileDropValidation.DisplayedLocalItems([
            LocalFileItem(url: fileURL),
            LocalFileItem(url: directoryURL),
        ])
        let remoteItems = FileDropValidation.DisplayedRemoteItems([
            remoteItem(path: "/remote/shared"),
            remoteItem(path: "//remote/./shared/", isDirectory: true),
        ])
        for isDirectory in [false, true] {
            XCTAssertEqual(localItems.contains(LocalFileDragPayload(url: fileURL, isDirectory: isDirectory)), !isDirectory)
            XCTAssertEqual(localItems.contains(LocalFileDragPayload(url: directoryURL, isDirectory: isDirectory)), isDirectory)
            XCTAssertTrue(remoteItems.contains(RemoteFileDragPayload(path: "/remote/shared", isDirectory: isDirectory)))
        }
    }

    private func remoteItem(path: String, isDirectory: Bool = false, name: String = "item") -> RemoteFileRecord {
        RemoteFileRecord(
            name: name, path: path, isDirectory: isDirectory, isSymlink: false, size: 0,
            modifiedAtSecs: nil, permissions: nil, uid: nil, gid: nil,
            symlinkTarget: nil, symlinkTargetIsDir: nil
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
