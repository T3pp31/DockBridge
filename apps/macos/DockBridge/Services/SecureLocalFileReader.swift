import Darwin
import Foundation

enum SecureLocalFileReaderError: LocalizedError {
    case readFailed(String)
    case symlinkNotAllowed
    case ownerMismatch
    case insecurePermissions

    var errorDescription: String? {
        switch self {
        case .readFailed(let message):
            return message
        case .symlinkNotAllowed:
            return "Refusing to follow symbolic link."
        case .ownerMismatch:
            return "File is not owned by the current user."
        case .insecurePermissions:
            return "File has insecure permissions."
        }
    }
}

enum SecureLocalFileReader {
    static func readData(from url: URL) throws -> Data {
        let path = url.path

        var linkStat = stat()
        if lstat(path, &linkStat) != 0 {
            throw SecureLocalFileReaderError.readFailed(String(cString: strerror(errno)))
        }

        if (linkStat.st_mode & S_IFMT) == S_IFLNK {
            throw SecureLocalFileReaderError.symlinkNotAllowed
        }

        let fd = open(path, O_RDONLY | O_NOFOLLOW)
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

        let effectiveUID = geteuid()
        if fileStat.st_uid != effectiveUID {
            throw SecureLocalFileReaderError.ownerMismatch
        }

        let mode = fileStat.st_mode & 0o777
        guard mode == 0o600 || mode == 0o400 else {
            throw SecureLocalFileReaderError.insecurePermissions
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = read(fd, &buffer, buffer.count)
            if bytesRead < 0 {
                throw SecureLocalFileReaderError.readFailed(String(cString: strerror(errno)))
            }
            if bytesRead == 0 {
                break
            }
            data.append(buffer, count: bytesRead)
        }

        return data
    }
}
