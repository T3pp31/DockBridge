import Darwin
import Foundation

enum SecureLocalFileReaderError: LocalizedError {
    case readFailed(String)
    case symlinkNotAllowed
    case ownerMismatch
    case insecurePermissions
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case .readFailed(let message):
            return message
        case .symlinkNotAllowed:
            return String(localized: "Refusing to follow symbolic link.")
        case .ownerMismatch:
            return String(localized: "File is not owned by the current user.")
        case .insecurePermissions:
            return String(localized: "File has insecure permissions.")
        case .fileTooLarge:
            return String(localized: "File is too large.")
        }
    }
}

enum SecureLocalFileReader {
    /// Local JSON stores are small; this limit prevents pathological files and
    /// files growing during the read from exhausting memory.
    private static let maxFileSizeBytes: UInt64 = 5 * 1024 * 1024

    static func readData(from url: URL) throws -> Data {
        let path = url.path

        var linkStat = stat()
        if lstat(path, &linkStat) != 0 {
            throw SecureLocalFileReaderError.readFailed(String(cString: strerror(errno)))
        }

        if (linkStat.st_mode & S_IFMT) == S_IFLNK {
            throw SecureLocalFileReaderError.symlinkNotAllowed
        }

        // FIFOs/devices can block forever on open or read; only regular
        // files are eligible (issue #692).
        guard (linkStat.st_mode & S_IFMT) == S_IFREG else {
            throw SecureLocalFileReaderError.readFailed("not a regular file")
        }

        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            let openError = errno
            if openError == ELOOP {
                throw SecureLocalFileReaderError.symlinkNotAllowed
            }
            throw SecureLocalFileReaderError.readFailed(String(cString: strerror(openError)))
        }
        defer { close(fd) }

        var fileStat = stat()
        guard fstat(fd, &fileStat) == 0 else {
            throw SecureLocalFileReaderError.readFailed(String(cString: strerror(errno)))
        }

        guard (fileStat.st_mode & S_IFMT) == S_IFREG else {
            throw SecureLocalFileReaderError.readFailed("not a regular file")
        }

        let effectiveUID = geteuid()
        if fileStat.st_uid != effectiveUID {
            throw SecureLocalFileReaderError.ownerMismatch
        }

        let mode = fileStat.st_mode & 0o777
        guard mode == 0o600 || mode == 0o400 else {
            throw SecureLocalFileReaderError.insecurePermissions
        }

        if fileStat.st_size > maxFileSizeBytes {
            throw SecureLocalFileReaderError.fileTooLarge
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        var totalBytesRead: UInt64 = 0
        while true {
            let bytesRead = read(fd, &buffer, buffer.count)
            if bytesRead < 0 {
                throw SecureLocalFileReaderError.readFailed(String(cString: strerror(errno)))
            }
            if bytesRead == 0 {
                break
            }
            totalBytesRead += UInt64(bytesRead)
            if totalBytesRead > maxFileSizeBytes {
                throw SecureLocalFileReaderError.fileTooLarge
            }
            data.append(buffer, count: bytesRead)
        }

        return data
    }
}
