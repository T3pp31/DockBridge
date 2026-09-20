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

        // Per-entry resilience: a single unreadable / disappearing entry must
        // not blank the whole local pane. Fall back to the minimal initializer
        // (size/date unknown) when resourceValues fails, e.g. a file deleted
        // between the directory listing and this call, or an unreadable
        // protected directory.
        let items = urls.compactMap { url -> LocalFileItem? in
            guard let values = try? url.resourceValues(forKeys: keys) else {
                return nil
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
