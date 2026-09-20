import Foundation

/// Interface implemented by the Rust-backed bridge and test doubles.
///
/// ViewModels depend on this protocol (not the concrete
/// `RustBridgeService`) so their logic can be unit-tested without a live
/// SSH server. The protocol deliberately does NOT inherit `ObservableObject`:
/// `ObservableObject.objectWillChange` has an `associatedtype` that cannot be
/// used through an `any` existential, which would force call sites to accept
/// only concrete types. State observation stays on the concrete
/// `RustBridgeService`; ViewModels observe it via `objectWillChange` where
/// needed (e.g. `ConnectionListViewModel` keeps the concrete type for that
/// purpose).
@MainActor
protocol RemoteBridging {
    var connectionStatus: ConnectionStatus { get }
    var connectedProfileID: UUID? { get }
    var lastDisconnectReason: String? { get }
    var initialRemoteDirectory: String? { get }
    var connectedUsername: String? { get }
    var pendingHostKeyChallenge: HostKeyChallenge? { get set }
    var isConnected: Bool { get }

    func connect(profile: ConnectionProfile, password: String?, passphrase: String?) async throws
    func disconnect() async throws
    func getInitialDirectory() async throws -> String
    func listDirectory(path: String) async throws -> [RemoteFileRecord]
    func firstExistingHomeDirectoryCandidate(for username: String) async -> String?
    func upload(
        localPath: String,
        remoteDirectory: String,
        overwritePolicy: TransferOverwritePolicy
    ) async throws
    func download(
        remotePath: String,
        localDirectory: String,
        overwritePolicy: TransferOverwritePolicy
    ) async throws
    func deleteRemote(path: String) async throws
    func renameRemote(from: String, to: String) async throws
    func mkdirRemote(path: String) async throws
    func fetchTransferTasks() async throws -> [TransferTaskRecord]
    func cancelTransfer(taskId: UInt64) async throws
    func clearCompletedTransfers() async throws
    func clearAllTransfers() async throws
    func retryTransfer(taskId: UInt64) async throws
    func respondToHostKeyChallenge(accepted: Bool)
}

extension RemoteBridging {
    /// Backward-compatible convenience for callers that explicitly want the
    /// historical replace behavior.
    func upload(localPath: String, remoteDirectory: String) async throws {
        try await upload(
            localPath: localPath,
            remoteDirectory: remoteDirectory,
            overwritePolicy: .replace
        )
    }

    /// Backward-compatible convenience for callers that explicitly want the
    /// historical replace behavior.
    func download(remotePath: String, localDirectory: String) async throws {
        try await download(
            remotePath: remotePath,
            localDirectory: localDirectory,
            overwritePolicy: .replace
        )
    }
}
