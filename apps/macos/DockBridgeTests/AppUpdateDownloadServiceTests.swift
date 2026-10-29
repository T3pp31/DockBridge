import CryptoKit
import Foundation
import XCTest
@testable import DockBridge

private struct MockDownloadURLSession: URLSessionDownloadProviding {
    let fileURL: URL
    let statusCode: Int

    func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (fileURL, response)
    }
}

private struct MockChecksumURLSession: URLSessionDataProviding {
    let checksumLine: String
    let statusCode: Int

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(checksumLine.utf8), response)
    }
}

private struct MockDMGImageMounter: DMGImageMounting {
    let mountPoint: URL

    func mount(dmgURL: URL) throws -> URL {
        return mountPoint
    }

    func unmount(mountPoint: URL) throws {}
}

private struct MockSignatureVerifier: AppBundleSignatureVerifying {
    var error: ReleaseCodeSignatureVerifierError?

    func verifyAppBundle(at url: URL) throws {
        if let error {
            throw error
        }
    }
}

final class AppUpdateDownloadServiceTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppUpdateDownloadServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        try super.tearDownWithError()
    }

    func testDownloadVerifyAndRevealRejectsChecksumMismatch() async throws {
        let dmgURL = temporaryDirectory.appendingPathComponent("update.dmg")
        try Data("dmg-contents".utf8).write(to: dmgURL)

        let service = AppUpdateDownloadService(
            downloadSession: MockDownloadURLSession(fileURL: dmgURL, statusCode: 200),
            dataSession: MockChecksumURLSession(checksumLine: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef update.dmg", statusCode: 200),
            signatureVerifier: MockSignatureVerifier(),
            dmgMounter: MockDMGImageMounter(mountPoint: temporaryDirectory.appendingPathComponent("mount")),
            fileManager: .default
        )

        let update = AppUpdateInfo(
            version: "0.2.0",
            downloadURL: URL(string: "https://github.com/T3pp31/DockBridge/releases/download/v0.2.0/DockBridge-0.2.0-macOS.dmg")!,
            checksumURL: URL(string: "https://github.com/T3pp31/DockBridge/releases/download/v0.2.0/DockBridge-0.2.0-macOS.dmg.sha256")!,
            releasePageURL: URL(string: "https://github.com/T3pp31/DockBridge/releases/tag/v0.2.0")!
        )

        do {
            try await service.downloadVerifyAndReveal(update: update)
            XCTFail("Expected checksum mismatch")
        } catch let error as AppUpdateDownloadError {
            XCTAssertEqual(error, .checksumMismatch)
        }
    }

    func testDownloadVerifyAndRevealRejectsSignatureVerificationFailure() async throws {
        let dmgURL = temporaryDirectory.appendingPathComponent("update.dmg")
        try Data("dmg-contents".utf8).write(to: dmgURL)
        let mountPoint = temporaryDirectory.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        _ = try makeTestBundle(bundleIdentifier: "com.dockbridge.app", in: mountPoint)

        let digest = SHA256.hash(data: Data("dmg-contents".utf8))
        let checksum = digest.map { String(format: "%02x", $0) }.joined()

        let service = AppUpdateDownloadService(
            downloadSession: MockDownloadURLSession(fileURL: dmgURL, statusCode: 200),
            dataSession: MockChecksumURLSession(checksumLine: "\(checksum) update.dmg", statusCode: 200),
            signatureVerifier: MockSignatureVerifier(error: .unsignedBundle),
            dmgMounter: MockDMGImageMounter(mountPoint: mountPoint),
            fileManager: .default
        )

        let update = AppUpdateInfo(
            version: "0.2.0",
            downloadURL: URL(string: "https://github.com/T3pp31/DockBridge/releases/download/v0.2.0/DockBridge-0.2.0-macOS.dmg")!,
            checksumURL: URL(string: "https://github.com/T3pp31/DockBridge/releases/download/v0.2.0/DockBridge-0.2.0-macOS.dmg.sha256")!,
            releasePageURL: URL(string: "https://github.com/T3pp31/DockBridge/releases/tag/v0.2.0")!
        )

        do {
            try await service.downloadVerifyAndReveal(update: update)
            XCTFail("Expected signature verification failure")
        } catch let error as AppUpdateDownloadError {
            XCTAssertEqual(error, .signatureVerificationFailed(.unsignedBundle))
        }
    }

    func testDownloadVerifyAndRevealRejectsMissingAppBundle() async throws {
        let dmgURL = temporaryDirectory.appendingPathComponent("update.dmg")
        try Data("dmg-contents".utf8).write(to: dmgURL)
        let mountPoint = temporaryDirectory.appendingPathComponent("empty-mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        let digest = SHA256.hash(data: Data("dmg-contents".utf8))
        let checksum = digest.map { String(format: "%02x", $0) }.joined()

        let service = AppUpdateDownloadService(
            downloadSession: MockDownloadURLSession(fileURL: dmgURL, statusCode: 200),
            dataSession: MockChecksumURLSession(checksumLine: "\(checksum) update.dmg", statusCode: 200),
            signatureVerifier: MockSignatureVerifier(),
            dmgMounter: MockDMGImageMounter(mountPoint: mountPoint),
            fileManager: .default
        )

        let update = AppUpdateInfo(
            version: "0.2.0",
            downloadURL: URL(string: "https://github.com/T3pp31/DockBridge/releases/download/v0.2.0/DockBridge-0.2.0-macOS.dmg")!,
            checksumURL: URL(string: "https://github.com/T3pp31/DockBridge/releases/download/v0.2.0/DockBridge-0.2.0-macOS.dmg.sha256")!,
            releasePageURL: URL(string: "https://github.com/T3pp31/DockBridge/releases/tag/v0.2.0")!
        )

        do {
            try await service.downloadVerifyAndReveal(update: update)
            XCTFail("Expected missing app bundle error")
        } catch let error as AppUpdateDownloadError {
            XCTAssertEqual(error, .appBundleNotFound)
        }
    }

    func testDownloadVerifyAndRevealRejectsMissingChecksum() async throws {
        let dmgURL = temporaryDirectory.appendingPathComponent("update.dmg")
        try Data("dmg-contents".utf8).write(to: dmgURL)

        let service = AppUpdateDownloadService(
            downloadSession: MockDownloadURLSession(fileURL: dmgURL, statusCode: 200),
            dataSession: MockChecksumURLSession(checksumLine: "", statusCode: 200),
            signatureVerifier: MockSignatureVerifier(),
            dmgMounter: MockDMGImageMounter(mountPoint: temporaryDirectory.appendingPathComponent("mount")),
            fileManager: .default
        )

        let update = AppUpdateInfo(
            version: "0.2.0",
            downloadURL: URL(string: "https://github.com/T3pp31/DockBridge/releases/download/v0.2.0/DockBridge-0.2.0-macOS.dmg")!,
            checksumURL: nil,
            releasePageURL: URL(string: "https://github.com/T3pp31/DockBridge/releases/tag/v0.2.0")!
        )

        do {
            try await service.downloadVerifyAndReveal(update: update)
            XCTFail("Expected missing checksum error")
        } catch let error as AppUpdateDownloadError {
            XCTAssertEqual(error, .checksumMissing)
        }
    }

    func testDownloadVerifyAndRevealIgnoresUnexpectedAppBundles() async throws {
        let dmgURL = temporaryDirectory.appendingPathComponent("update.dmg")
        try Data("dmg-contents".utf8).write(to: dmgURL)
        let mountPoint = temporaryDirectory.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        _ = try makeTestBundle(bundleIdentifier: "com.evil.app", bundleName: "Evil.app", in: mountPoint)

        let digest = SHA256.hash(data: Data("dmg-contents".utf8))
        let checksum = digest.map { String(format: "%02x", $0) }.joined()

        let service = AppUpdateDownloadService(
            downloadSession: MockDownloadURLSession(fileURL: dmgURL, statusCode: 200),
            dataSession: MockChecksumURLSession(checksumLine: "\(checksum) update.dmg", statusCode: 200),
            signatureVerifier: MockSignatureVerifier(),
            dmgMounter: MockDMGImageMounter(mountPoint: mountPoint),
            fileManager: .default
        )

        let update = AppUpdateInfo(
            version: "0.2.0",
            downloadURL: URL(string: "https://github.com/T3pp31/DockBridge/releases/download/v0.2.0/DockBridge-0.2.0-macOS.dmg")!,
            checksumURL: URL(string: "https://github.com/T3pp31/DockBridge/releases/download/v0.2.0/DockBridge-0.2.0-macOS.dmg.sha256")!,
            releasePageURL: URL(string: "https://github.com/T3pp31/DockBridge/releases/tag/v0.2.0")!
        )

        do {
            try await service.downloadVerifyAndReveal(update: update)
            XCTFail("Expected missing app bundle error")
        } catch let error as AppUpdateDownloadError {
            XCTAssertEqual(error, .appBundleNotFound)
        }
    }

    func testStreamingChecksumMatchesOneShotDigestAcrossChunkBoundaries() async throws {
        let chunkSize = 1024 * 1024
        let sizes = [0, chunkSize, chunkSize + 1, 2 * chunkSize + chunkSize / 2]
        let mountPoint = temporaryDirectory.appendingPathComponent("empty-mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let update = AppUpdateInfo(
            version: "0.2.0",
            downloadURL: URL(string: "https://example.com/update.dmg")!,
            checksumURL: URL(string: "https://example.com/update.dmg.sha256")!,
            releasePageURL: URL(string: "https://example.com/release")!
        )

        for size in sizes {
            let data = Data((0..<size).map { UInt8(truncatingIfNeeded: $0) })
            // A one-shot digest is an independent oracle for the streaming loop.
            let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            for matches in [true, false] {
                let dmgURL = temporaryDirectory.appendingPathComponent(UUID().uuidString + ".dmg")
                var downloadedData = data
                if !matches, !downloadedData.isEmpty {
                    // Corrupt the final byte, including the byte beyond a full chunk.
                    downloadedData[downloadedData.count - 1] ^= 1
                }
                try downloadedData.write(to: dmgURL)
                let expected = !matches && size == 0 ? String(repeating: "0", count: 64) : checksum
                let service = AppUpdateDownloadService(
                    downloadSession: MockDownloadURLSession(fileURL: dmgURL, statusCode: 200),
                    dataSession: MockChecksumURLSession(checksumLine: "\(expected) update.dmg", statusCode: 200),
                    signatureVerifier: MockSignatureVerifier(),
                    dmgMounter: MockDMGImageMounter(mountPoint: mountPoint),
                    fileManager: .default
                )

                do {
                    try await service.downloadVerifyAndReveal(update: update)
                    XCTFail("Expected verification to stop before revealing the update")
                } catch let error as AppUpdateDownloadError {
                    // A valid checksum must reach bundle validation. Using an
                    // empty mock mount avoids opening Finder or mounting a DMG.
                    XCTAssertEqual(error, matches ? .appBundleNotFound : .checksumMismatch,
                                   "size=\(size), matches=\(matches)")
                }
            }
        }
    }

    private func makeTestBundle(
        bundleIdentifier: String,
        bundleName: String = "DockBridge.app",
        in directory: URL
    ) throws -> URL {
        let bundleURL = directory.appendingPathComponent(bundleName, isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: contentsURL.appendingPathComponent("MacOS", isDirectory: true),
            withIntermediateDirectories: true
        )

        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleExecutable": "DockBridge",
            "CFBundlePackageType": "APPL",
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"))
        return bundleURL
    }
}
