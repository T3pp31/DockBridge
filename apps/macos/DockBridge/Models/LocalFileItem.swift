import Foundation

struct LocalFileItem: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modificationDate: Date?

    var id: String { url.path }

    init(url: URL) {
        self.url = url
        self.name = url.lastPathComponent

        let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ])
        self.isDirectory = values?.isDirectory ?? false
        self.size = Int64(values?.fileSize ?? 0)
        self.modificationDate = values?.contentModificationDate
    }

    init(url: URL, resourceValues values: URLResourceValues) {
        self.url = url
        self.name = url.lastPathComponent
        self.isDirectory = values.isDirectory ?? false
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
        let values = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey])
        _ = values
        var mode: UInt16 = 0
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let posix = attributes?[.posixPermissions] as? NSNumber {
            mode = UInt16(truncating: posix)
        }
        guard mode != 0 else { return nil }
        return PermissionFormatter.string(from: mode)
    }

    var modificationSortKey: Date { modificationDate ?? .distantPast }

    static func list(
        directory: URL,
        showHiddenFiles: Bool
    ) throws -> [LocalFileItem] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: showHiddenFiles ? [] : [.skipsHiddenFiles]
        )

        let items = try urls.map { url -> LocalFileItem in
            let values = try url.resourceValues(forKeys: keys)
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
