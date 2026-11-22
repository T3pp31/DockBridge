import AppKit
import SwiftUI
import XCTest
@testable import DockBridge

@MainActor
final class HostKeyConfirmViewTests: XCTestCase {
    func testMismatchChallengeDisplaysMismatchStateAndInvokesCallbacks() {
        // Given: a challenge with an expected fingerprint (issue #839 F01)
        let challenge = HostKeyChallenge(
            host: "example.com",
            port: 22,
            fingerprintSha256: "SHA256:new-fingerprint",
            expectedFingerprintSha256: "SHA256:old-fingerprint"
        )
        var accepted = 0
        var rejected = 0

        let view = HostKeyConfirmView(
            challenge: challenge,
            onAccept: { accepted += 1 },
            onReject: { rejected += 1 }
        )

        XCTAssertTrue(view.isMismatch)
        XCTAssertTrue(challenge.isHostKeyMismatch)
        XCTAssertEqual(view.dialogTitle, String(localized: "Host Key Changed"))

        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.width, 0)
        XCTAssertGreaterThan(host.fittingSize.height, 0)

        view.onReject()
        view.onAccept()
        XCTAssertEqual(rejected, 1)
        XCTAssertEqual(accepted, 1)
    }

    func testUnknownChallengeDisplaysUnknownStateAndInvokesCallbacks() {
        // Given: a first-connection challenge (issue #839 F01)
        let challenge = HostKeyChallenge(
            host: "example.com",
            port: 22,
            fingerprintSha256: "SHA256:new-fingerprint",
            expectedFingerprintSha256: nil
        )
        var accepted = 0
        var rejected = 0

        let view = HostKeyConfirmView(
            challenge: challenge,
            onAccept: { accepted += 1 },
            onReject: { rejected += 1 }
        )

        XCTAssertFalse(view.isMismatch)
        XCTAssertFalse(challenge.isHostKeyMismatch)
        XCTAssertEqual(view.dialogTitle, String(localized: "Unknown Host Key"))

        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.width, 0)
        XCTAssertGreaterThan(host.fittingSize.height, 0)

        view.onAccept()
        view.onReject()
        XCTAssertEqual(accepted, 1)
        XCTAssertEqual(rejected, 1)
    }
}
