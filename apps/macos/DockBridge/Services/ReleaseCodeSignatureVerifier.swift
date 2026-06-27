import CryptoKit
import Foundation
import Security

struct ReleaseVerificationPolicy: Equatable, Sendable {
    let expectedBundleIdentifier: String
    let expectedTeamIdentifier: String
    let signingCertificateFingerprintSHA256: String
    let requireSignedUpdates: Bool
    let requireNotarizedUpdates: Bool

    static var current: ReleaseVerificationPolicy {
        ReleaseVerificationPolicy(
            expectedBundleIdentifier: AppUpdateConfig.bundleIdentifier,
            expectedTeamIdentifier: AppUpdateConfig.expectedTeamIdentifier,
            signingCertificateFingerprintSHA256: AppUpdateConfig.signingCertificateFingerprintSHA256,
            requireSignedUpdates: AppUpdateConfig.requireSignedUpdates,
            requireNotarizedUpdates: AppUpdateConfig.requireNotarizedUpdates
        )
    }
}

enum ReleaseCodeSignatureVerifierError: Error, Equatable {
    case unsignedBundle
    case bundleIdentifierMismatch(expected: String, actual: String)
    case missingDeveloperIDSignature
    case teamIdentifierMismatch(expected: String, actual: String)
    case certificateFingerprintMismatch(expected: String, actual: String)
    case notarizationMissing
}

protocol AppBundleSignatureVerifying: Sendable {
    func verifyAppBundle(at url: URL) throws
}

struct ReleaseCodeSignatureVerifier: AppBundleSignatureVerifying {
    private let policy: ReleaseVerificationPolicy
    private let fileManager: FileManager

    init(
        policy: ReleaseVerificationPolicy = .current,
        fileManager: FileManager = .default
    ) {
        self.policy = policy
        self.fileManager = fileManager
    }

    func verifyAppBundle(at url: URL) throws {
        let bundleIdentifier = try readBundleIdentifier(from: url)
        guard bundleIdentifier == policy.expectedBundleIdentifier else {
            throw ReleaseCodeSignatureVerifierError.bundleIdentifierMismatch(
                expected: policy.expectedBundleIdentifier,
                actual: bundleIdentifier
            )
        }

        guard policy.requireSignedUpdates || policy.requireNotarizedUpdates else {
            return
        }

        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            throw ReleaseCodeSignatureVerifierError.unsignedBundle
        }

        let validityStatus = SecStaticCodeCheckValidity(staticCode, [], nil)
        guard validityStatus == errSecSuccess else {
            throw ReleaseCodeSignatureVerifierError.unsignedBundle
        }

        var signingInfo: CFDictionary?
        let copyStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInfo
        )
        guard copyStatus == errSecSuccess, let signingInfo else {
            throw ReleaseCodeSignatureVerifierError.unsignedBundle
        }

        let info = signingInfo as NSDictionary

        if policy.requireSignedUpdates {
            try verifyDeveloperIDSignature(signingInfo: info)
            try verifyTeamIdentifier(signingInfo: info)
            try verifyCertificateFingerprint(signingInfo: info)
        }

        if policy.requireNotarizedUpdates {
            guard info["NotarizationDate"] != nil else {
                throw ReleaseCodeSignatureVerifierError.notarizationMissing
            }
        }
    }

    private func readBundleIdentifier(from bundleURL: URL) throws -> String {
        let infoPlistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard fileManager.fileExists(atPath: infoPlistURL.path) else {
            throw ReleaseCodeSignatureVerifierError.unsignedBundle
        }

        let data = try Data(contentsOf: infoPlistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dictionary = plist as? [String: Any],
              let bundleIdentifier = dictionary["CFBundleIdentifier"] as? String else {
            throw ReleaseCodeSignatureVerifierError.unsignedBundle
        }
        return bundleIdentifier
    }

    private func verifyDeveloperIDSignature(signingInfo: NSDictionary) throws {
        guard let certificates = signingInfo[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leafCertificate = certificates.first else {
            throw ReleaseCodeSignatureVerifierError.missingDeveloperIDSignature
        }

        guard let summary = SecCertificateCopySubjectSummary(leafCertificate) as String?,
              summary.hasPrefix("Developer ID Application:") else {
            throw ReleaseCodeSignatureVerifierError.missingDeveloperIDSignature
        }
    }

    private func verifyTeamIdentifier(signingInfo: NSDictionary) throws {
        guard !policy.expectedTeamIdentifier.isEmpty else { return }

        let teamIdentifier = signingInfo[kSecCodeInfoTeamIdentifier as String] as? String ?? ""
        guard teamIdentifier == policy.expectedTeamIdentifier else {
            throw ReleaseCodeSignatureVerifierError.teamIdentifierMismatch(
                expected: policy.expectedTeamIdentifier,
                actual: teamIdentifier
            )
        }
    }

    private func verifyCertificateFingerprint(signingInfo: NSDictionary) throws {
        guard !policy.signingCertificateFingerprintSHA256.isEmpty else { return }

        guard let certificates = signingInfo[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leafCertificate = certificates.first,
              let certificateData = SecCertificateCopyData(leafCertificate) as Data? else {
            throw ReleaseCodeSignatureVerifierError.missingDeveloperIDSignature
        }

        let digest = SHA256.hash(data: certificateData)
        let fingerprint = digest.map { String(format: "%02x", $0) }.joined()
        let expected = policy.signingCertificateFingerprintSHA256.lowercased()
        guard fingerprint == expected else {
            throw ReleaseCodeSignatureVerifierError.certificateFingerprintMismatch(
                expected: expected,
                actual: fingerprint
            )
        }
    }
}
