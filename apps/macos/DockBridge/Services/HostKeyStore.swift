import Foundation

final class HostKeyStore: @unchecked Sendable {
    static let shared = HostKeyStore()

    private let fileName = "known_hosts.json"

    private init() {}

    var knownHostsPath: URL {
        DockBridgePaths.appSupportDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    func ensureStoreExists() throws {
        let path = knownHostsPath
        let parent = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: path.path) {
            let emptyStore = Data("{}".utf8)
            try emptyStore.write(to: path, options: .atomic)
        }

        try setSecurePermissions(for: path)
    }

    func setSecurePermissions(for url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }
}
