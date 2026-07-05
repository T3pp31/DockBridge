import Foundation

@MainActor
final class RustBridgeService: NSObject, ObservableObject, HostKeyHandler, ConnectionEventHandler {
    @Published private(set) var connectionStatus: ConnectionStatus = .disconnected
    @Published private(set) var connectedProfileID: UUID?
    @Published private(set) var lastDisconnectReason: String?
    @Published private(set) var initialRemoteDirectory: String?
    @Published private(set) var connectedUsername: String?
    @Published var pendingHostKeyChallenge: HostKeyChallenge?
    @Published var hostKeyContinuation: CheckedContinuation<Bool, Never>?

    var isConnected: Bool { connectionStatus.isConnected }

    private var client: DockBridgeClient?
    private var sessionId: UInt64?
    private let settings: AppSettingsService
    private let hostKeyStore: HostKeyStore
    private let bookmarkService: SecurityScopedBookmarkService

    init(
        settings: AppSettingsService = .shared,
        hostKeyStore: HostKeyStore = .shared,
        bookmarkService: SecurityScopedBookmarkService = .shared
    ) {
        self.settings = settings
        self.hostKeyStore = hostKeyStore
        self.bookmarkService = bookmarkService
        super.init()
    }

    func prepareClient() throws {
        try hostKeyStore.ensureStoreDirectoryExists()
        let record = settings.buildAppConfigRecord(knownHostsPath: hostKeyStore.knownHostsPath.path)
        client = try DockBridgeClient(
            appConfig: record,
            hostKeyHandler: self,
            connectionEventHandler: self
        )
    }

    func connect(
        profile: ConnectionProfile,
        password: String?,
        passphrase: String?
    ) async throws {
        let config = settings.loadConfig()
        if let bookmark = config.opensshKnownHostsBookmark {
            try await bookmarkService.withAccess(to: bookmark) { _ in
                try await performConnect(
                    profile: profile,
                    password: password,
                    passphrase: passphrase
                )
            }
        } else {
            try await performConnect(
                profile: profile,
                password: password,
                passphrase: passphrase
            )
        }
    }

    private func performConnect(
        profile: ConnectionProfile,
        password: String?,
        passphrase: String?
    ) async throws {
        try prepareClient()
        guard let client else {
            throw DockBridgeError.Generic(message: "Rust client is not initialized.")
        }

        connectedProfileID = profile.id
        connectionStatus = .connecting(endpoint: profile.endpointLabel)
        lastDisconnectReason = nil

        var password = password
        var passphrase = passphrase
        defer {
            SensitiveString.clear(&password)
            SensitiveString.clear(&passphrase)
        }

        do {
            var record = profile.toRecord(password: password, passphrase: passphrase)
            defer { record.clearCredentials() }

            let newSessionId = try await Task.detached(priority: .userInitiated) {
                try client.connect(profile: record)
            }.value

            let rawInitialDirectory = try await Task.detached(priority: .userInitiated) {
                try client.getInitialDirectory(sessionId: newSessionId)
            }.value

            let resolvedDirectory = try await resolveWorkingDirectory(
                rawInitialDirectory,
                username: profile.username,
                isRootUser: profile.isRootUser,
                client: client,
                sessionId: newSessionId
            )

            sessionId = newSessionId
            connectedUsername = profile.username
            initialRemoteDirectory = resolvedDirectory
            connectionStatus = .connected(endpoint: profile.endpointLabel)
        } catch {
            clearConnectionState()
            throw error
        }
    }

    func disconnect() async throws {
        guard let client, let sessionId else { return }
        try await Task.detached(priority: .userInitiated) {
            try client.disconnect(sessionId: sessionId)
        }.value
        clearConnectionState()
    }

    func getInitialDirectory() async throws -> String {
        try await runOnBridge { client, sessionId in
            try client.getInitialDirectory(sessionId: sessionId)
        }
    }

    func listDirectory(path: String) async throws -> [RemoteFileRecord] {
        try await runOnBridge { client, sessionId in
            try client.listDirectory(sessionId: sessionId, path: path)
        }
    }

    func firstExistingHomeDirectoryCandidate(for username: String) async -> String? {
        guard let client, let sessionId, isConnected else { return nil }
        for candidate in Self.homeDirectoryCandidates(for: username) {
            let exists = await Task.detached(priority: .userInitiated) {
                (try? client.listDirectory(sessionId: sessionId, path: candidate)) != nil
            }.value
            if exists {
                return candidate
            }
        }
        return nil
    }

    func upload(localPath: String, remoteDirectory: String) async throws {
        try await runOnBridge { client, sessionId in
            try client.uploadEntry(
                sessionId: sessionId,
                localPath: localPath,
                remoteDirectory: remoteDirectory
            )
        }
        await refreshTransferQueue()
    }

