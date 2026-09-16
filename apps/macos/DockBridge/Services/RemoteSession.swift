import Foundation

/// A single active SSH/SFTP session owned by `RustBridgeService`.
///
/// `RustBridgeService` shares one `DockBridgeClient` (which already supports
/// multiple sessions) and manages a map of `RemoteSession` objects keyed by
/// the Rust-side `sessionId`. Each window/tab can bind to its own session so
/// multiple servers can be used at the same time.
@MainActor
final class RemoteSession: ObservableObject, Identifiable {
    /// Rust-side session identifier; `nil` while connecting.
    private(set) var sessionId: UInt64?
    /// Connection profile that opened this session.
    let profileID: UUID
    /// Profile endpoint label used for display.
    let endpointLabel: String
    /// Set once connected.
    @Published private(set) var connectionStatus: ConnectionStatus = .connecting(endpoint: "")
    @Published private(set) var lastDisconnectReason: String?
    @Published private(set) var initialRemoteDirectory: String?
    @Published private(set) var connectedUsername: String?

    /// Stable identity for SwiftUI (window/tab binding).
    let id: UUID

    init(
        id: UUID = UUID(),
        profileID: UUID,
        endpointLabel: String
    ) {
        self.id = id
        self.profileID = profileID
        self.endpointLabel = endpointLabel
    }

    var isConnected: Bool { connectionStatus.isConnected }
    var isConnecting: Bool { connectionStatus.isConnecting }

    func markConnected(
        sessionId: UInt64,
        username: String,
        initialDirectory: String
    ) {
        self.sessionId = sessionId
        connectedUsername = username
        initialRemoteDirectory = initialDirectory
        connectionStatus = .connected(endpoint: endpointLabel)
    }

    func markDisconnected() {
        sessionId = nil
        initialRemoteDirectory = nil
        connectedUsername = nil
        connectionStatus = .disconnected
    }

    func markConnecting() {
        connectionStatus = .connecting(endpoint: endpointLabel)
        lastDisconnectReason = nil
    }

    /// Simulates an unexpected remote disconnect (used by event handler and tests).
    func markLost(reason: String) {
        lastDisconnectReason = reason
        markDisconnected()
    }
}
