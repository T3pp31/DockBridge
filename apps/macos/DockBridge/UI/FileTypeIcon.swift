import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
import UniformTypeIdentifiers
#endif

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

    /// A 16pt file-type icon for table rows (Issue #229).
    ///
    /// Uses the system UTType icon (Finder-style) when one is available and
    /// falls back to a single-color SF Symbol otherwise, so type is visually
    /// distinguishable in both cases.
    @ViewBuilder
    static func fileIcon(for filename: String, isDirectory: Bool) -> some View {
        #if canImport(AppKit)
        let ext = (filename as NSString).pathExtension
        let utType: UTType = isDirectory
            ? .folder
            : (ext.isEmpty ? UTType.data : (UTType(filenameExtension: ext) ?? .data))
        Image(nsImage: NSWorkspace.shared.icon(for: utType))
            .resizable()
            .interpolation(.high)
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
        #else
        Image(systemName: systemImage(for: filename, isDirectory: isDirectory))
        #endif
    }
}
