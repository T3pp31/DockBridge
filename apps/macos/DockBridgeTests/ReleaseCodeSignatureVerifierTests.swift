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
                expectedTeamIdentifier: "",
                signingCertificateFingerprintSHA256: "",
                requireSignedUpdates: false,
                requireNotarizedUpdates: true
            )
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
                expectedTeamIdentifier: "",
                signingCertificateFingerprintSHA256: "",
                requireSignedUpdates: false,
                requireNotarizedUpdates: true
            ),
            checkValidity: { code, flags, requirement in
                guard let requirement else {
                    return SecStaticCodeCheckValidity(code, flags, nil)
                }

                var expression: CFString?
                XCTAssertEqual(SecRequirementCopyString(requirement, [], &expression), errSecSuccess)
                XCTAssertEqual(expression as String?, "notarized")
                XCTAssertEqual(
                    flags.rawValue,
                    kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode
                )
                return result
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
