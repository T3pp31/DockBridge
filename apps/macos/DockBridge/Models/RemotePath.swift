import Foundation

enum RemotePath {
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

    static func parent(of path: String) -> String {
        let normalized = normalize(path)
        guard normalized != "/" else { return "/" }

        let withoutTrailingSlash = normalized.hasSuffix("/")
            ? String(normalized.dropLast())
            : normalized

        let parent = (withoutTrailingSlash as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : normalize(parent)
    }

    static func normalize(_ path: String) -> String {
        var value = path.replacingOccurrences(of: "//", with: "/")
        if value.isEmpty {
            value = "/"
        }
        if !value.hasPrefix("/") {
            value = "/" + value
        }
        return value
    }

    static func directoryPath(_ path: String) -> String {
        let normalized = normalize(path)
        return normalized.hasSuffix("/") ? normalized : normalized + "/"
    }
}
