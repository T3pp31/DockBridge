import CryptoKit
import Darwin
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
    /// Signature or notarization verification requires a team ID; signed updates also require a certificate fingerprint.
    case misconfiguredSignaturePolicy
}

protocol AppBundleSignatureVerifying: Sendable {
    func verifyAppBundle(at url: URL) throws
}

struct ReleaseCodeSignatureVerifier: AppBundleSignatureVerifying {
    // Pinning the signing identity does not replace certificate lifetime and revocation checks.
    static let validityCheckFlags = SecCSFlags(
        rawValue: kSecCSCheckAllArchitectures
            | kSecCSStrictValidate
            | kSecCSCheckNestedCode
    ).union([.considerExpiration, .enforceRevocationChecks])

    private let policy: ReleaseVerificationPolicy

    private let checkValidity: @Sendable (SecStaticCode, SecCSFlags, SecRequirement?) -> OSStatus
    private let copySigningInformation: @Sendable (SecStaticCode) -> (OSStatus, CFDictionary?)

    init(
        policy: ReleaseVerificationPolicy = .current,
        checkValidity: @escaping @Sendable (SecStaticCode, SecCSFlags, SecRequirement?) -> OSStatus = {
            SecStaticCodeCheckValidity($0, $1, $2)
        },
        copySigningInformation: @escaping @Sendable (SecStaticCode) -> (OSStatus, CFDictionary?) = { code in
            var information: CFDictionary?
            let status = SecCodeCopySigningInformation(
                code, SecCSFlags(rawValue: kSecCSSigningInformation), &information
            )
            return (status, information)
        }
    ) {
        self.policy = policy
        self.checkValidity = checkValidity
        self.copySigningInformation = copySigningInformation
    }

    func verifyAppBundle(at url: URL) throws {
        let infoPlistURL = url.appendingPathComponent("Contents/Info.plist")
        // Do not follow links or block opening a FIFO. Validate the opened file,
        // not path metadata that could change before the read.
        let fileDescriptor = open(infoPlistURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fileDescriptor >= 0 else {
            throw ReleaseCodeSignatureVerifierError.unsignedBundle
        }
        defer { close(fileDescriptor) }

        var fileStat = stat()
        guard fstat(fileDescriptor, &fileStat) == 0,
              (fileStat.st_mode & S_IFMT) == S_IFREG,
              fileStat.st_size >= 0,
              fileStat.st_size <= AppUpdateConfig.maxInfoPlistSizeBytes else {
            throw ReleaseCodeSignatureVerifierError.unsignedBundle
        }

        // Reject unsafe metadata before Security can consume it, but only parse
        // the bundle identifier after the required signature checks have passed.
        if policy.requireSignedUpdates || policy.requireNotarizedUpdates {
            try verifySignature(at: url)
        }

        let bundleIdentifier = try readBundleIdentifier(from: fileDescriptor)
        guard bundleIdentifier == policy.expectedBundleIdentifier else {
            throw ReleaseCodeSignatureVerifierError.bundleIdentifierMismatch(
                expected: policy.expectedBundleIdentifier,
                actual: bundleIdentifier
            )
        }
    }

    private func verifySignature(at url: URL) throws {
        try validateSignaturePolicy()

        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            url as CFURL,
            [],
            &staticCode
        )
        guard createStatus == errSecSuccess, let staticCode else {
            throw ReleaseCodeSignatureVerifierError.unsignedBundle
        }

        let validityStatus = checkValidity(
            staticCode,
            Self.validityCheckFlags,
            nil
        )
        guard validityStatus == errSecSuccess else {
            throw ReleaseCodeSignatureVerifierError.unsignedBundle
        }

        let (copyStatus, signingInfo) = copySigningInformation(staticCode)
        guard copyStatus == errSecSuccess, let signingInfo else {
            throw ReleaseCodeSignatureVerifierError.unsignedBundle
        }

        try verifySigningInformation(signingInfo as NSDictionary)

        if policy.requireNotarizedUpdates {
            // Only Security's requirement evaluation proves notarization. Signing
            // metadata and timestamps cannot substitute for a notarization ticket.
            var requirement: SecRequirement?
            let requirementStatus = SecRequirementCreateWithString(
                "notarized" as CFString, [], &requirement
            )
            guard requirementStatus == errSecSuccess,
                  let requirement,
                  checkValidity(staticCode, Self.validityCheckFlags, requirement) == errSecSuccess else {
                throw ReleaseCodeSignatureVerifierError.notarizationMissing
            }
        }
    }

    /// Evaluates metadata after static code validity and policy validation have succeeded.
    func verifySigningInformation(_ info: NSDictionary) throws {
        if policy.requireSignedUpdates {
            try verifyDeveloperIDSignature(signingInfo: info)
            try verifyTeamIdentifier(signingInfo: info)
            try verifyCertificateFingerprint(signingInfo: info)
        } else if policy.requireNotarizedUpdates {
            // Notarization alone does not bind an update to the expected vendor.
            try verifyTeamIdentifier(signingInfo: info)
        }
    }

    private func readBundleIdentifier(from fileDescriptor: Int32) throws -> String {
        let sizeLimit = AppUpdateConfig.maxInfoPlistSizeBytes
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            // Read at most one byte beyond the limit to detect files growing
            // after fstat without allocating or reading an unbounded amount.
            let bytesRead = read(fileDescriptor, &buffer, min(buffer.count, sizeLimit - data.count + 1))
            if bytesRead < 0 {
                if errno == EINTR {
                    continue
                }
                throw ReleaseCodeSignatureVerifierError.unsignedBundle
            }
            if bytesRead == 0 {
                break
            }
            guard data.count + bytesRead <= sizeLimit else {
                throw ReleaseCodeSignatureVerifierError.unsignedBundle
            }
            data.append(buffer, count: bytesRead)
        }

        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dictionary = plist as? [String: Any],
              let bundleIdentifier = dictionary["CFBundleIdentifier"] as? String else {
            throw ReleaseCodeSignatureVerifierError.unsignedBundle
        }
        return bundleIdentifier
    }

    private func validateSignaturePolicy() throws {
        guard !policy.expectedTeamIdentifier.isEmpty,
              !policy.requireSignedUpdates || !policy.signingCertificateFingerprintSHA256.isEmpty else {
            throw ReleaseCodeSignatureVerifierError.misconfiguredSignaturePolicy
        }
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
        let teamIdentifier = signingInfo[kSecCodeInfoTeamIdentifier as String] as? String ?? ""
        guard teamIdentifier == policy.expectedTeamIdentifier else {
            throw ReleaseCodeSignatureVerifierError.teamIdentifierMismatch(
                expected: policy.expectedTeamIdentifier,
                actual: teamIdentifier
            )
        }
    }

    private func verifyCertificateFingerprint(signingInfo: NSDictionary) throws {
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