    func download(remotePath: String, localDirectory: String) async throws {
        try await runOnBridge { client, sessionId in
            try client.downloadEntry(
                sessionId: sessionId,
                remotePath: remotePath,
                localDirectory: localDirectory
            )
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
        guard let client else { return }
        try await Task.detached(priority: .userInitiated) {
            try client.cancelTransfer(taskId: taskId)
        }.value
    }

    func clearCompletedTransfers() async throws {
        guard let client else { return }
        try await Task.detached(priority: .userInitiated) {
            client.clearCompletedTransfers()
        }.value
    }

    func clearAllTransfers() async throws {
        guard let client else { return }
        try await Task.detached(priority: .userInitiated) {
            try client.clearAllTransfers()
        }.value
    }

    func retryTransfer(taskId: UInt64) async throws {
        try await runOnBridge { client, sessionId in
            try client.retryTransfer(sessionId: sessionId, taskId: taskId)
        }
    }

    func respondToHostKeyChallenge(accepted: Bool) {
        pendingHostKeyChallenge = nil
        guard let continuation = hostKeyContinuation else { return }
        hostKeyContinuation = nil
        continuation.resume(returning: accepted)
    }

    // MARK: - HostKeyHandler

    nonisolated func promptUnknownHost(challenge: HostKeyChallenge) -> Bool {
        // The HostKeyHandler protocol requires a non-throwing Bool return, so
        // any error from the synchronous bridge is treated as a rejection —
        // the safe default for an unverified host key.
        do {
            return try DropOperationSync.run { @MainActor in
                await self.awaitHostKeyDecision(for: challenge)
            }
        } catch {
            return false
        }
    }

    @MainActor
    func awaitHostKeyDecision(for challenge: HostKeyChallenge) async -> Bool {
        if pendingHostKeyChallenge != nil {
            respondToHostKeyChallenge(accepted: false)
        }

        let timeoutSecs = settings.loadConfig().connectionTimeoutSecs

        let decision = await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor in
                await withCheckedContinuation { continuation in
                    self.hostKeyContinuation = continuation
                    self.pendingHostKeyChallenge = challenge
                }
            }

            group.addTask { @MainActor in
                do {
                    try await Task.sleep(for: .seconds(timeoutSecs))
                } catch is CancellationError {
                    // The decision task completed first. Cooperatively stop
                    // without touching a later host-key challenge.
                    return false
                } catch {
                    return false
                }
                self.respondToHostKeyChallenge(accepted: false)
                return false
            }

            // Avoid force-unwrapping; default to false (reject) if the group
            // unexpectedly yields no result.
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }

        pendingHostKeyChallenge = nil
        hostKeyContinuation = nil
        return decision
    }

    // MARK: - ConnectionEventHandler

    nonisolated func onSessionDisconnected(sessionId: UInt64, reason: String) {
        Task { @MainActor in
            guard self.sessionId == sessionId else { return }
            self.handleImplicitDisconnect(reason: reason)
        }
    }

    private func handleImplicitDisconnect(reason: String) {
        guard connectionStatus.isConnected || connectionStatus.isConnecting else { return }
        lastDisconnectReason = reason
        resetSessionFields()
    }

    private func clearConnectionState() {
        resetSessionFields()
        connectedProfileID = nil
        client = nil
    }

    private func resetSessionFields() {
        sessionId = nil
        initialRemoteDirectory = nil
        connectedUsername = nil
        connectionStatus = .disconnected
    }

    private func refreshTransferQueue() async {
        _ = try? await fetchTransferTasks()
    }

    private func resolveWorkingDirectory(
        _ rawDirectory: String,
        username: String,
        isRootUser: Bool,
        client: DockBridgeClient,
        sessionId: UInt64
    ) async throws -> String {
        guard rawDirectory == "/", !isRootUser else {
            return rawDirectory
        }

        for candidate in Self.homeDirectoryCandidates(for: username) {
            let exists = try await Task.detached(priority: .userInitiated) {
                (try? client.listDirectory(sessionId: sessionId, path: candidate)) != nil
            }.value
            if exists {
                return candidate
            }
        }

        return rawDirectory
    }

    private static func homeDirectoryCandidates(for username: String) -> [String] {
        [
            "/home/\(username)",
            "/Users/\(username)",
        ]
    }

    private func runOnBridge<T: Sendable>(
        _ operation: @escaping @Sendable (DockBridgeClient, UInt64) throws -> T
    ) async throws -> T {
        guard let client, let sessionId else {
            throw DockBridgeError.Generic(message: "Not connected to a remote host.")
        }

        do {
            return try await Task.detached(priority: .userInitiated) {
                try operation(client, sessionId)
            }.value
        } catch {
            if error.isConnectionLost {
                let reason = error.dockBridgeUserMessage
                Task { @MainActor in
                    self.handleImplicitDisconnect(reason: reason)
                }
            }
            throw error
        }
    }
}
