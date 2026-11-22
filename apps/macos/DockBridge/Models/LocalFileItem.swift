import Foundation

struct LocalFileItem: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isSymbolicLink: Bool?
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
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ])
        self.isDirectory = values?.isDirectory ?? Self.isDirectoryOnFileSystem(at: url)
        self.isSymbolicLink = values?.isSymbolicLink
        self.size = Int64(values?.fileSize ?? 0)
        self.modificationDate = values?.contentModificationDate
    }

    init(url: URL, resourceValues values: URLResourceValues) {
        self.url = url
        self.name = url.lastPathComponent
        self.isDirectory = values.isDirectory ?? Self.isDirectoryOnFileSystem(at: url)
        self.isSymbolicLink = values.isSymbolicLink
        self.size = Int64(values.fileSize ?? 0)
        self.modificationDate = values.contentModificationDate
    }

    init(parentOf directory: URL) {
        let parent = directory.deletingLastPathComponent()
        self.url = parent
        self.name = ".."
        self.isDirectory = true
        self.isSymbolicLink = false
        self.size = 0
        self.modificationDate = nil
    }

    var isParentDirectory: Bool { name == ".." }

    /// Listing sort key: the name with case and diacritics folded using
    /// locale-independent Unicode folding (`locale: nil`), so the result does
    /// not depend on the user's locale (e.g. Turkish dotless-i folding) and is
    /// consistent with the plain code-point comparison in `list`.
    ///
    /// Ordering contract for `list`: folders first, then ascending folded key,
    /// then ascending raw name as a deterministic tie-break.
    static func listingSortKey(for name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

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
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
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

        // Fold each name once and sort on plain string comparisons instead of
        // calling localizedCaseInsensitiveCompare per comparison (issue #1369).
        // The key lives only for this sort, so the model keeps its synthesized
        // Equatable/Hashable. See `listingSortKey(for:)` for the order contract.
        return items
            .map { (key: listingSortKey(for: $0.name), item: $0) }
            .sorted { lhs, rhs in
                if lhs.item.isDirectory != rhs.item.isDirectory {
                    return lhs.item.isDirectory
                }
                if lhs.key != rhs.key {
                    return lhs.key < rhs.key
                }
                return lhs.item.name < rhs.item.name
            }
            .map { $0.item }
    }
}
