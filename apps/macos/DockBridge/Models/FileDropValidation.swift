import Foundation

enum FileDropValidation {
    static func canUploadLocalItem(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        return FileManager.default.isReadableFile(atPath: url.path)
    }

    static func canMoveLocalItem(from source: URL, to directory: URL) -> Bool {
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
        let normalizedSource = RemotePath.normalize(source)
        let normalizedDirectory = RemotePath.directoryPath(directory)

        if normalizedSource == RemotePath.normalize(normalizedDirectory) {
            return false
        }

        let sourceParent = RemotePath.directoryPath(RemotePath.parent(of: normalizedSource))
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
        return RemotePath.directoryPath(item.path)
    }

    static func destinationDirectory(forLocalDropOn item: LocalFileItem) -> URL? {
        guard item.isDirectory else { return nil }
        return item.url
    }
}
