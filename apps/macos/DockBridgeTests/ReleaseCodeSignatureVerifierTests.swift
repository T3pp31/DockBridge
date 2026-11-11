import Security
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

    func testValidityCheckFlagsRequireCertificateExpirationAndRevocationChecks() {
        let flags = ReleaseCodeSignatureVerifier.validityCheckFlags

        XCTAssertTrue(flags.contains(.considerExpiration))
        XCTAssertTrue(flags.contains(.enforceRevocationChecks))
    }

    func testValidityCheckFlagsPreserveStrictValidationOfAllArchitecturesAndNestedCode() {
        let flags = ReleaseCodeSignatureVerifier.validityCheckFlags.rawValue

        XCTAssertEqual(flags & kSecCSCheckAllArchitectures, kSecCSCheckAllArchitectures)
        XCTAssertEqual(flags & kSecCSStrictValidate, kSecCSStrictValidate)
        XCTAssertEqual(flags & kSecCSCheckNestedCode, kSecCSCheckNestedCode)
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

    func testVerifyAppBundleRejectsUnsignedBundleWhenOnlyNotarizationRequired() throws {
        let bundleURL = try makeTestBundle(bundleIdentifier: "com.dockbridge.app")
        let verifier = makeNotarizationOnlyVerifier()

        XCTAssertThrowsError(try verifier.verifyAppBundle(at: bundleURL)) { error in
            XCTAssertEqual(error as? ReleaseCodeSignatureVerifierError, .unsignedBundle)
        }
    }

    func testVerifyAppBundleRejectsNotarizationOnlyPolicyWithoutExpectedTeam() throws {
        let bundleURL = try makeTestBundle(bundleIdentifier: "com.dockbridge.app")
        for fingerprint in ["", "abc123"] {
            let verifier = ReleaseCodeSignatureVerifier(
                policy: ReleaseVerificationPolicy(
                    expectedBundleIdentifier: "com.dockbridge.app",
                    expectedTeamIdentifier: "",
                    signingCertificateFingerprintSHA256: fingerprint,
                    requireSignedUpdates: false,
                    requireNotarizedUpdates: true
                )
            )

            XCTAssertThrowsError(try verifier.verifyAppBundle(at: bundleURL)) { error in
                XCTAssertEqual(error as? ReleaseCodeSignatureVerifierError, .misconfiguredSignaturePolicy)
            }
        }
    }

    func testNotarizationOnlyPolicyRejectsUnexpectedOrMissingSignerTeam() {
        let verifier = makeNotarizationOnlyVerifier()
        let cases: [(team: String?, actual: String)] = [
            ("OTHERTEAM1", "OTHERTEAM1"),
            ("", ""),
            (nil, ""),
        ]

        for values in cases {
            var info: [String: Any] = ["NotarizationDate": Date()]
            if let team = values.team {
                info[kSecCodeInfoTeamIdentifier as String] = team
            }

            XCTAssertThrowsError(try verifier.verifySigningInformation(info as NSDictionary)) { error in
                XCTAssertEqual(
                    error as? ReleaseCodeSignatureVerifierError,
                    .teamIdentifierMismatch(expected: "TEAMID1234", actual: values.actual)
                )
            }
        }
    }

    func testNotarizationOnlyPolicyAcceptsExpectedTeamWithoutCertificatePin() {
        let verifier = makeNotarizationOnlyVerifier()
        let info: NSDictionary = [
            kSecCodeInfoTeamIdentifier as String: "TEAMID1234",
            "NotarizationDate": Date(),
        ]

        XCTAssertNoThrow(try verifier.verifySigningInformation(info))
    }

    func testNotarizationOnlyPolicyStillRejectsMissingNotarizationForExpectedTeam() {
        let verifier = makeNotarizationOnlyVerifier()
        let info: NSDictionary = [kSecCodeInfoTeamIdentifier as String: "TEAMID1234"]

        XCTAssertThrowsError(try verifier.verifySigningInformation(info)) { error in
            XCTAssertEqual(error as? ReleaseCodeSignatureVerifierError, .notarizationMissing)
        }
    }

    func testSignedUpdatePoliciesStillRequireDeveloperIDSignature() {
        for requireNotarizedUpdates in [false, true] {
            let verifier = ReleaseCodeSignatureVerifier(
                policy: ReleaseVerificationPolicy(
                    expectedBundleIdentifier: "com.dockbridge.app",
                    expectedTeamIdentifier: "TEAMID1234",
                    signingCertificateFingerprintSHA256: "abc123",
                    requireSignedUpdates: true,
                    requireNotarizedUpdates: requireNotarizedUpdates
                )
            )
            let info: NSDictionary = [
                kSecCodeInfoTeamIdentifier as String: "TEAMID1234",
                "NotarizationDate": Date(),
            ]

            XCTAssertThrowsError(try verifier.verifySigningInformation(info)) { error in
                XCTAssertEqual(error as? ReleaseCodeSignatureVerifierError, .missingDeveloperIDSignature)
            }
        }
    }

    private func makeNotarizationOnlyVerifier() -> ReleaseCodeSignatureVerifier {
        ReleaseCodeSignatureVerifier(
            policy: ReleaseVerificationPolicy(
                expectedBundleIdentifier: "com.dockbridge.app",
                expectedTeamIdentifier: "TEAMID1234",
                signingCertificateFingerprintSHA256: "",
                requireSignedUpdates: false,
                requireNotarizedUpdates: true
            )
        )
    }

    func testVerifyAppBundleAcceptsBinaryInfoPlistWhenSignatureNotRequired() throws {
        let bundleURL = try makeTestBundle(bundleIdentifier: "com.dockbridge.app", format: .binary)

        XCTAssertNoThrow(try unsignedPolicyVerifier.verifyAppBundle(at: bundleURL))
    }

    func testVerifyAppBundleAcceptsInfoPlistAtSizeLimit() throws {
        let bundleURL = try makeTestBundle(bundleIdentifier: "com.dockbridge.app")
        try padInfoPlist(in: bundleURL, toSize: AppUpdateConfig.maxInfoPlistSizeBytes)

        XCTAssertNoThrow(try unsignedPolicyVerifier.verifyAppBundle(at: bundleURL))
    }

    func testVerifyAppBundleRejectsInfoPlistOneByteOverSizeLimit() throws {
        let bundleURL = try makeTestBundle(bundleIdentifier: "com.dockbridge.app")
        // This remains a valid plist with a matching identifier, so a parser
        // error cannot accidentally satisfy the size-limit regression test.
        try padInfoPlist(in: bundleURL, toSize: AppUpdateConfig.maxInfoPlistSizeBytes + 1)

        XCTAssertThrowsError(try unsignedPolicyVerifier.verifyAppBundle(at: bundleURL)) { error in
            XCTAssertEqual(error as? ReleaseCodeSignatureVerifierError, .unsignedBundle)
        }
    }

    func testVerifyAppBundleRejectsSymbolicLinkToValidInfoPlist() throws {
        let bundleURL = try makeTestBundle(bundleIdentifier: "com.dockbridge.app")
        let infoPlistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        let targetURL = temporaryDirectory.appendingPathComponent("valid.plist")
        try FileManager.default.moveItem(at: infoPlistURL, to: targetURL)
        try FileManager.default.createSymbolicLink(at: infoPlistURL, withDestinationURL: targetURL)

        XCTAssertThrowsError(try unsignedPolicyVerifier.verifyAppBundle(at: bundleURL)) { error in
            XCTAssertEqual(error as? ReleaseCodeSignatureVerifierError, .unsignedBundle)
        }
    }

    func testVerifyAppBundleRejectsMissingOrNonRegularInfoPlist() throws {
        let bundleURL = try makeTestBundle(bundleIdentifier: "com.dockbridge.app")
        let infoPlistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.removeItem(at: infoPlistURL)

        XCTAssertThrowsError(try unsignedPolicyVerifier.verifyAppBundle(at: bundleURL)) { error in
            XCTAssertEqual(error as? ReleaseCodeSignatureVerifierError, .unsignedBundle)
        }

        try FileManager.default.createDirectory(at: infoPlistURL, withIntermediateDirectories: false)
        XCTAssertThrowsError(try unsignedPolicyVerifier.verifyAppBundle(at: bundleURL)) { error in
            XCTAssertEqual(error as? ReleaseCodeSignatureVerifierError, .unsignedBundle)
        }
    }

    func testVerifyAppBundleRejectsInvalidInfoPlistWhenSignatureNotRequired() throws {
        let bundleURL = try makeTestBundle(bundleIdentifier: "com.dockbridge.app")
        let infoPlistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        let missingIdentifier = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundlePackageType": "APPL"], format: .xml, options: 0
        )
        for data in [Data(), Data("not a plist".utf8), missingIdentifier] {
            try data.write(to: infoPlistURL)
            XCTAssertThrowsError(try unsignedPolicyVerifier.verifyAppBundle(at: bundleURL))
        }
    }

    func testVerifyAppBundleChecksSignatureBeforeParsingOrComparingBundleIdentifier() throws {
        let bundleURL = try makeTestBundle(bundleIdentifier: "com.evil.app")
        let infoPlistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        let mismatchedPlist = try Data(contentsOf: infoPlistURL)
        for requireSignedUpdates in [true, false] {
            let verifier = ReleaseCodeSignatureVerifier(
                policy: ReleaseVerificationPolicy(
                    expectedBundleIdentifier: "com.dockbridge.app",
                    expectedTeamIdentifier: "TEAMID1234",
                    signingCertificateFingerprintSHA256: "abc123",
                    requireSignedUpdates: requireSignedUpdates,
                    requireNotarizedUpdates: !requireSignedUpdates
                )
            )
            for data in [mismatchedPlist, Data("not a plist".utf8)] {
                try data.write(to: infoPlistURL)
                XCTAssertThrowsError(try verifier.verifyAppBundle(at: bundleURL)) { error in
                    XCTAssertEqual(error as? ReleaseCodeSignatureVerifierError, .unsignedBundle)
                }
            }
        }
    }

    private var unsignedPolicyVerifier: ReleaseCodeSignatureVerifier {
        ReleaseCodeSignatureVerifier(
            policy: ReleaseVerificationPolicy(
                expectedBundleIdentifier: "com.dockbridge.app",
                expectedTeamIdentifier: "",
                signingCertificateFingerprintSHA256: "",
                requireSignedUpdates: false,
                requireNotarizedUpdates: false
            )
        )
    }

    private func padInfoPlist(in bundleURL: URL, toSize size: Int) throws {
        let infoPlistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        var data = try Data(contentsOf: infoPlistURL)
        data.append(Data(repeating: 0x20, count: size - data.count))
        try data.write(to: infoPlistURL)
    }

    private func makeTestBundle(
        bundleIdentifier: String,
        format: PropertyListSerialization.PropertyListFormat = .xml
    ) throws -> URL {
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
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0)
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"))
        return bundleURL
    }
}
