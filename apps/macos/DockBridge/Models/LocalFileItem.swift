import Foundation

struct LocalFileItem: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modificationDate: Date?

    var id: String { url.path }

    init(
        url: URL,
        resourceValuesProvider: (URL, Set<URLResourceKey>) throws -> URLResourceValues = {
            try $0.resourceValues(forKeys: $1)
        }
    ) {
        self.url = url
        self.name = url.lastPathComponent

        let values = try? resourceValuesProvider(url, [
            .isDirectoryKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ])
        self.isDirectory = values?.isDirectory ?? Self.isDirectoryOnFileSystem(at: url)
        self.size = Int64(values?.fileSize ?? 0)
        self.modificationDate = values?.contentModificationDate
    }

    init(url: URL, resourceValues values: URLResourceValues) {
        self.url = url
        self.name = url.lastPathComponent
        self.isDirectory = values.isDirectory ?? Self.isDirectoryOnFileSystem(at: url)
        self.size = Int64(values.fileSize ?? 0)
        self.modificationDate = values.contentModificationDate
    }

    init(parentOf directory: URL) {
        let parent = directory.deletingLastPathComponent()
        self.url = parent
        self.name = ".."
        self.isDirectory = true
        self.size = 0
        self.modificationDate = nil
    }

    var isParentDirectory: Bool { name == ".." }

    /// POSIX permission bits (e.g. "rwxr-xr-x") from the file system, or nil
    /// when they cannot be read.
    static func posixPermissionsString(for url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let posix = attributes[.posixPermissions] as? NSNumber else { return nil }
        let mode = UInt32(truncating: posix)
        return PermissionFormatter.string(from: mode)
    }

    var modificationSortKey: Date { modificationDate ?? .distantPast }

    private static func isDirectoryOnFileSystem(at url: URL) -> Bool {
        // A size/date lookup can fail even when the entry's type is still readable.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }

    static func list(
        directory: URL,
        showHiddenFiles: Bool,
        resourceValuesProvider: (URL, Set<URLResourceKey>) throws -> URLResourceValues = {
            try $0.resourceValues(forKeys: $1)
        }
    ) throws -> [LocalFileItem] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: showHiddenFiles ? [] : [.skipsHiddenFiles]
        )

        // Per-entry resilience: a single unreadable / disappearing entry must
        // not blank the whole local pane. Fall back to the minimal initializer
        // (size/date unknown) when resourceValues fails, e.g. a file deleted
        // between the directory listing and this call, or an unreadable
        // protected directory.
        let items = urls.compactMap { url -> LocalFileItem? in
            guard let values = try? resourceValuesProvider(url, keys) else {
                // Keep the entry visible with unknown size/date instead of
                // silently dropping it (issue #686). The initializer also tries
                // an independent type lookup if resource values remain unreadable.
                return LocalFileItem(url: url, resourceValuesProvider: resourceValuesProvider)
            }
            return LocalFileItem(url: url, resourceValues: values)
        }

        return items.sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory && !rhs.isDirectory
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }
}
