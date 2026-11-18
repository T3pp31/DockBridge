import AppKit
import CryptoKit
import Foundation

protocol URLSessionDownloadProviding: Sendable {
    func download(for request: URLRequest) async throws -> (URL, URLResponse)
}

extension URLSession: URLSessionDownloadProviding {
    func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        try await download(for: request, delegate: nil)
    }
}

protocol DMGImageMounting: Sendable {
    func mount(dmgURL: URL) throws -> URL
    func unmount(mountPoint: URL) throws
}

struct HdiutilDMGImageMounter: DMGImageMounting {
    private let executableURL: URL

    init(executableURL: URL = URL(fileURLWithPath: "/usr/bin/hdiutil")) {
        self.executableURL = executableURL
    }

    func mount(dmgURL: URL) throws -> URL {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["attach", "-nobrowse", "-plist", dmgURL.path]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        // Diagnostics are not used; an unread stderr pipe could block hdiutil.
        process.standardError = FileHandle.nullDevice

        try process.run()
        // Drain stdout while hdiutil is running, before waiting for its exit.
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw AppUpdateDownloadError.mountFailed
        }

        let plist = try? PropertyListSerialization.propertyList(from: outputData, format: nil)
        let systemEntities = (plist as? [String: Any])?["system-entities"] as? [[String: Any]]


        for entity in systemEntities ?? [] {
            guard let mountPoint = entity["mount-point"] as? String,
                  let content = entity["content-hint"] as? String ?? entity["content"] as? String,
                  content == "Apple_HFS" || content == "Apple_APFS" else {
                continue
            }
            return URL(fileURLWithPath: mountPoint, isDirectory: true)
        }

        // A successful attach can still lack a usable volume. Detach only
        // on this failure path; the caller owns a successfully mounted image.
        if let deviceEntry = systemEntities?.compactMap({ $0["dev-entry"] as? String }).first {
            try? unmount(mountPoint: URL(fileURLWithPath: deviceEntry))
        }
        throw AppUpdateDownloadError.mountFailed
    }

    func unmount(mountPoint: URL) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["detach", mountPoint.path, "-quiet"]
        // Neither stream is used for detach, including failure-path cleanup.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw AppUpdateDownloadError.unmountFailed
        }
    }
}

enum AppUpdateDownloadError: Error, Equatable {
    case invalidDownloadResponse
    case checksumMissing
    case checksumFetchFailed
    case checksumMismatch
    case mountFailed
    case unmountFailed
    case revealFailed
    case appBundleNotFound
    case signatureVerificationFailed(ReleaseCodeSignatureVerifierError)
    /// The signed bundle's version does not match the release version the app
    /// offered, so installing it could downgrade to an older release (issue #1372).
    case versionMismatch(expected: String, actual: String)
}

extension AppUpdateDownloadError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidDownloadResponse:
            return String(localized: "The update download could not be completed.")
        case .checksumMissing:
            return String(localized: "The update checksum is not available. Download the update manually from the release page.")
        case .checksumFetchFailed:
            return String(localized: "The update checksum could not be verified.")
        case .checksumMismatch:
            return String(localized: "The downloaded update does not match the published checksum.")
        case .mountFailed:
            return String(localized: "The update disk image could not be opened.")
        case .unmountFailed:
            return String(localized: "The update disk image could not be closed.")
        case .revealFailed:
            return String(localized: "The update could not be shown in Finder. Try again or download the update manually from the release page.")
        case .appBundleNotFound:
            return String(localized: "The update disk image does not contain the DockBridge app.")
        case .signatureVerificationFailed(let error):
            return signatureVerificationMessage(for: error)
        case .versionMismatch(let expected, let actual):
            let format = String(
                localized: "The update app bundle version (%@) does not match the offered release version (%@). Download the update manually from the release page."
            )
            return String(format: format, actual, expected)
        }
    }

    private func signatureVerificationMessage(for error: ReleaseCodeSignatureVerifierError) -> String {
        switch error {
        case .unsignedBundle:
            return String(localized: "The update is not properly signed.")
        case .bundleIdentifierMismatch:
            return String(localized: "The update app bundle identifier does not match DockBridge.")
        case .missingDeveloperIDSignature:
            return String(localized: "The update is not signed with a Developer ID certificate.")
        case .teamIdentifierMismatch:
            return String(localized: "The update was signed by an unexpected Apple Developer team.")
        case .certificateFingerprintMismatch:
            return String(localized: "The update signing certificate does not match the expected release certificate.")
        case .notarizationMissing:
            return String(localized: "The update is not notarized by Apple.")
        case .misconfiguredSignaturePolicy:
            return String(localized: "Update signature policy is misconfigured. Expected team identifier must be set for signed or notarized updates; certificate fingerprint is also required for signed updates.")
        }
    }
}

protocol AppUpdateDownloading: Sendable {
    func downloadVerifyAndReveal(update: AppUpdateInfo) async throws
}

// All stored properties are immutable `let` constants set at init, so this is safe for concurrent access.
final class AppUpdateDownloadService: AppUpdateDownloading, @unchecked Sendable {
    private let downloadSession: URLSessionDownloadProviding
    private let dataSession: URLSessionDataProviding
    private let signatureVerifier: AppBundleSignatureVerifying
    private let dmgMounter: DMGImageMounting
    private let fileManager: FileManager
    private let revealInFinder: @MainActor @Sendable (URL) -> Bool

