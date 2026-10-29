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

    /// Creates a valid owner-only store if absent, and secures an existing regular file.
    /// Existing contents are preserved; symlinks and non-regular files are rejected.
    func ensureStoreDirectoryExists() throws {
        let path = knownHostsPath
        let parent = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        if try secureExistingStore(at: path) { return }

        // Publish only a fully written store. Linking is atomic and refuses to
        // replace any destination created by another caller in the meantime.
        let temporary = parent.appendingPathComponent(".known-hosts-\(UUID().uuidString).partial")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.unlink(temporary.path) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        let emptyStore = try JSONSerialization.data(withJSONObject: ["entries": [Any]()])
        try file.write(contentsOf: emptyStore)
        try file.synchronize()
        if Darwin.link(temporary.path, path.path) != 0 {
            guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard try secureExistingStore(at: path) else { throw POSIXError(.ENOENT) }
        }
    }

    private func secureExistingStore(at path: URL) throws -> Bool {
        // Nonblocking open prevents a FIFO at the store path from hanging startup.
        let descriptor = Darwin.open(path.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EINVAL) }
        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return true
    }

    func setSecurePermissions(for url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }
}
