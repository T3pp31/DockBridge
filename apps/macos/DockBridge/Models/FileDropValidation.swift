import Foundation

enum FileDropValidation {
    private struct DisplayedItemKey: Hashable {
        let path: String
        let isDirectory: Bool
    }

    // Precomputed normalized index for the currently displayed listing.
    // MainViewModel caches this per listing/filter snapshot and invalidates it
    // on directory reload or filter change so repeated drops only normalize the
    // dragged payloads (issue #1417).
    struct DisplayedLocalItems {
        private let keys: Set<DisplayedItemKey>
        private let normalizePath: (URL) -> String

        init(
            _ items: [LocalFileItem],
            normalizePath: ((URL) -> String)? = nil
        ) {
            let payloadNormalizer = normalizePath ?? FileDropValidation.normalizedLocalPath
            self.normalizePath = payloadNormalizer
            var keys: Set<DisplayedItemKey> = []
            keys.reserveCapacity(items.count)
            if let normalizePath {
                for item in items where !item.isParentDirectory {
                    keys.insert(DisplayedItemKey(path: normalizePath(item.url), isDirectory: item.isDirectory))
                }
            } else {
                // Non-symlink entries share their parent directory's symlink
                // resolution, avoiding O(N) filesystem symlink resolution calls
                // when indexing large directories.
                var resolvedParents: [URL: URL] = [:]
                for item in items where !item.isParentDirectory {
                    let path: String
                    if item.isSymbolicLink == false {
                        let standardized = item.url.standardizedFileURL
                        let parent = standardized.deletingLastPathComponent()
                        let resolvedParent: URL
                        if let cached = resolvedParents[parent] {
                            resolvedParent = cached
                        } else {
                            resolvedParent = parent.resolvingSymlinksInPath()
                            resolvedParents[parent] = resolvedParent
                        }
                        path = resolvedParent.appendingPathComponent(standardized.lastPathComponent).path
                    } else {
                        path = FileDropValidation.normalizedLocalPath(item.url)
                    }
                    keys.insert(DisplayedItemKey(path: path, isDirectory: item.isDirectory))
                }
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
            normalizePath: ((String) throws -> String)? = nil
        ) {
            let effectiveNormalizePath = normalizePath ?? RemotePath.normalize
            self.normalizePath = effectiveNormalizePath
            var keys: Set<DisplayedItemKey> = []
            keys.reserveCapacity(items.count)
            for item in items where !item.isParentDirectory {
                guard let path = try? effectiveNormalizePath(item.path) else { continue }
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
        // Missing paths are also unreadable, so a separate existence check is unnecessary.
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
