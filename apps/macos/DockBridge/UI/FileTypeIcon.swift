import Foundation

enum FileTypeIcon {
    static func systemImage(for filename: String, isDirectory: Bool) -> String {
        if isDirectory {
            return "folder"
        }

        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp", "svg", "ico":
            return "photo"
        case "mp4", "mov", "avi", "mkv", "m4v", "webm":
            return "film"
        case "mp3", "wav", "aac", "flac", "m4a", "ogg":
            return "music.note"
        case "zip", "tar", "gz", "bz2", "xz", "7z", "rar", "tgz":
            return "doc.zipper"
        case "swift", "rs", "py", "js", "ts", "tsx", "jsx", "json", "xml", "html", "htm", "css",
             "md", "txt", "csv", "yaml", "yml", "toml", "sh", "c", "cpp", "h", "java", "go":
            return "doc.text"
        case "pdf":
            return "doc.richtext"
        case "app", "dmg", "pkg":
            return "app"
        default:
            return "doc"
        }
    }
}
