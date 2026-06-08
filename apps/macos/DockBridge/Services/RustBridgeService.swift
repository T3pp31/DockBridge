import Foundation

@MainActor
final class RustBridgeService: NSObject, ObservableObject, HostKeyHandler {
    @Published private(set) var isConnected = false
    @Published var pendingHostKeyChallenge: HostKeyChallenge?
    @Published var hostKeyContinuation: CheckedContinuation<Bool, Never>?

    private var client: DockBridgeClient?
    private var sessionId: UInt64?
    private let settings: AppSettingsService
    private let hostKeyStore: HostKeyStore

    init(
        settings: AppSettingsService = .shared,
        hostKeyStore: HostKeyStore = .shared
    ) {
        self.settings = settings
        self.hostKeyStore = hostKeyStore
        super.init()
    }

    func prepareClient() {
        try? hostKeyStore.ensureStoreExists()
        let record = settings.buildAppConfigRecord()
        client = DockBridgeClient(appConfig: record, hostKeyHandler: self)
    }

    func connect(
        profile: ConnectionProfile,
        password: String?,
        passphrase: String?
    ) async throws {
        if client == nil {
            prepareClient()
        }
        guard let client else {
            throw DockBridgeError.Generic(message: "Rust client is not initialized.")
        }

        let record = profile.toRecord(password: password, passphrase: passphrase)
        let newSessionId = try await Task.detached(priority: .userInitiated) {
            try client.connect(profile: record)
        }.value

        sessionId = newSessionId
        isConnected = true
    }

    func disconnect() async throws {
        guard let client, let sessionId else { return }
        try await Task.detached(priority: .userInitiated) {
            try client.disconnect(sessionId: sessionId)
        }.value
        self.sessionId = nil
        isConnected = false
    }

    func listDirectory(path: String) async throws -> [RemoteFileRecord] {
        try await runOnBridge { client, sessionId in
            try client.listDirectory(sessionId: sessionId, path: path)
        }
    }

    func upload(localPath: String, remotePath: String) async throws {
        try await runOnBridge { client, sessionId in
            try client.upload(sessionId: sessionId, localPath: localPath, remotePath: remotePath)
        }
        await refreshTransferQueue()
    }

    func download(remotePath: String, localPath: String) async throws {
        try await runOnBridge { client, sessionId in
            try client.download(sessionId: sessionId, remotePath: remotePath, localPath: localPath)
        }
        await refreshTransferQueue()
    }

    func deleteRemote(path: String) async throws {
        try await runOnBridge { client, sessionId in
            try client.delete(sessionId: sessionId, remotePath: path)
        }
    }

    func renameRemote(from: String, to: String) async throws {
        try await runOnBridge { client, sessionId in
            try client.rename(sessionId: sessionId, from: from, to: to)
        }
    }

    func mkdirRemote(path: String) async throws {
        try await runOnBridge { client, sessionId in
            try client.createDirectory(sessionId: sessionId, remotePath: path)
        }
    }

    func fetchTransferTasks() async throws -> [TransferTaskRecord] {
        guard let client else { return [] }
        return try await Task.detached(priority: .userInitiated) {
            client.getTransferQueue()
        }.value
    }

    func cancelTransfer(taskId: UInt64) async throws {
        try await runOnBridge { client, _ in
            try client.cancelTransfer(taskId: taskId)
        }
    }

    func respondToHostKeyChallenge(accepted: Bool) {
        pendingHostKeyChallenge = nil
        hostKeyContinuation?.resume(returning: accepted)
        hostKeyContinuation = nil
    }

    // MARK: - HostKeyHandler

    nonisolated func promptUnknownHost(challenge: HostKeyChallenge) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        final class Decision: @unchecked Sendable {
            var accepted = false
        }
        let decision = Decision()

        Task { @MainActor in
            self.pendingHostKeyChallenge = challenge
            decision.accepted = await withCheckedContinuation { continuation in
                self.hostKeyContinuation = continuation
            }
            self.pendingHostKeyChallenge = nil
            semaphore.signal()
        }

        semaphore.wait()
        return decision.accepted
    }

    private func refreshTransferQueue() async {
        _ = try? await fetchTransferTasks()
    }

    private func runOnBridge(
        _ operation: @escaping @Sendable (DockBridgeClient, UInt64) throws -> Void
    ) async throws {
        try await runOnBridge { client, sessionId -> Void in
            try operation(client, sessionId)
            return ()
        }
    }

    private func runOnBridge<T: Sendable>(
        _ operation: @escaping @Sendable (DockBridgeClient, UInt64) throws -> T
    ) async throws -> T {
        guard let client, let sessionId else {
            throw DockBridgeError.Generic(message: "Not connected to a remote host.")
        }
        return try await Task.detached(priority: .userInitiated) {
            try operation(client, sessionId)
        }.value
    }
}
