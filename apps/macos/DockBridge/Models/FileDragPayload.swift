import CoreTransferable
import Foundation
import UniformTypeIdentifiers

#if canImport(AppKit)
import AppKit
#endif

extension UTType {
    static let dockBridgeLocalFile = UTType(exportedAs: "dev.dockbridge.local-file")
    static let dockBridgeRemoteFile = UTType(exportedAs: "dev.dockbridge.remote-file")
}

struct LocalFileDragPayload: Codable, Hashable, Transferable {
    let path: String
    let isDirectory: Bool

    init(url: URL, isDirectory: Bool) {
        self.path = url.path
        self.isDirectory = isDirectory
    }

    var url: URL {
        URL(fileURLWithPath: path, isDirectory: isDirectory)
    }

    var exportedFile: SentTransferredFile {
        // Let destinations access the original instead of staging a full copy.
        SentTransferredFile(url, allowAccessingOriginalFile: true)
    }

    static var transferRepresentation: some TransferRepresentation {
        // External destinations (Finder, Mail, Terminal) receive the file
        // URL itself; app-internal drops stay Codable. FileRepresentation
        // comes first so external apps do not fall back to the custom UTType.
        FileRepresentation(exportedContentType: .fileURL) { payload in
            payload.exportedFile
        }
        CodableRepresentation(contentType: .dockBridgeLocalFile)
    }
}

struct RemoteFileDragPayload: Codable, Hashable, Transferable {
    let path: String
    let isDirectory: Bool

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .dockBridgeRemoteFile)
    }
}
