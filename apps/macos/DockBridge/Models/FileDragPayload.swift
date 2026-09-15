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
        URL(fileURLWithPath: path)
    }

    static var transferRepresentation: some TransferRepresentation {
        // App-internal drops stay Codable; external destinations (Finder,
        // Mail, Terminal) receive the file URL itself.
        CodableRepresentation(contentType: .dockBridgeLocalFile)
        FileRepresentation(exportedContentType: .fileURL) { payload in
            SentTransferredFile(payload.url)
        }
    }

    func itemProvider() -> NSItemProvider {
        guard let data = try? JSONEncoder().encode(self) else {
            return NSItemProvider()
        }
        return NSItemProvider(item: data as NSData, typeIdentifier: UTType.dockBridgeLocalFile.identifier)
    }
}

struct RemoteFileDragPayload: Codable, Hashable, Transferable {
    let path: String
    let isDirectory: Bool

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .dockBridgeRemoteFile)
    }

    func itemProvider() -> NSItemProvider {
        guard let data = try? JSONEncoder().encode(self) else {
            return NSItemProvider()
        }
        return NSItemProvider(item: data as NSData, typeIdentifier: UTType.dockBridgeRemoteFile.identifier)
    }
}
