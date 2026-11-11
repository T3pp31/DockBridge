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

// Mutable call records are protected by the lock.
private final class MockDMGImageMounter: DMGImageMounting, @unchecked Sendable {
    let mountPoint: URL
    private let lock = NSLock()
    private var mountedDMGURL: URL?
    private var unmountedPoints: [URL] = []

    var downloadedURL: URL? { lock.withLock { mountedDMGURL } }
    var unmountedMountPoints: [URL] { lock.withLock { unmountedPoints } }

    init(mountPoint: URL) {
        self.mountPoint = mountPoint
    }

    func mount(dmgURL: URL) throws -> URL {
        lock.withLock { mountedDMGURL = dmgURL }
        return mountPoint
    }

    func unmount(mountPoint: URL) throws {
        lock.withLock { unmountedPoints.append(mountPoint) }
    }
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

    func testDownloadVerifyAndRevealRequiresFinderToOpenVolume() async throws {
        let contents = Data("dmg-contents".utf8)
        let checksum = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
        let mountPoint = temporaryDirectory.appendingPathComponent("mount", isDirectory: true)
        _ = try makeTestBundle(bundleIdentifier: "com.dockbridge.app", in: mountPoint)
        let update = AppUpdateInfo(
            version: "0.2.0",
            downloadURL: URL(string: "https://example.com/update.dmg")!,
            checksumURL: URL(string: "https://example.com/update.dmg.sha256")!,
            releasePageURL: URL(string: "https://example.com/release")!
        )

        for opensInFinder in [false, true] {
            let dmgURL = temporaryDirectory.appendingPathComponent("update.dmg")
            try contents.write(to: dmgURL)
            let mounter = MockDMGImageMounter(mountPoint: mountPoint)
            let revealRequested = expectation(description: "Reveal volume (opens=\(opensInFinder))")
            let service = AppUpdateDownloadService(
                downloadSession: MockDownloadURLSession(fileURL: dmgURL, statusCode: 200),
                dataSession: MockChecksumURLSession(checksumLine: "\(checksum) update.dmg", statusCode: 200),
                signatureVerifier: MockSignatureVerifier(),
                dmgMounter: mounter,
                revealInFinder: { url in
                    XCTAssertEqual(url, mountPoint)
                    XCTAssertTrue(mounter.unmountedMountPoints.isEmpty)
                    if let downloadedURL = mounter.downloadedURL {
                        XCTAssertTrue(FileManager.default.fileExists(atPath: downloadedURL.path))
                    } else {
                        XCTFail("Expected the image to be mounted before revealing it")
                    }
                    revealRequested.fulfill()
                    return opensInFinder
                }
            )

            do {
                try await service.downloadVerifyAndReveal(update: update)
                XCTAssertTrue(opensInFinder, "A Finder failure must not return success")
            } catch let error as AppUpdateDownloadError {
                XCTAssertFalse(opensInFinder, "A Finder success must not throw")
                XCTAssertEqual(error, .revealFailed)
                XCTAssertEqual(
                    error.localizedDescription,
                    String(localized: "The update could not be shown in Finder. Try again or download the update manually from the release page.")
                )
            }

            await fulfillment(of: [revealRequested], timeout: 1)
            XCTAssertEqual(mounter.unmountedMountPoints, opensInFinder ? [] : [mountPoint])
            let downloadedURL = try XCTUnwrap(mounter.downloadedURL)
            // Both outcomes remove the temporary DMG, but only success leaves
            // the volume mounted for the user's manual copy.
            XCTAssertFalse(FileManager.default.fileExists(atPath: downloadedURL.path))
        }
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

        let mounter = MockDMGImageMounter(mountPoint: mountPoint)
        let service = AppUpdateDownloadService(
            downloadSession: MockDownloadURLSession(fileURL: dmgURL, statusCode: 200),
            dataSession: MockChecksumURLSession(checksumLine: "\(checksum) update.dmg", statusCode: 200),
            signatureVerifier: MockSignatureVerifier(error: .unsignedBundle),
            dmgMounter: mounter,
            revealInFinder: { _ in
                XCTFail("Signature verification must succeed before revealing the update")
                return true
            }
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
        XCTAssertEqual(mounter.unmountedMountPoints, [mountPoint])
        let downloadedURL = try XCTUnwrap(mounter.downloadedURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloadedURL.path))
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

    func testHdiutilMountReadsLargeStdoutAndStderrWithoutBlocking() throws {
        let largeSize = 1024 * 1024
        let dmgURL = temporaryDirectory.appendingPathComponent("update.dmg")
        let mountPoint = URL(fileURLWithPath: "/Volumes/DockBridge Test", isDirectory: true)

        for (paddingSize, stderrSize, contentKey, content) in [
            (0, 0, "content-hint", "Apple_HFS"),
            (largeSize, 0, "content-hint", "Apple_APFS"),
            (0, largeSize, "content", "Apple_HFS"),
            (largeSize, largeSize, "content-hint", "Apple_APFS"),
        ] {
            let output = try makeAttachOutput(entities: [[
                "mount-point": mountPoint.path,
                contentKey: content,
            ]], paddingSize: paddingSize)
            let (mounter, directory) = try makeHdiutilFixture(
                stdout: output,
                stderr: Data(repeating: 0x78, count: stderrSize)
            )
            defer { assertHdiutilDidNotTimeOut(in: directory) }

            XCTAssertEqual(try mounter.mount(dmgURL: dmgURL), mountPoint)
            let calls = try String(contentsOf: directory.appendingPathComponent("calls"), encoding: .utf8)
            XCTAssertEqual(calls, "attach -nobrowse -plist \(dmgURL.path)\n")
        }
    }

    func testHdiutilMountRejectsNonzeroExitAfterLargeOutput() throws {
        let output = try makeAttachOutput(entities: [[
            "mount-point": "/Volumes/DockBridge Test",
            "content": "Apple_HFS",
        ]], paddingSize: 1024 * 1024)
        let (mounter, directory) = try makeHdiutilFixture(
            stdout: output,
            stderr: Data(repeating: 0x78, count: 1024 * 1024),
            attachStatus: 1
        )
        defer { assertHdiutilDidNotTimeOut(in: directory) }

        XCTAssertThrowsError(try mounter.mount(dmgURL: temporaryDirectory.appendingPathComponent("update.dmg"))) {
            XCTAssertEqual($0 as? AppUpdateDownloadError, .mountFailed)
        }
    }

    func testHdiutilMountRejectsMalformedPlist() throws {
        let (mounter, directory) = try makeHdiutilFixture(stdout: Data("not a plist".utf8))
        defer { assertHdiutilDidNotTimeOut(in: directory) }

        XCTAssertThrowsError(try mounter.mount(dmgURL: temporaryDirectory.appendingPathComponent("update.dmg"))) {
            XCTAssertEqual($0 as? AppUpdateDownloadError, .mountFailed)
        }
    }

    func testHdiutilMountDetachesUnusableVolumeWithLargeOutput() throws {
        let output = try makeAttachOutput(entities: [["dev-entry": "/dev/disk99"]], paddingSize: 1024 * 1024)
        let (mounter, directory) = try makeHdiutilFixture(
            stdout: output,
            stderr: Data(repeating: 0x78, count: 1024 * 1024)
        )
        defer { assertHdiutilDidNotTimeOut(in: directory) }
        let dmgURL = temporaryDirectory.appendingPathComponent("update.dmg")

        XCTAssertThrowsError(try mounter.mount(dmgURL: dmgURL)) {
            XCTAssertEqual($0 as? AppUpdateDownloadError, .mountFailed)
        }
        let calls = try String(contentsOf: directory.appendingPathComponent("calls"), encoding: .utf8)
        XCTAssertEqual(calls, "attach -nobrowse -plist \(dmgURL.path)\ndetach /dev/disk99 -quiet\n")
    }

    func testHdiutilUnmountHandlesLargeOutputAndPreservesExitStatus() throws {
        for status in [0, 1] {
            let (mounter, directory) = try makeHdiutilFixture(
                stdout: Data(repeating: 0x78, count: 1024 * 1024),
                stderr: Data(repeating: 0x79, count: 1024 * 1024),
                detachStatus: status
            )
            defer { assertHdiutilDidNotTimeOut(in: directory) }
            let mountPoint = URL(fileURLWithPath: "/Volumes/DockBridge Test", isDirectory: true)

            if status == 0 {
                XCTAssertNoThrow(try mounter.unmount(mountPoint: mountPoint))
            } else {
                XCTAssertThrowsError(try mounter.unmount(mountPoint: mountPoint)) {
                    XCTAssertEqual($0 as? AppUpdateDownloadError, .unmountFailed)
                }
            }
        }
    }

    private func makeAttachOutput(entities: [[String: String]], paddingSize: Int = 0) throws -> Data {
        let plist: [String: Any] = [
            "padding": String(repeating: "x", count: paddingSize),
            "system-entities": entities,
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    private func makeHdiutilFixture(
        stdout: Data,
        stderr: Data = Data(),
        attachStatus: Int = 0,
        detachStatus: Int = 0
    ) throws -> (HdiutilDMGImageMounter, URL) {
        let directory = temporaryDirectory.appendingPathComponent("hdiutil fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try stdout.write(to: directory.appendingPathComponent("stdout"))
        try stderr.write(to: directory.appendingPathComponent("stderr"))
        let executableURL = directory.appendingPathComponent("hdiutil")
        // printf is a shell builtin, so the watchdog can kill the writer itself
        // if pipe draining regresses. It has no inherited output pipe handles.
        let script = """
        #!/bin/sh
        set -eu
        directory=${0%/*}
        parent_pid=$$
        (
            /bin/sleep 10
            : > "$directory/timed-out"
            kill -KILL "$parent_pid"
        ) </dev/null >/dev/null 2>&1 &
        watchdog_pid=$!
        trap 'kill "$watchdog_pid" 2>/dev/null || true' EXIT
        printf '%s\\n' "$*" >> "$directory/calls"
        case "$1" in
            attach) status=\(attachStatus) ;;
            detach) status=\(detachStatus) ;;
            *) exit 99 ;;
        esac
        stdout=$(/bin/cat "$directory/stdout")
        stderr=$(/bin/cat "$directory/stderr")
        printf '%s' "$stderr" >&2
        printf '%s' "$stdout"
        exit "$status"
        """
        try Data(script.utf8).write(to: executableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executableURL.path)
        return (HdiutilDMGImageMounter(executableURL: executableURL), directory)
    }

    private func assertHdiutilDidNotTimeOut(in directory: URL, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("timed-out").path),
            "hdiutil fixture blocked until the watchdog killed it",
            file: file,
            line: line
        )
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
