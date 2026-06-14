import Foundation

enum RemoteEntryNameError: LocalizedError {
    case invalidCharacters

    var errorDescription: String? {
        switch self {
        case .invalidCharacters:
            return "The name cannot contain '/', '..', or null characters."
        }
    }
}

enum RemotePathError: LocalizedError {
    case invalidPath(String)

    var errorDescription: String? {
        switch self {
        case .invalidPath(let path):
            return "The remote path '\(path)' contains an invalid '..' segment."
        }
    }
}

enum RemotePath {
    static func isValidEntryName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        if name.contains("/") { return false }
        if name.contains("\0") { return false }
        if name.contains("..") { return false }
        return true
    }

    static func join(_ base: String, _ name: String) -> String {
        let trimmedName = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if base.isEmpty || base == "/" {
            return "/" + trimmedName
        }

        if base.hasSuffix("/") {
            return base + trimmedName
        }

        return base + "/" + trimmedName
    }

    static func parent(of path: String) throws -> String {
        let normalized = try normalize(path)
        guard normalized != "/" else { return "/" }

        let withoutTrailingSlash = normalized.hasSuffix("/")
            ? String(normalized.dropLast())
            : normalized

        let parent = (withoutTrailingSlash as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : try normalize(parent)
    }

    static func normalize(_ path: String) throws -> String {
        try rejectParentSegment(in: path)

        var value = path.replacingOccurrences(of: "//", with: "/")
        if value.isEmpty {
            value = "/"
        }
        if !value.hasPrefix("/") {
            value = "/" + value
        }
        return value
    }

    static func directoryPath(_ path: String) throws -> String {
        let normalized = try normalize(path)
        return normalized.hasSuffix("/") ? normalized : normalized + "/"
    }

    private static func rejectParentSegment(in path: String) throws {
        if path.split(separator: "/").contains(where: { $0 == ".." }) {
            throw RemotePathError.invalidPath(path)
        }
    }
}
