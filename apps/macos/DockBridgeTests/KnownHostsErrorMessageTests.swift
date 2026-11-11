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
        // A standalone path segment must also not count (issue #689).
        XCTAssertFalse(
            DockBridgeError.isConnectionLostMessage(
                "failed to upload '/srv/eof.txt': no such file"
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

    func testUploadPermissionDeniedErrorMessageMentionsRemoteDirectory() {
        let message = DockBridgeError.friendlyMessage(for: "failed to upload: permission denied")
        XCTAssertEqual(
            message,
            String(localized: "You do not have write permission on the remote side. Check the remote working directory.")
        )
    }

    func testReadAndUnspecifiedPermissionDeniedMessagesAreOperationNeutral() {
        let messages = [
            "permission denied",
            "PeRmIsSiOn DeNiEd",
            "failed to list directory '/root': Permission denied",
            "failed to download '/root/private.txt' to '/tmp/private.txt': Permission denied",
            "failed to open '/root/private.txt': Permission denied",
            "failed to stat '/root/private.txt': Permission denied",
            "failed to canonicalize remote path '/root': Permission denied",
            // Write-operation tokens in paths do not identify the operation.
            "failed to download '/srv/failed to upload.txt' to '/tmp/a': Permission denied",
            "failed to list directory '/srv/failed to create directory': Permission denied",
        ]
        let expected = String(localized: "You do not have permission to access this path on the remote side.")

        for raw in messages {
            XCTAssertEqual(DockBridgeError.friendlyMessage(for: raw), expected, raw)
        }
    }

    func testPermissionDeniedIsOperationNeutralThroughMessageBasedErrorCases() {
        let raw = "failed to list directory '/root': Permission denied"
        let errors: [DockBridgeError] = [
            .Other(message: raw),
            .ConnectionLost(message: raw),
            .Config(message: raw),
        ]

        for error in errors {
            XCTAssertEqual(
                error.dockBridgeUserMessage,
                String(localized: "You do not have permission to access this path on the remote side.")
            )
        }
    }

    func testPermissionDeniedPreservesMoreSpecificErrorMessages() {
        let cases = [
            (
                "authentication failed: Permission denied",
                String(localized: "Check the username and password.")
            ),
            (
                "failed to load private key from /tmp/key: Permission denied",
                String(localized: "Unable to load the private key. Check the key file path, permissions, and passphrase.")
            ),
            (
                "failed to read known hosts store: Permission denied",
                String(localized: "Unable to load the host key store. Quit the app, back up or remove known_hosts.json, then reconnect.")
            ),
        ]

        for (raw, expected) in cases {
            XCTAssertEqual(DockBridgeError.friendlyMessage(for: raw), expected, raw)
        }
    }

    func testReadErrorsWithoutPermissionDeniedKeepRawMessage() {
        let messages = [
            "failed to download '/remote/a' to '/tmp/a': No such file",
            "failed to list directory '/remote': server-specific error",
        ]
        for raw in messages {
            XCTAssertEqual(DockBridgeError.friendlyMessage(for: raw), raw)
        }
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

    func testHostKeyRejectedTypedErrorMessageIsUserFriendly() {
        let error = DockBridgeError.HostKeyRejected(host: "example.com", port: 22)

        XCTAssertEqual(
            error.userFriendlyMessage,
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

    func testUnsupportedPasswordAuthenticationMessageIsNotCredentialPrompt() {
        let message = DockBridgeError.friendlyMessage(
            for: "password authentication is not supported by the server"
        )

        XCTAssertEqual(
            message,
            String(
                localized: "This server does not accept password authentication. Use public key authentication or another supported method."
            )
        )
        XCTAssertFalse(DockBridgeError.isAuthenticationMessage(message))
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

    func testPrivateKeyLoadFailedMessageMentionsKeyPathAndPassphrase() {
        let error = DockBridgeError.PrivateKeyLoadFailed(
            path: "/tmp/id_ed25519",
            message: "incorrect passphrase"
        )

        XCTAssertEqual(
            error.dockBridgeUserMessage,
            String(
                localized: "Unable to load the private key. Check the key file path, permissions, and passphrase."
            )
        )
    }

    func testRawPrivateKeyLoadFailureMapsToKeySpecificMessage() {
        let message = DockBridgeError.friendlyMessage(
            for: "failed to load private key from /tmp/id_ed25519: incorrect passphrase"
        )

        XCTAssertEqual(
            message,
            String(
                localized: "Unable to load the private key. Check the key file path, permissions, and passphrase."
            )
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

    func testReadPermissionDeniedDoesNotSuggestCredentialOrTransferRecovery() {
        let friendly = DockBridgeError.friendlyMessage(
            for: "failed to list directory '/root': Permission denied"
        )
        XCTAssertEqual(
            MainViewModel.recoveryKind(for: friendly, isDisconnected: false),
            .none
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