    init(
        downloadSession: URLSessionDownloadProviding = URLSession.shared,
        dataSession: URLSessionDataProviding = URLSession.shared,
        signatureVerifier: AppBundleSignatureVerifying = ReleaseCodeSignatureVerifier(),
        dmgMounter: DMGImageMounting = HdiutilDMGImageMounter(),
        fileManager: FileManager = .default,
        revealInFinder: @escaping @MainActor @Sendable (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.downloadSession = downloadSession
        self.dataSession = dataSession
        self.signatureVerifier = signatureVerifier
        self.dmgMounter = dmgMounter
        self.fileManager = fileManager
        self.revealInFinder = revealInFinder
    }

    func downloadVerifyAndReveal(update: AppUpdateInfo) async throws {
        let downloadedURL = try await downloadDMG(from: update.downloadURL)

        defer {
            try? fileManager.removeItem(at: downloadedURL)
        }

        if let checksumURL = update.checksumURL {
            try await verifyChecksum(of: downloadedURL, checksumURL: checksumURL)
        } else {
            throw AppUpdateDownloadError.checksumMissing
        }

        let mountPoint = try dmgMounter.mount(dmgURL: downloadedURL)

        var shouldUnmount = true
        defer {
            if shouldUnmount {
                try? dmgMounter.unmount(mountPoint: mountPoint)
            }
        }

        guard let appBundleURL = findAppBundle(in: mountPoint) else {
            throw AppUpdateDownloadError.appBundleNotFound
        }

        do {
            try signatureVerifier.verifyAppBundle(at: appBundleURL)
        } catch let error as ReleaseCodeSignatureVerifierError {
            throw AppUpdateDownloadError.signatureVerificationFailed(error)
        } catch {
            throw AppUpdateDownloadError.signatureVerificationFailed(.unsignedBundle)
        }

        // A signature only proves the bundle is an authentic DockBridge build,
        // not that it is the release the app offered. Without this check a
        // validly signed older release could be served under the expected
        // asset names and downgrade the installation (issue #1372).
        let bundleVersion = try readBundleShortVersion(at: appBundleURL)
        guard VersionComparator.compare(bundleVersion, update.version) == .orderedSame else {
            throw AppUpdateDownloadError.versionMismatch(
                expected: VersionComparator.normalize(update.version),
                actual: bundleVersion
            )
        }

        guard await revealInFinder(mountPoint) else {
            throw AppUpdateDownloadError.revealFailed
        }
        // Finder needs the mounted volume for the user's manual copy.
        // Removing the backing pathname is safe while the image remains
        // mounted, and avoids leaving the downloaded DMG in temporary files.
        shouldUnmount = false
    }

    private func downloadDMG(from url: URL) async throws -> URL {
        let request = URLRequest(url: url)
        let (temporaryURL, response) = try await downloadSession.download(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw AppUpdateDownloadError.invalidDownloadResponse
        }

        let destinationURL = fileManager.temporaryDirectory
            .appendingPathComponent("DockBridge-update-\(UUID().uuidString).dmg")
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        return destinationURL
    }

    private func verifyChecksum(of fileURL: URL, checksumURL: URL) async throws {
        let request = URLRequest(url: checksumURL)
        let (data, response) = try await dataSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw AppUpdateDownloadError.checksumFetchFailed
        }

        guard let checksumLine = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .first else {
            throw AppUpdateDownloadError.checksumFetchFailed
        }

        let expectedChecksum = String(checksumLine)
        guard expectedChecksum.count == 64,
              expectedChecksum.allSatisfy({ $0.isHexDigit }) else {
            throw AppUpdateDownloadError.checksumFetchFailed
        }

        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer {
            try? fileHandle.close()
        }

        var hasher = SHA256()
        while let chunk = try fileHandle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        let actualChecksum = digest.map { String(format: "%02x", $0) }.joined()
        guard actualChecksum == expectedChecksum.lowercased() else {
            throw AppUpdateDownloadError.checksumMismatch
        }
    }

    private func findAppBundle(in directory: URL) -> URL? {
        let expectedBundleURL = directory.appendingPathComponent(
            "\(AppUpdateConfig.appName).app",
            isDirectory: true
        )
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: expectedBundleURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return expectedBundleURL
    }

    /// Reads `CFBundleShortVersionString` from the bundle's `Info.plist`.
    ///
    /// Mirrors the signature verifier's hardened read: no symlink following,
    /// no FIFO blocking, and a bounded size. A missing or unreadable value is
    /// reported as an app-bundle failure rather than a version mismatch.
    private func readBundleShortVersion(at bundleURL: URL) throws -> String {
        let infoPlistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        let fileDescriptor = open(infoPlistURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fileDescriptor >= 0 else {
            throw AppUpdateDownloadError.appBundleNotFound
        }
        defer { close(fileDescriptor) }

        var fileStat = stat()
        let sizeLimit = AppUpdateConfig.maxInfoPlistSizeBytes
        guard fstat(fileDescriptor, &fileStat) == 0,
              (fileStat.st_mode & S_IFMT) == S_IFREG,
              fileStat.st_size >= 0,
              fileStat.st_size <= sizeLimit else {
            throw AppUpdateDownloadError.appBundleNotFound
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = read(fileDescriptor, &buffer, min(buffer.count, sizeLimit - data.count + 1))
            if bytesRead < 0 {
                if errno == EINTR {
                    continue
                }
                throw AppUpdateDownloadError.appBundleNotFound
            }
            if bytesRead == 0 {
                break
            }
            guard data.count + bytesRead <= sizeLimit else {
                throw AppUpdateDownloadError.appBundleNotFound
            }
            data.append(buffer, count: bytesRead)
        }

        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dictionary = plist as? [String: Any],
              let version = dictionary["CFBundleShortVersionString"] as? String,
              !version.isEmpty else {
            throw AppUpdateDownloadError.appBundleNotFound
        }
        return version
    }
}
