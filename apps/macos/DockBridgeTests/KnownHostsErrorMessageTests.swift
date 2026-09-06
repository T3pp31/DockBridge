import XCTest
@testable import DockBridge

final class KnownHostsErrorMessageTests: XCTestCase {
    func testSessionClosedErrorMessageIsUserFriendly() {
        let message = DockBridgeError.friendlyMessage(for: "failed to upload: session closed")
        XCTAssertTrue(message.contains("closed"))
    }

    func testConnectionLostMessageDetection() {
        XCTAssertTrue(DockBridgeError.isConnectionLostMessage("session closed"))
        XCTAssertTrue(DockBridgeError.isConnectionLostMessage("Connection reset by peer"))
        XCTAssertFalse(DockBridgeError.isConnectionLostMessage("permission denied"))
    }

    func testConnectionStatusTitles() {
        XCTAssertEqual(ConnectionStatus.disconnected.statusTitle, "Disconnected")
        XCTAssertEqual(
            ConnectionStatus.connected(endpoint: "user@host:22").statusTitle,
            "Connected: user@host:22"
        )
    }

    func testPermissionDeniedErrorMessageMentionsRemoteDirectory() {
        let message = DockBridgeError.friendlyMessage(for: "failed to upload: permission denied")
        XCTAssertTrue(message.lowercased().contains("remote"))
    }

    func testCorruptedKnownHostsErrorMessageIsUserFriendly() {
        let raw = "failed to read known hosts store at /tmp/known_hosts.json: missing field `entries`"
        let message = DockBridgeError.friendlyMessage(for: raw).lowercased()

        XCTAssertTrue(
            message.contains("known hosts") || message.contains("host key"),
            "Expected known hosts guidance, got: \(message)"
        )
    }

    func testMkdirFailedErrorMessageMentionsRemoteDirectory() {
        let message = DockBridgeError.friendlyMessage(
            for: "failed to create directory '/home/demo': Permission denied"
        )
        XCTAssertTrue(message.lowercased().contains("remote"))
        XCTAssertTrue(message.lowercased().contains("working directory"))
    }

    func testUploadNoSuchFileErrorMessageMentionsRemoteDirectory() {
        let message = DockBridgeError.friendlyMessage(
            for: "failed to upload '/tmp/file.pdf' to '/home/demo/file.pdf': No such file: No such file"
        )
        XCTAssertTrue(message.lowercased().contains("remote"))
        XCTAssertTrue(message.lowercased().contains("destination"))
    }

    func testHostKeyRejectedErrorMessageIsUserFriendly() {
        let message = DockBridgeError.friendlyMessage(
            for: "host key rejected by user for example.com:22"
        )
        XCTAssertEqual(message, "Connection aborted because the host key was not approved.")
    }

    func testAuthenticationRejectedErrorIsNotMappedToHostKeyMessage() {
        let message = DockBridgeError.friendlyMessage(
            for: "connection rejected: authentication failed for user 'demo'"
        )
        XCTAssertTrue(message.lowercased().contains("username") || message.lowercased().contains("password"))
        XCTAssertFalse(message.lowercased().contains("host key"))
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
        let error = DockBridgeError.Generic(
            message: "authentication failed for user 'demo'"
        )
        XCTAssertTrue(error.isAuthenticationFailure)
        XCTAssertEqual(error.dockBridgeUserMessage, "Check the username and password.")

        let keyError = DockBridgeError.Generic(
            message: "failed to load private key from /tmp/key: decrypt failed"
        )
        XCTAssertTrue(keyError.isAuthenticationFailure)
    }
}

@MainActor
final class ErrorRecoveryKindTests: XCTestCase {
    func testAuthMessagesMapToEditConnection() {
        XCTAssertEqual(
            MainViewModel.recoveryKind(for: "Check the username and password.", isDisconnected: false),
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
            MainViewModel.recoveryKind(for: "The connection was closed. Reconnect and try again.", isDisconnected: true),
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
