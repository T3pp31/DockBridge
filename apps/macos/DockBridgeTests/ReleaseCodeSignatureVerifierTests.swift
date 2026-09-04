import XCTest
@testable import DockBridge

final class ReleaseCodeSignatureVerifierTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReleaseCodeSignatureVerifierTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        try super.tearDownWithError()
    }

    func testVerifyAppBundleAcceptsMatchingBundleIdentifierWhenSignatureNotRequired() throws {
        let bundleURL = try makeTestBundle(bundleIdentifier: "com.dockbridge.app")
        let verifier = ReleaseCodeSignatureVerifier(
            policy: ReleaseVerificationPolicy(
                expectedBundleIdentifier: "com.dockbridge.app",
                expectedTeamIdentifier: "",
                signingCertificateFingerprintSHA256: "",
                requireSignedUpdates: false,
                requireNotarizedUpdates: false
            )
        )

        XCTAssertNoThrow(try verifier.verifyAppBundle(at: bundleURL))
    }

    func testVerifyAppBundleRejectsBundleIdentifierMismatch() throws {
        let bundleURL = try makeTestBundle(bundleIdentifier: "com.evil.app")
        let verifier = ReleaseCodeSignatureVerifier(
            policy: ReleaseVerificationPolicy(
                expectedBundleIdentifier: "com.dockbridge.app",
                expectedTeamIdentifier: "",
                signingCertificateFingerprintSHA256: "",
                requireSignedUpdates: false,
                requireNotarizedUpdates: false
            )
        )

        XCTAssertThrowsError(try verifier.verifyAppBundle(at: bundleURL)) { error in
            XCTAssertEqual(
                error as? ReleaseCodeSignatureVerifierError,
                .bundleIdentifierMismatch(expected: "com.dockbridge.app", actual: "com.evil.app")
            )
        }
    }

    func testVerifyAppBundleRejectsUnsignedBundleWhenSignatureRequired() throws {
        let bundleURL = try makeTestBundle(bundleIdentifier: "com.dockbridge.app")
        let verifier = ReleaseCodeSignatureVerifier(
            policy: ReleaseVerificationPolicy(
                expectedBundleIdentifier: "com.dockbridge.app",
                expectedTeamIdentifier: "TEAMID1234",
                signingCertificateFingerprintSHA256: "abc123",
                requireSignedUpdates: true,
                requireNotarizedUpdates: false
            )
        )

        XCTAssertThrowsError(try verifier.verifyAppBundle(at: bundleURL)) { error in
            XCTAssertEqual(error as? ReleaseCodeSignatureVerifierError, .unsignedBundle)
        }
    }

    func testVerifyAppBundleRejectsMisconfiguredPolicyWhenSignedUpdatesRequiredWithoutTeamOrFingerprint() throws {
        let bundleURL = try makeTestBundle(bundleIdentifier: "com.dockbridge.app")
        let cases: [(team: String, fingerprint: String)] = [
            ("", ""),
            ("TEAMID1234", ""),
            ("", "abc123"),
        ]

        for policyValues in cases {
            let verifier = ReleaseCodeSignatureVerifier(
                policy: ReleaseVerificationPolicy(
                    expectedBundleIdentifier: "com.dockbridge.app",
                    expectedTeamIdentifier: policyValues.team,
                    signingCertificateFingerprintSHA256: policyValues.fingerprint,
                    requireSignedUpdates: true,
                    requireNotarizedUpdates: false
                )
            )

            XCTAssertThrowsError(try verifier.verifyAppBundle(at: bundleURL)) { error in
                XCTAssertEqual(
                    error as? ReleaseCodeSignatureVerifierError,
                    .misconfiguredSignaturePolicy,
                    "team=\(policyValues.team.debugDescription) fingerprint=\(policyValues.fingerprint.debugDescription)"
                )
            }
        }
    }

    func testVerifyAppBundleRejectsMissingNotarizationWhenRequired() throws {
        let bundleURL = try makeTestBundle(bundleIdentifier: "com.dockbridge.app")
        let verifier = ReleaseCodeSignatureVerifier(
            policy: ReleaseVerificationPolicy(
                expectedBundleIdentifier: "com.dockbridge.app",
                expectedTeamIdentifier: "",
                signingCertificateFingerprintSHA256: "",
                requireSignedUpdates: false,
                requireNotarizedUpdates: true
            )
        )

        XCTAssertThrowsError(try verifier.verifyAppBundle(at: bundleURL)) { error in
            XCTAssertEqual(error as? ReleaseCodeSignatureVerifierError, .unsignedBundle)
        }
    }

    private func makeTestBundle(bundleIdentifier: String) throws -> URL {
        let bundleURL = temporaryDirectory.appendingPathComponent("DockBridge.app", isDirectory: true)
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
