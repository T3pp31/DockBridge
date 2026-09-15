import Combine
import Foundation

@MainActor
final class RustBridgeService: NSObject, ObservableObject, HostKeyHandler, ConnectionEventHandler {
    /// Published state for the *active* session (kept for API compatibility with
    /// existing views). When multiple sessions exist, these reflect the
    /// currently selected session.
    @Published private(set) var connectionStatus: ConnectionStatus = .disconnected
    @Published private(set) var connectedProfileID: UUID?
    @Published private(set) var lastDisconnectReason: String?
    @Published private(set) var initialRemoteDirectory: String?
    @Published private(set) var connectedUsername: String?
    @Published var pendingHostKeyChallenge: HostKeyChallenge?
    @Published var hostKeyContinuation: CheckedContinuation<Bool, Never>?

    var isConnected: Bool { connectionStatus.isConnected }

    /// All open sessions keyed by `RemoteSession.id`.
    private(set) var sessions: [UUID: RemoteSession] = [:]
    /// The session currently surfaced through the published properties above.
    private(set) var activeSessionID: UUID?

    private var client: DockBridgeClient?
    private var sessionId: UInt64?
    private let settings: AppSettingsService
    private let hostKeyStore: HostKeyStore
    private let bookmarkService: SecurityScopedBookmarkService
    private var sessionCancellables: [UUID: AnyCancellable] = [:]

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

    // MARK: - Session management

    /// Returns the active session, or the last connected one if none is marked active.
    var activeSession: RemoteSession? {
        if let id = activeSessionID, let session = sessions[id] {
            return session
        }
        // Fall back to the most recently connected session for API compat.
        return sessions.values.max {
            ($0.sessionId ?? 0) < ($1.sessionId ?? 0)
        }
    }

    /// All sessions sorted by creation order (oldest first).
    var allSessions: [RemoteSession] {
        sessions.values.sorted { ($0.sessionId ?? 0) < ($1.sessionId ?? 0) }
    }

    /// Returns the session with the given id, if open.
    func session(id: UUID) -> RemoteSession? {
        sessions[id]
    }

    /// Switches which session is surfaced via the published properties.
    func setActiveSession(_ session: RemoteSession) {
        activeSessionID = session.id
        syncPublishedState(from: session)
        refreshActiveSessionState()
    }

    /// Connects to a profile, creating a new `RemoteSession` that can coexist
    /// with other open sessions. Returns the new session.
    @discardableResult
    func connectToNewSession(
        profile: ConnectionProfile,
        password: String?,
        passphrase: String?
    ) async throws -> RemoteSession {
        let config = settings.loadConfig()
        if let bookmark = config.opensshKnownHostsBookmark {
            return try await bookmarkService.withAccess(to: bookmark) { _ in
                try await performConnectNewSession(
                    profile: profile,
                    password: password,
                    passphrase: passphrase
                )
            }
        } else {
            return try await performConnectNewSession(
                profile: profile,
                password: password,
                passphrase: passphrase
            )
        }
    }

    // MARK: - Legacy single-session API (delegates to active session)

    func connect(
        profile: ConnectionProfile,
        password: String?,
        passphrase: String?
    ) async throws {
        _ = try await connectToNewSession(
            profile: profile,
            password: password,
            passphrase: passphrase
        )
    }

