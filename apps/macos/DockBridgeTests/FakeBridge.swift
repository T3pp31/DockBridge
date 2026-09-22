import Foundation
@testable import DockBridge

/// Test double for `RemoteBridging` that records calls and lets tests script
/// directory listings / transfer tasks without a live SSH server.
@MainActor
final class FakeBridge: RemoteBridging {
    var connectionStatus: ConnectionStatus = .disconnected
    var connectedProfileID: UUID?
    var lastDisconnectReason: String?
    var initialRemoteDirectory: String?
    var connectedUsername: String?
    var pendingHostKeyChallenge: HostKeyChallenge?
    var isConnected: Bool { connectionStatus.isConnected }

    /// Directory listings keyed by path; missing paths throw `FakeBridgeError.listingNotFound`.
    var directoryListings: [String: [RemoteFileRecord]] = [:]
    /// Paths requested through `listDirectory`, used to verify refreshes.
    private(set) var listedDirectories: [String] = []
    /// Transfer tasks returned by `fetchTransferTasks`.
    var transferTasks: [TransferTaskRecord] = []
    /// Upload destinations recorded during `upload`.
    private(set) var uploaded: [(
        localPath: String,
        remoteDirectory: String,
        overwritePolicy: TransferOverwritePolicy
    )] = []
    /// Download destinations recorded during `download`.
    private(set) var downloaded: [(
        remotePath: String,
        localDirectory: String,
        overwritePolicy: TransferOverwritePolicy
    )] = []
    /// Delete paths recorded during `deleteRemote`.
    private(set) var deleted: [String] = []
    /// Rename pairs recorded during `renameRemote`.
    private(set) var renamed: [(from: String, to: String)] = []
    /// mkdir paths recorded during `mkdirRemote`.
    private(set) var createdDirectories: [String] = []
    /// Set to fake a remote failure; `true` makes transfer calls throw.
    var failTransfers = false
    /// Set to fake a connection failure; `true` makes `connect` throw.
    var failConnect = false
    /// Simulates write-impossible remote state so `upload` throws.
    var uploadFails = false
    /// Simulates read-impossible remote state so `download` throws.
    var downloadFails = false
    /// Simulates delete errors.
    var deleteFails = false

    func connect(profile: ConnectionProfile, password: String?, passphrase: String?) async throws {
        connectedProfileID = profile.id
        connectedUsername = profile.username
        if failConnect {
            connectionStatus = .disconnected
            throw DockBridgeError.Other(message: "simulated connect failure")
        }
        connectionStatus = .connected(endpoint: profile.endpointLabel)
    }

    func disconnect() async throws {
        connectionStatus = .disconnected
        connectedProfileID = nil
        connectedUsername = nil
        lastDisconnectReason = nil
    }

    func getInitialDirectory() async throws -> String {
        initialRemoteDirectory ?? "/"
    }

    func listDirectory(path: String) async throws -> [RemoteFileRecord] {
        listedDirectories.append(path)
        if let items = directoryListings[path] { return items }
        throw DockBridgeError.Other(message: "listing not found: \(path)")
    }

    func firstExistingHomeDirectoryCandidate(for username: String) async -> String? {
        let candidates = ["/home/\(username)", "/Users/\(username)"]
        for candidate in candidates where directoryListings[candidate] != nil {
            return candidate
        }
        return nil
    }

    func upload(
        localPath: String,
        remoteDirectory: String,
        overwritePolicy: TransferOverwritePolicy
    ) async throws {
        uploaded.append((localPath, remoteDirectory, overwritePolicy))
        if uploadFails {
            throw DockBridgeError.Other(message: "simulated upload failure")
        }
    }

    func download(
        remotePath: String,
        localDirectory: String,
        overwritePolicy: TransferOverwritePolicy
    ) async throws {
        downloaded.append((remotePath, localDirectory, overwritePolicy))
        if downloadFails {
            throw DockBridgeError.Other(message: "simulated download failure")
        }
    }

    func deleteRemote(path: String) async throws {
        deleted.append(path)
        if deleteFails {
            throw DockBridgeError.Other(message: "simulated delete failure")
        }
    }

    func renameRemote(from: String, to: String) async throws {
        renamed.append((from, to))
        if failTransfers {
            throw DockBridgeError.Other(message: "simulated rename failure")
        }
    }

    func mkdirRemote(path: String) async throws {
        createdDirectories.append(path)
        if failTransfers {
            throw DockBridgeError.Other(message: "simulated mkdir failure")
        }
    }

    func fetchTransferTasks() async throws -> [TransferTaskRecord] {
        transferTasks
    }

    func cancelTransfer(taskId: UInt64) async throws {
        transferTasks.removeAll { $0.id == taskId }
    }

    func clearCompletedTransfers() async throws {
        transferTasks.removeAll { task in
            switch task.status {
            case .completed, .failed, .cancelled: return true
            default: return false
            }
        }
    }

    func clearAllTransfers() async throws {
        transferTasks = []
    }

    func retryTransfer(taskId: UInt64) async throws {}

    func respondToHostKeyChallenge(accepted: Bool) {
        pendingHostKeyChallenge = nil
    }

    /// Convenience: mark a task in-progress to exercise speed sampling.
    func setTransferTasks(_ tasks: [TransferTaskRecord]) {
        transferTasks = tasks
    }
}
