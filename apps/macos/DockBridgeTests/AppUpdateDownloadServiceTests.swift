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

        let service = AppUpdateDownloadService(
            downloadSession: MockDownloadURLSession(fileURL: dmgURL, statusCode: 200),
            dataSession: MockChecksumURLSession(checksumLine: "", statusCode: 200),
            signatureVerifier: MockSignatureVerifier(),
            dmgMounter: MockDMGImageMounter(mountPoint: mountPoint),
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
            XCTFail("Expected missing app bundle error")
        } catch let error as AppUpdateDownloadError {
            XCTAssertEqual(error, .appBundleNotFound)
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
