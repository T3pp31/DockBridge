import Foundation

enum FileDropValidation {
    static func isDisplayedLocalItem(_ payload: LocalFileDragPayload, in items: [LocalFileItem]) -> Bool {
        let payloadPath = normalizedLocalPath(payload.url)
        return items.contains { item in
            !item.isParentDirectory
                && normalizedLocalPath(item.url) == payloadPath
                && item.isDirectory == payload.isDirectory
        }
    }

    static func isDisplayedRemoteItem(_ payload: RemoteFileDragPayload, in items: [RemoteFileRecord]) -> Bool {
        guard let normalizedPayloadPath = try? RemotePath.normalize(payload.path) else {
            return false
        }
        return items.contains { item in
            guard !item.isParentDirectory,
                  let normalizedItemPath = try? RemotePath.normalize(item.path) else {
                return false
            }
            return normalizedItemPath == normalizedPayloadPath && item.isDirectory == payload.isDirectory
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
        // NOTE: This resolves symlinks at check time. Callers should re-run
        // this validation immediately before the actual move to narrow the
        // TOCTOU window (see MainViewModel.moveLocalItem).
        let sourcePath = normalizedLocalPath(source)
        let directoryPath = normalizedLocalPath(directory)

        if sourcePath == directoryPath {
            return false
        }

        let sourceParentPath = (sourcePath as NSString).deletingLastPathComponent
        if sourceParentPath == directoryPath {
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
