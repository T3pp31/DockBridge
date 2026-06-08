import Foundation

final class HostKeyStore: @unchecked Sendable {
    static let shared = HostKeyStore()

    private let fileName = "known_hosts.json"
    private let baseDirectory: URL

    private init() {
        self.baseDirectory = DockBridgePaths.appSupportDirectory
    }

    init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    var knownHostsPath: URL {
        if baseDirectory == DockBridgePaths.appSupportDirectory {
            return DockBridgePaths.knownHostsFile
        }
        return baseDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    func ensureStoreDirectoryExists() throws {
        let path = knownHostsPath
        let parent = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: path.path) {
            try setSecurePermissions(for: path)
        }
    }

    func setSecurePermissions(for url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }
}
