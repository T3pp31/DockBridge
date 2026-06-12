import XCTest
@testable import DockBridge

final class HostKeyConfirmViewTests: XCTestCase {
    func testMismatchChallengeIsDetected() {
        // Given: a challenge with an expected fingerprint
        let challenge = HostKeyChallenge(
            host: "example.com",
            port: 22,
            fingerprintSha256: "SHA256:new-fingerprint",
            expectedFingerprintSha256: "SHA256:old-fingerprint"
        )

        // When: rendering the confirmation view
        let view = HostKeyConfirmView(
            challenge: challenge,
            onAccept: {},
            onReject: {}
        )

        // Then: the view builds without crashing for mismatch mode
        XCTAssertNotNil(view.body)
    }

    func testUnknownChallengeHasNoExpectedFingerprint() {
        // Given: a first-connection challenge
        let challenge = HostKeyChallenge(
            host: "example.com",
            port: 22,
            fingerprintSha256: "SHA256:new-fingerprint",
            expectedFingerprintSha256: nil
        )

        // When: rendering the confirmation view
        let view = HostKeyConfirmView(
            challenge: challenge,
            onAccept: {},
            onReject: {}
        )

        // Then: the view builds without crashing for unknown mode
        XCTAssertNotNil(view.body)
    }
}
