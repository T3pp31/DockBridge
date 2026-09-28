import XCTest
@testable import DockBridge

final class KnownHostsErrorMessageTests: XCTestCase {
    func testSessionClosedErrorMessageIsUserFriendly() {
        let message = DockBridgeError.friendlyMessage(for: "failed to upload: session closed")
        XCTAssertEqual(
            message,
            String(localized: "The connection was closed. Reconnect and try again.")
        )
    }

    func testConnectionLostMessageDetection() {
        XCTAssertTrue(DockBridgeError.isConnectionLostMessage("session closed"))
        XCTAssertTrue(DockBridgeError.isConnectionLostMessage("Connection reset by peer"))
        XCTAssertFalse(DockBridgeError.isConnectionLostMessage("permission denied"))
        XCTAssertFalse(DockBridgeError.isConnectionLostMessage("no such file"))
        XCTAssertTrue(DockBridgeError.isConnectionLostMessage("sender dropped"))
        XCTAssertTrue(DockBridgeError.isConnectionLostMessage("write channel closed"))
        XCTAssertTrue(DockBridgeError.isConnectionLostMessage("RecvError: channel closed"))
        XCTAssertTrue(DockBridgeError.isConnectionLostMessage("unexpected eof"))
        XCTAssertTrue(DockBridgeError.isConnectionLostMessage("connection closed: eof"))
    }

    func testConnectionLostIgnoresEofSubstringInsidePath() {
        // Given: an error embedding a user-controlled path containing "eof"
        // When: checked for connection loss
        // Then: it is NOT treated as disconnected
        XCTAssertFalse(
            DockBridgeError.isConnectionLostMessage(
                "failed to delete '/home/geoffrey/thereof.txt': Permission denied"
            )
        )
        XCTAssertFalse(
            DockBridgeError.isConnectionLostMessage(
                "failed to upload 'geoff.txt': no such file"
            )
        )
    }

    func testConnectionStatusTitles() {
        // The title is localized; assert the state transition is reflected
        // rather than a specific language string.
        XCTAssertFalse(ConnectionStatus.disconnected.statusTitle.isEmpty)
        let connectedTitle = ConnectionStatus.connected(endpoint: "user@host:22").statusTitle
        XCTAssertFalse(connectedTitle.isEmpty)
        XCTAssertTrue(connectedTitle.contains("user@host:22"))
    }

    func testPermissionDeniedErrorMessageMentionsRemoteDirectory() {
        let message = DockBridgeError.friendlyMessage(for: "failed to upload: permission denied")
        XCTAssertEqual(
            message,
            String(localized: "You do not have write permission on the remote side. Check the remote working directory.")
        )
    }

    func testCorruptedKnownHostsErrorMessageIsUserFriendly() {
        let raw = "failed to read known hosts store at /tmp/known_hosts.json: missing field `entries`"
        let message = DockBridgeError.friendlyMessage(for: raw)

        XCTAssertEqual(
            message,
            String(localized: "Unable to load the host key store. Quit the app, back up or remove known_hosts.json, then reconnect.")
        )
    }

    func testMkdirFailedErrorMessageMentionsRemoteDirectory() {
        let message = DockBridgeError.friendlyMessage(
            for: "failed to create directory '/home/demo': Permission denied"
        )
        XCTAssertEqual(
            message,
            String(localized: "You do not have write permission on the remote side. Check the remote working directory.")
        )
    }

    func testUploadNoSuchFileErrorMessageMentionsRemoteDirectory() {
        let message = DockBridgeError.friendlyMessage(
            for: "failed to upload '/tmp/file.pdf' to '/home/demo/file.pdf': No such file: No such file"
        )
        XCTAssertEqual(
            message,
            String(localized: "The remote destination directory does not exist. Open a valid directory in the remote pane and try again.")
        )
    }

    func testHostKeyRejectedErrorMessageIsUserFriendly() {
        let message = DockBridgeError.friendlyMessage(
            for: "host key rejected by user for example.com:22"
        )
        XCTAssertEqual(
            message,
            String(localized: "Connection aborted because the host key was not approved.")
        )
    }

