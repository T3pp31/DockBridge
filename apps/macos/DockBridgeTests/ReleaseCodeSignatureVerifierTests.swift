import CryptoKit
import Darwin
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
            ),
            checkValidity: { _, _, _ in
                XCTFail("Signature and notarization checks must be skipped when not required")
                return errSecCSInternalError
            },
            copySigningInformation: { _ in
                XCTFail("Signing metadata must not be requested when verification is disabled")
                return (errSecCSInternalError, nil)
            }
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
            var info: [String: Any] = [:]
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
        ]

        XCTAssertNoThrow(try verifier.verifySigningInformation(info))
    }

    func testNotarizationOnlyPolicyStillRejectsMissingNotarizationForExpectedTeam() throws {
        let bundleURL = try makeAdHocSignedTestBundle()
        let verifier = makeNotarizationVerifier(result: errSecCSReqFailed)
        XCTAssertThrowsError(try verifier.verifyAppBundle(at: bundleURL)) { error in
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

    func testVerifyAppBundleAcceptsSuccessfulNotarizationRequirementWithoutSigningInfoDate() throws {
        let bundleURL = try makeAdHocSignedTestBundle()
        let verifier = makeNotarizationVerifier(result: errSecSuccess)

        XCTAssertNoThrow(try verifier.verifyAppBundle(at: bundleURL))
    }

    func testVerifyAppBundleRejectsFailedNotarizationRequirement() throws {
        let bundleURL = try makeAdHocSignedTestBundle()
        for status in [errSecCSReqFailed, errSecCSInternalError] {
            let verifier = makeNotarizationVerifier(result: status)

            XCTAssertThrowsError(try verifier.verifyAppBundle(at: bundleURL)) { error in
                XCTAssertEqual(error as? ReleaseCodeSignatureVerifierError, .notarizationMissing)
            }
        }
    }

    func testVerifyAppBundleRejectsRealAdHocSignatureWithoutNotarization() throws {
        let bundleURL = try makeAdHocSignedTestBundle()
        let verifier = ReleaseCodeSignatureVerifier(
            policy: ReleaseVerificationPolicy(
                expectedBundleIdentifier: "com.dockbridge.app",
                expectedTeamIdentifier: "TEAMID1234",
                signingCertificateFingerprintSHA256: "",
                requireSignedUpdates: false,
                requireNotarizedUpdates: true
            ),
            copySigningInformation: { _ in
                // Metadata seam only: the validity and notarized requirement calls remain real.
                (errSecSuccess, [kSecCodeInfoTeamIdentifier as String: "TEAMID1234"] as CFDictionary)
            }
        )

        XCTAssertThrowsError(try verifier.verifyAppBundle(at: bundleURL)) { error in
            XCTAssertEqual(error as? ReleaseCodeSignatureVerifierError, .notarizationMissing)
        }
    }

    func testVerifyAppBundleStillRequiresDeveloperIDBeforeNotarization() throws {
        let bundleURL = try makeAdHocSignedTestBundle()
        let verifier = ReleaseCodeSignatureVerifier(
            policy: ReleaseVerificationPolicy(
                expectedBundleIdentifier: "com.dockbridge.app",
                expectedTeamIdentifier: "TEAMID1234",
                signingCertificateFingerprintSHA256: "abc123",
                requireSignedUpdates: true,
                requireNotarizedUpdates: true
            ),
            checkValidity: { code, flags, requirement in
                XCTAssertNil(requirement, "Developer ID must be checked before notarization")
                return SecStaticCodeCheckValidity(code, flags, requirement)
            }
        )

        XCTAssertThrowsError(try verifier.verifyAppBundle(at: bundleURL)) { error in
            XCTAssertEqual(error as? ReleaseCodeSignatureVerifierError, .missingDeveloperIDSignature)
        }
    }

    private func makeNotarizationVerifier(result: OSStatus) -> ReleaseCodeSignatureVerifier {
        ReleaseCodeSignatureVerifier(
            policy: ReleaseVerificationPolicy(
                expectedBundleIdentifier: "com.dockbridge.app",
                expectedTeamIdentifier: "TEAMID1234",
                signingCertificateFingerprintSHA256: "",
                requireSignedUpdates: false,
                requireNotarizedUpdates: true
            ),
            checkValidity: { code, flags, requirement in
                XCTAssertEqual(flags, ReleaseCodeSignatureVerifier.validityCheckFlags)
                guard let requirement else {
                    return SecStaticCodeCheckValidity(code, flags, nil)
                }

                var expression: CFString?
                XCTAssertEqual(SecRequirementCopyString(requirement, [], &expression), errSecSuccess)
                XCTAssertEqual(expression as String?, "notarized")
                XCTAssertEqual(
                    flags.rawValue,
                    ReleaseCodeSignatureVerifier.validityCheckFlags.rawValue
                )
                return result
            },
            copySigningInformation: { _ in
                // Team metadata is tested separately; this seam reaches the notarization check
                // without a Developer ID identity or a network-dependent signed fixture.
                (errSecSuccess, [kSecCodeInfoTeamIdentifier as String: "TEAMID1234"] as CFDictionary)
            }
        )
    }

    private func makeAdHocSignedTestBundle() throws -> URL {
        let bundleURL = try makeTestBundle(bundleIdentifier: "com.dockbridge.app")
        // An ad-hoc signature needs no signing identity, credentials or network.
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"),
            to: bundleURL.appendingPathComponent("Contents/MacOS/DockBridge")
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", bundleURL.path]
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        let diagnostics = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: diagnostics, as: UTF8.self))
        return bundleURL
    }

    func testNotarizationOnlyPolicyRejectsRealAdHocSignerWithoutExpectedTeam() throws {
        let bundleURL = try makeAdHocSignedTestBundle()
        XCTAssertThrowsError(try makeNotarizationOnlyVerifier().verifyAppBundle(at: bundleURL)) { error in
            XCTAssertEqual(
                error as? ReleaseCodeSignatureVerifierError,
                .teamIdentifierMismatch(expected: "TEAMID1234", actual: "")
            )
        }
    }

    func testFailedValidityCheckStopsBeforeMetadataOrNotarization() throws {
        let bundleURL = try makeAdHocSignedTestBundle()
        // The same fail-closed behavior applies to certificate expiry, revocation,
        // malformed signatures, and unexpected Security errors.
        for status in [errSecCertificateExpired, errSecCertificateRevoked, errSecCSInternalError] {
            let verifier = ReleaseCodeSignatureVerifier(
                policy: notarizationOnlyPolicy,
                checkValidity: { _, flags, requirement in
                    XCTAssertEqual(flags, ReleaseCodeSignatureVerifier.validityCheckFlags)
                    XCTAssertNil(requirement)
                    return status
                },
                copySigningInformation: { _ in
                    XCTFail("Invalid code must not reach metadata or notarization checks")
                    return (errSecSuccess, [:] as CFDictionary)
                }
            )
            XCTAssertThrowsError(try verifier.verifyAppBundle(at: bundleURL)) { error in
                XCTAssertEqual(error as? ReleaseCodeSignatureVerifierError, .unsignedBundle)
            }
        }
    }

    func testMissingOrFailedSigningInformationFailsClosed() throws {
        let bundleURL = try makeAdHocSignedTestBundle()
        for status in [errSecSuccess, errSecCSInternalError] {
            let verifier = ReleaseCodeSignatureVerifier(
                policy: notarizationOnlyPolicy,
                checkValidity: { code, flags, requirement in
                    XCTAssertNil(requirement, "Missing metadata must stop before notarization")
                    return SecStaticCodeCheckValidity(code, flags, requirement)
                },
                copySigningInformation: { _ in
                    // A success without a dictionary and an error with otherwise plausible
                    // metadata must both fail closed.
                    let info: CFDictionary? = status == errSecSuccess ? nil :
                        [kSecCodeInfoTeamIdentifier as String: "TEAMID1234"] as CFDictionary
                    return (status, info)
                }
            )
            XCTAssertThrowsError(try verifier.verifyAppBundle(at: bundleURL)) { error in
                XCTAssertEqual(error as? ReleaseCodeSignatureVerifierError, .unsignedBundle)
            }
        }
    }

    func testUnexpectedTeamStopsBeforeNotarization() throws {
        let bundleURL = try makeAdHocSignedTestBundle()
        let verifier = ReleaseCodeSignatureVerifier(
            policy: notarizationOnlyPolicy,
            checkValidity: { code, flags, requirement in
                XCTAssertNil(requirement, "A mismatched team must stop before notarization")
                return SecStaticCodeCheckValidity(code, flags, requirement)
            },
            copySigningInformation: { _ in
                (errSecSuccess, [kSecCodeInfoTeamIdentifier as String: "OTHERTEAM1"] as CFDictionary)
            }
        )
        XCTAssertThrowsError(try verifier.verifyAppBundle(at: bundleURL)) { error in
            XCTAssertEqual(
                error as? ReleaseCodeSignatureVerifierError,
                .teamIdentifierMismatch(expected: "TEAMID1234", actual: "OTHERTEAM1")
            )
        }
    }

    func testSignedPolicyChecksDeveloperIDTeamAndCertificatePin() throws {
        // These self-signed public certificates test metadata interpretation only.
        // They are not trusted Developer ID chains and never bypass live validity checking.
        let certificateData = try XCTUnwrap(Data(base64Encoded: Self.developerCertificateDER))
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, certificateData as CFData))
        let otherData = try XCTUnwrap(Data(base64Encoded: Self.otherCertificateDER))
        let otherCertificate = try XCTUnwrap(SecCertificateCreateWithData(nil, otherData as CFData))
        let fingerprint = SHA256.hash(data: certificateData).map { String(format: "%02x", $0) }.joined()
        func verifier(pin: String) -> ReleaseCodeSignatureVerifier {
            ReleaseCodeSignatureVerifier(policy: ReleaseVerificationPolicy(
                expectedBundleIdentifier: "com.dockbridge.app",
                expectedTeamIdentifier: "TEAMID1234",
                signingCertificateFingerprintSHA256: pin,
                requireSignedUpdates: true,
                requireNotarizedUpdates: false
            ))
        }
        let matching: NSDictionary = [
            kSecCodeInfoTeamIdentifier as String: "TEAMID1234",
            kSecCodeInfoCertificates as String: [certificate],
        ]
        XCTAssertNoThrow(try verifier(pin: fingerprint.uppercased()).verifySigningInformation(matching))
        XCTAssertThrowsError(try verifier(pin: "incorrect").verifySigningInformation(matching)) { error in
            XCTAssertEqual(
                error as? ReleaseCodeSignatureVerifierError,
                .certificateFingerprintMismatch(expected: "incorrect", actual: fingerprint)
            )
        }
        let wrongTeam: NSDictionary = [
            kSecCodeInfoTeamIdentifier as String: "OTHERTEAM1",
            kSecCodeInfoCertificates as String: [certificate],
        ]
        XCTAssertThrowsError(try verifier(pin: fingerprint).verifySigningInformation(wrongTeam)) { error in
            XCTAssertEqual(
                error as? ReleaseCodeSignatureVerifierError,
                .teamIdentifierMismatch(expected: "TEAMID1234", actual: "OTHERTEAM1")
            )
        }
        let wrongCertificate: NSDictionary = [
            kSecCodeInfoTeamIdentifier as String: "TEAMID1234",
            kSecCodeInfoCertificates as String: [otherCertificate],
        ]
        XCTAssertThrowsError(try verifier(pin: fingerprint).verifySigningInformation(wrongCertificate)) { error in
            XCTAssertEqual(error as? ReleaseCodeSignatureVerifierError, .missingDeveloperIDSignature)
        }
    }

    func testVerifyAppBundleRejectsFIFOInfoPlistWithoutBlocking() throws {
        let bundleURL = try makeTestBundle(bundleIdentifier: "com.dockbridge.app")
        let infoURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.removeItem(at: infoURL)
        XCTAssertEqual(mkfifo(infoURL.path, mode_t(0o600)), 0)
        let completed = expectation(description: "FIFO metadata rejected without waiting for a writer")
        let verifier = unsignedPolicyVerifier
        defer {
            // Release a blocked reader if O_NONBLOCK regresses, after the bounded
            // expectation has already recorded failure. Never block this cleanup.
            let writer = open(infoURL.path, O_WRONLY | O_NONBLOCK)
            if writer >= 0 { close(writer) }
        }
        DispatchQueue.global().async {
            do {
                try verifier.verifyAppBundle(at: bundleURL)
                XCTFail("Expected FIFO Info.plist to be rejected")
            } catch {
                XCTAssertEqual(error as? ReleaseCodeSignatureVerifierError, .unsignedBundle)
            }
            completed.fulfill()
        }
        wait(for: [completed], timeout: 5)
    }

    private var notarizationOnlyPolicy: ReleaseVerificationPolicy {
        ReleaseVerificationPolicy(
            expectedBundleIdentifier: "com.dockbridge.app",
            expectedTeamIdentifier: "TEAMID1234",
            signingCertificateFingerprintSHA256: "",
            requireSignedUpdates: false,
            requireNotarizedUpdates: true
        )
    }

    // Public DER-only test fixtures. No private keys or live signing identities are stored.
    private static let developerCertificateDER = "MIIBzTCCAXOgAwIBAgIUEimKc7+3xV5rvfmCVNTH8rdR1egwCgYIKoZIzj0EAwIwPDE6MDgGA1UEAwwxRGV2ZWxvcGVyIElEIEFwcGxpY2F0aW9uOiBOb250cnVzdGVkIFRlc3QgRml4dHVyZTAeFw0yNjExMTEwNTMyMzJaFw0yNjExMTIwNTMyMzJaMDwxOjA4BgNVBAMMMURldmVsb3BlciBJRCBBcHBsaWNhdGlvbjogTm9udHJ1c3RlZCBUZXN0IEZpeHR1cmUwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAASaCBXBzv5q1nzEYyZeFAMyLfQCoNpgOhnJYkAnx0m+C7EN35AdHcWJhibvtEvf1IoNnga9UO2f1rSGRZ8d2zkso1MwUTAdBgNVHQ4EFgQUOVn8lN2bJxhn7r5nNFXUbSP1KZowHwYDVR0jBBgwFoAUOVn8lN2bJxhn7r5nNFXUbSP1KZowDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNIADBFAiEAuogkeJsZHsym83tVrnWkSffD30APzK2Wf0NZvxQ/vOcCIFer6X9YSh5ric1XcDumEKyFWZsy4K33NSTue+w5ZP6v"
    private static let otherCertificateDER = "MIIBmDCCAT2gAwIBAgIUHnnO+VEjl/zxdsJCHHh3fDuxYcAwCgYIKoZIzj0EAwIwITEfMB0GA1UEAwwWVW5yZWxhdGVkIFRlc3QgRml4dHVyZTAeFw0yNjExMTEwNTMyMzJaFw0yNjExMTIwNTMyMzJaMCExHzAdBgNVBAMMFlVucmVsYXRlZCBUZXN0IEZpeHR1cmUwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAATrhwpyoCqtiKaKtofa2pvfnXukQqRK/78sE0aaPdMi1ZZc9ES5thxRx+bnWq3jrIMZQSfAbYeYwu4trXClLV0Fo1MwUTAdBgNVHQ4EFgQUFfUIDWrvBXWlq0uB4T18B4YB+OcwHwYDVR0jBBgwFoAUFfUIDWrvBXWlq0uB4T18B4YB+OcwDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNJADBGAiEAyvtHtfGfG7AFj6Df2HX65aCfGNh9Rup8+cbXbNl2+2QCIQDByxTjIZbcdNZfWa0QwPX1ZrJoIt6Fc5w+zsw1jQfAWQ=="

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
