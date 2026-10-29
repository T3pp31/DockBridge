import Foundation
import Darwin

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

        // Exclusive creation never truncates an existing store or follows a
        // symlink placed at the destination between checking and opening it.
        let createdDescriptor = Darwin.open(path.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        if createdDescriptor >= 0 {
            let file = FileHandle(fileDescriptor: createdDescriptor, closeOnDealloc: true)
            defer { try? file.close() }
            let emptyStore = try JSONSerialization.data(withJSONObject: ["entries": [Any]()])
            try file.write(contentsOf: emptyStore)
        } else {
            guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let descriptor = Darwin.open(path.path, O_WRONLY | O_NOFOLLOW)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { Darwin.close(descriptor) }
            guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    func setSecurePermissions(for url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }
}
