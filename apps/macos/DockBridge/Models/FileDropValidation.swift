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
