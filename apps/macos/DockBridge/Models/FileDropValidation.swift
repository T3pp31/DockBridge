import Foundation

enum FileDropValidation {
    private struct DisplayedItemKey: Hashable {
        let path: String
        let isDirectory: Bool
    }

    // Build a fresh index per validation batch, not per payload or across drops:
    // both the displayed listing and local symlink targets may change.
    struct DisplayedLocalItems {
        private let keys: Set<DisplayedItemKey>
        private let normalizePath: (URL) -> String

        init(
            _ items: [LocalFileItem],
            normalizePath: @escaping (URL) -> String = FileDropValidation.normalizedLocalPath
        ) {
            self.normalizePath = normalizePath
            var keys: Set<DisplayedItemKey> = []
            keys.reserveCapacity(items.count)
            for item in items where !item.isParentDirectory {
                keys.insert(DisplayedItemKey(path: normalizePath(item.url), isDirectory: item.isDirectory))
            }
            self.keys = keys
        }

        func contains(_ payload: LocalFileDragPayload) -> Bool {
            keys.contains(DisplayedItemKey(path: normalizePath(payload.url), isDirectory: payload.isDirectory))
        }
    }

    struct DisplayedRemoteItems {
        private let keys: Set<DisplayedItemKey>
        private let normalizePath: (String) throws -> String

        init(
            _ items: [RemoteFileRecord],
            normalizePath: @escaping (String) throws -> String = RemotePath.normalize
        ) {
            self.normalizePath = normalizePath
            var keys: Set<DisplayedItemKey> = []
            keys.reserveCapacity(items.count)
            for item in items where !item.isParentDirectory {
                guard let path = try? normalizePath(item.path) else { continue }
                keys.insert(DisplayedItemKey(path: path, isDirectory: item.isDirectory))
            }
            self.keys = keys
        }

        func contains(_ payload: RemoteFileDragPayload) -> Bool {
            guard let path = try? normalizePath(payload.path) else { return false }
            return keys.contains(DisplayedItemKey(path: path, isDirectory: payload.isDirectory))
        }
    }

    static func canUploadLocalItem(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        return FileManager.default.isReadableFile(atPath: url.path)
    }

    static func canUploadExternalItem(at url: URL) -> Bool {
        guard url.isFileURL else {
            return false
        }
        return canUploadLocalItem(at: url)
    }

    static func canMoveLocalItem(from source: URL, to directory: URL) -> Bool {
        // NOTE: This resolves ancestor and destination symlinks at check time.
        // Callers should re-run this validation immediately before the actual
        // move to narrow the TOCTOU window (see MainViewModel.moveLocalItem).
        // Keep the final source component unresolved: we move the link itself,
        // not its target.
        let standardizedSource = source.standardizedFileURL
        let sourceParent = standardizedSource.deletingLastPathComponent().resolvingSymlinksInPath()
        let sourcePath = sourceParent.appendingPathComponent(standardizedSource.lastPathComponent).path
        let directoryPath = normalizedLocalPath(directory)

        if sourcePath == directoryPath {
            return false
        }

        if sourceParent.path == directoryPath {
            return false
        }

        if directoryPath.hasPrefix(sourcePath + "/") {
            return false
        }

        return true
    }

    private static func normalizedLocalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func canMoveRemoteItem(from source: String, to directory: String) -> Bool {
        guard
            let normalizedSource = try? RemotePath.normalize(source),
            let normalizedDirectory = try? RemotePath.directoryPath(directory)
        else {
            return false
        }

        if normalizedSource == (try? RemotePath.normalize(normalizedDirectory)) {
            return false
        }

        guard
            let sourceParent = try? RemotePath.directoryPath(RemotePath.parent(of: normalizedSource))
        else {
            return false
        }
        if sourceParent == normalizedDirectory {
            return false
        }

        let directoryWithoutTrailingSlash = normalizedDirectory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalizedSource == directoryWithoutTrailingSlash {
            return false
        }
        if normalizedDirectory.hasPrefix(normalizedSource + "/") {
            return false
        }

        return true
    }

    static func destinationDirectory(forRemoteDropOn item: RemoteFileRecord) -> String? {
        guard item.isDirectory else { return nil }
        return try? RemotePath.directoryPath(item.path)
    }

    static func destinationDirectory(forLocalDropOn item: LocalFileItem) -> URL? {
        guard item.isDirectory else { return nil }
        return item.url
    }
}