    func testAuthenticationRejectedErrorIsNotMappedToHostKeyMessage() {
        let message = DockBridgeError.friendlyMessage(
            for: "connection rejected: authentication failed for user 'demo'"
        )
        XCTAssertEqual(message, String(localized: "Check the username and password."))
        XCTAssertNotEqual(
            message,
            String(localized: "Connection aborted because the host key was not approved.")
        )
    }

    func testAuthenticationMessageDetectionUsesRawBridgeTokens() {
        XCTAssertTrue(
            DockBridgeError.isAuthenticationMessage(
                "authentication failed for user 'demo'"
            )
        )
        XCTAssertTrue(
            DockBridgeError.isAuthenticationMessage(
                "failed to load private key from /tmp/id_ed25519: incorrect passphrase"
            )
        )
        XCTAssertTrue(
            DockBridgeError.isAuthenticationMessage("Check the username and password.")
        )
        XCTAssertFalse(
            DockBridgeError.isAuthenticationMessage(
                "password authentication is not supported by the server"
            )
        )
        XCTAssertFalse(
            DockBridgeError.isAuthenticationMessage("failed to upload: permission denied")
        )
        XCTAssertFalse(
            DockBridgeError.isAuthenticationMessage("host key rejected by user for example.com:22")
        )
    }

    func testAuthenticationFailureInspectsGenericMessageBeforeFriendlyMapping() {
        let error = DockBridgeError.Other(
            message: "authentication failed for user 'demo'"
        )
        XCTAssertTrue(error.isAuthenticationFailure)
        XCTAssertEqual(
            error.dockBridgeUserMessage,
            String(localized: "Check the username and password.")
        )

        let keyError = DockBridgeError.Other(
            message: "failed to load private key from /tmp/key: decrypt failed"
        )
        XCTAssertTrue(keyError.isAuthenticationFailure)
    }
}

@MainActor
final class ErrorRecoveryKindTests: XCTestCase {
    func testAuthMessagesMapToEditConnection() {
        XCTAssertEqual(
            MainViewModel.recoveryKind(
                for: String(localized: "Check the username and password."),
                isDisconnected: false
            ),
            .editConnection
        )
        XCTAssertEqual(
            MainViewModel.recoveryKind(for: "authentication failed", isDisconnected: true),
            .editConnection
        )
        XCTAssertEqual(
            MainViewModel.recoveryKind(
                for: "Access to the private key was denied. Open the connection settings.",
                isDisconnected: false
            ),
            .editConnection
        )
    }

    func testPermissionDeniedDoesNotMapToEditConnection() {
        let friendly = DockBridgeError.friendlyMessage(for: "failed to upload: permission denied")
        XCTAssertEqual(
            MainViewModel.recoveryKind(for: friendly, isDisconnected: false),
            .showInQueue
        )
        XCTAssertNotEqual(
            MainViewModel.recoveryKind(for: "permission denied", isDisconnected: false),
            .editConnection
        )
    }

    func testTransferFailuresMapToShowInQueue() {
        XCTAssertEqual(
            MainViewModel.recoveryKind(for: "failed to upload '/tmp/a' to '/remote/a'", isDisconnected: false),
            .showInQueue
        )
        XCTAssertEqual(
            MainViewModel.recoveryKind(for: "failed to download remote file", isDisconnected: false),
            .showInQueue
        )
    }

    func testDisconnectedMapsToReconnect() {
        XCTAssertEqual(
            MainViewModel.recoveryKind(
                for: String(localized: "The connection was closed. Reconnect and try again."),
                isDisconnected: true
            ),
            .reconnect
        )
    }

    func testProfileMentionedPrefersEndpointLabel() {
        let alpha = ConnectionProfile(name: "Alpha", host: "alpha.example", username: "alice")
        let beta = ConnectionProfile(name: "Beta", host: "beta.example", username: "bob")
        let message = "session closed for \(alpha.endpointLabel)"
        let matched = MainViewModel.profileMentioned(in: message, profiles: [alpha, beta])
        XCTAssertEqual(matched?.id, alpha.id)
    }

    func testProfileMentionedReturnsNilWhenAmbiguous() {
        let one = ConnectionProfile(name: "", host: "shared.example", username: "a")
        let two = ConnectionProfile(name: "", host: "shared.example", username: "b")
        let matched = MainViewModel.profileMentioned(
            in: "error talking to shared.example",
            profiles: [one, two]
        )
        XCTAssertNil(matched)
    }
}
