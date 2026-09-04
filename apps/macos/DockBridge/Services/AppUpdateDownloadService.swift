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
    func mount(dmgURL: URL) throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", "-nobrowse", "-plist", dmgURL.path]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw AppUpdateDownloadError.mountFailed
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let plist = try PropertyListSerialization.propertyList(from: outputData, format: nil)
        guard let dictionary = plist as? [String: Any],
              let systemEntities = dictionary["system-entities"] as? [[String: Any]] else {
            throw AppUpdateDownloadError.mountFailed
        }

        for entity in systemEntities {
            guard let mountPoint = entity["mount-point"] as? String,
                  entity["content"] as? String == "Apple_HFS" || entity["content"] as? String == "Apple_APFS" else {
                continue
            }
            return URL(fileURLWithPath: mountPoint, isDirectory: true)
        }

        throw AppUpdateDownloadError.mountFailed
    }

    func unmount(mountPoint: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mountPoint.path, "-quiet"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

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
    case appBundleNotFound
    case signatureVerificationFailed(ReleaseCodeSignatureVerifierError)
}

extension AppUpdateDownloadError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidDownloadResponse:
            return "The update download could not be completed."
        case .checksumMissing:
            return "The update checksum is not available. Download the update manually from the release page."
        case .checksumFetchFailed:
            return "The update checksum could not be verified."
        case .checksumMismatch:
            return "The downloaded update does not match the published checksum."
        case .mountFailed:
            return "The update disk image could not be opened."
        case .unmountFailed:
            return "The update disk image could not be closed."
        case .appBundleNotFound:
            return "The update disk image does not contain the DockBridge app."
        case .signatureVerificationFailed(let error):
            return signatureVerificationMessage(for: error)
        }
    }

    private func signatureVerificationMessage(for error: ReleaseCodeSignatureVerifierError) -> String {
        switch error {
        case .unsignedBundle:
            return "The update is not properly signed."
        case .bundleIdentifierMismatch:
            return "The update app bundle identifier does not match DockBridge."
        case .missingDeveloperIDSignature:
            return "The update is not signed with a Developer ID certificate."
        case .teamIdentifierMismatch:
            return "The update was signed by an unexpected Apple Developer team."
        case .certificateFingerprintMismatch:
            return "The update signing certificate does not match the expected release certificate."
        case .notarizationMissing:
            return "The update is not notarized by Apple."
        case .misconfiguredSignaturePolicy:
            return "Update signature policy is misconfigured. Expected team identifier and certificate fingerprint must both be set when signed updates are required."
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

    init(
        downloadSession: URLSessionDownloadProviding = URLSession.shared,
        dataSession: URLSessionDataProviding = URLSession.shared,
        signatureVerifier: AppBundleSignatureVerifying = ReleaseCodeSignatureVerifier(),
        dmgMounter: DMGImageMounting = HdiutilDMGImageMounter(),
        fileManager: FileManager = .default
    ) {
        self.downloadSession = downloadSession
        self.dataSession = dataSession
        self.signatureVerifier = signatureVerifier
        self.dmgMounter = dmgMounter
        self.fileManager = fileManager
    }

    func downloadVerifyAndReveal(update: AppUpdateInfo) async throws {
        let downloadedURL = try await downloadDMG(from: update.downloadURL)

        var shouldCleanUpDownload = true
        defer {
            if shouldCleanUpDownload {
                try? fileManager.removeItem(at: downloadedURL)
            }
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

        NSWorkspace.shared.open(mountPoint)
        shouldUnmount = false
        shouldCleanUpDownload = false
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

        let fileData = try Data(contentsOf: fileURL)
        let digest = SHA256.hash(data: fileData)
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
}