    func disconnect() async throws {
        guard let client else { return }
        let target = activeSession
        let rustSessionId = target?.sessionId ?? sessionId
        guard let rustSessionId else { return }
        try await Task.detached(priority: .userInitiated) {
            try client.disconnect(sessionId: rustSessionId)
        }.value
        if let target {
            removeSession(target)
        } else {
            resetSessionFields()
            connectedProfileID = nil
        }
        refreshActiveSessionState()
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
        guard let client, isConnected else { return nil }
        let rustSessionId = activeSession?.sessionId ?? sessionId
        guard let rustSessionId else { return nil }
        for candidate in Self.homeDirectoryCandidates(for: username) {
            let exists = await Task.detached(priority: .userInitiated) {
                (try? client.listDirectory(sessionId: rustSessionId, path: candidate)) != nil
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
                    return false
                } catch {
                    return false
                }
                self.respondToHostKeyChallenge(accepted: false)
                return false
            }

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
            let target = self.sessions.values.first { $0.sessionId == sessionId }
            if let target {
                target.markLost(reason: reason)
                if target.id == self.activeSessionID {
                    self.syncPublishedState(from: target)
                }
            } else if self.sessionId == sessionId {
                self.handleImplicitDisconnect(reason: reason)
            }
        }
    }

    private func handleImplicitDisconnect(reason: String) {
        guard connectionStatus.isConnected || connectionStatus.isConnecting else { return }
        lastDisconnectReason = reason
        resetSessionFields()
        connectedProfileID = nil
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
        guard let client else {
            throw DockBridgeError.Generic(message: "Not connected to a remote host.")
        }
        let rustSessionId = activeSession?.sessionId ?? sessionId
        guard let rustSessionId else {
            throw DockBridgeError.Generic(message: "Not connected to a remote host.")
        }

        do {
            return try await Task.detached(priority: .userInitiated) {
                try operation(client, rustSessionId)
            }.value
        } catch {
            if error.isConnectionLost {
                let reason = error.dockBridgeUserMessage
                Task { @MainActor in
                    if let active = self.activeSession {
                        active.markLost(reason: reason)
                        self.syncPublishedState(from: active)
                    } else {
                        self.handleImplicitDisconnect(reason: reason)
                    }
                }
            }
            throw error
        }
    }

    // MARK: - Private session helpers

    private func performConnectNewSession(
        profile: ConnectionProfile,
        password: String?,
        passphrase: String?
    ) async throws -> RemoteSession {
        try prepareClient()
        guard let client else {
            throw DockBridgeError.Generic(message: "Rust client is not initialized.")
        }

        let session = RemoteSession(
            profileID: profile.id,
            endpointLabel: profile.endpointLabel
        )
        sessions[session.id] = session
        activeSessionID = session.id
        session.markConnecting()

        // Mirror into the legacy published state for existing views.
        sessionId = session.sessionId
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

            session.markConnected(
                sessionId: newSessionId,
                username: profile.username,
                initialDirectory: resolvedDirectory
            )
            self.sessionId = newSessionId
            connectedUsername = profile.username
            initialRemoteDirectory = resolvedDirectory
            connectionStatus = .connected(endpoint: profile.endpointLabel)
            observe(session)
            return session
        } catch {
            removeSession(session)
            throw error
        }
    }

    private func observe(_ session: RemoteSession) {
        guard sessionCancellables[session.id] == nil else { return }
        sessionCancellables[session.id] = session.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.refreshActiveSessionState()
            }
        }
    }

    private func removeSession(_ session: RemoteSession) {
        sessions.removeValue(forKey: session.id)
        sessionCancellables.removeValue(forKey: session.id)
        if activeSessionID == session.id {
            activeSessionID = nil
        }
        if let next = allSessions.first {
            setActiveSession(next)
        } else {
            resetSessionFields()
            connectedProfileID = nil
        }
    }

    /// Copies the given session's state into the legacy published properties
    /// that existing views/ViewModels observe.
    private func syncPublishedState(from session: RemoteSession) {
        connectedProfileID = session.profileID
        connectionStatus = session.connectionStatus
        lastDisconnectReason = session.lastDisconnectReason
        initialRemoteDirectory = session.initialRemoteDirectory
        connectedUsername = session.connectedUsername
        sessionId = session.sessionId
    }

    private func refreshActiveSessionState() {
        if let session = activeSession {
            syncPublishedState(from: session)
        }
    }
}

#if DEBUG
extension RustBridgeService {
    func applyConnectionStateForTesting(
        status: ConnectionStatus,
        profileID: UUID? = nil
    ) {
        guard let profileID else {
            // No profile supplied: reflect a pure disconnect (legacy behavior).
            connectionStatus = status
            connectedProfileID = nil
            return
        }
        let session = RemoteSession(profileID: profileID, endpointLabel: "test@example.com")
        sessions[session.id] = session
        activeSessionID = session.id
        switch status {
        case .disconnected:
            session.markConnecting()
            session.markDisconnected()
        case .connecting:
            session.markConnecting()
        case .connected:
            session.markConnecting()
            session.markConnected(sessionId: 1, username: "test", initialDirectory: "/")
        }
        // Publish state once through the session observation path.
        syncPublishedState(from: session)
    }

    func setSessionIdForTesting(_ id: UInt64?) {
        sessionId = id
    }

    func simulateSessionDisconnectedForTesting(sessionId: UInt64, reason: String) {
        if let target = sessions.values.first(where: { $0.sessionId == sessionId }) {
            target.markLost(reason: reason)
            if target.id == activeSessionID {
                syncPublishedState(from: target)
            }
        } else if self.sessionId == sessionId {
            handleImplicitDisconnect(reason: reason)
        }
    }
}
#endif
