import Combine
import Foundation

@MainActor
final class RustBridgeService: NSObject, RemoteBridging, ObservableObject, HostKeyHandler, ConnectionEventHandler {
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
    private let settings: AppSettingsService
    private let hostKeyStore: HostKeyStore
    private let bookmarkService: SecurityScopedBookmarkService
    private var sessionCancellables: [UUID: AnyCancellable] = [:]
    /// Insertion order of open sessions; used to pick a fallback active
    /// session without depending on Rust-side sessionId reuse.
    private var sessionOrder: [UUID] = []

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
        // One DockBridgeClient owns the Rust-side session registry. Replacing
        // it while sessions are open would orphan every existing session.
        guard client == nil else { return }
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
        // Fall back to the most recently opened session for API compat.
        return sessionOrder.compactMap { sessions[$0] }.last
    }

    /// All sessions in creation order (oldest first).
    var allSessions: [RemoteSession] {
        sessionOrder.compactMap { sessions[$0] }
    }

    /// Returns the session with the given id, if open.
    func session(id: UUID) -> RemoteSession? {
        sessions[id]
    }

    /// Switches which session is surfaced via the published properties.
    func setActiveSession(_ session: RemoteSession) {
        guard sessions[session.id] === session else { return }
        activeSessionID = session.id
        syncPublishedState(from: session)
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
        guard let session = activeSession else { return }
        try await disconnect(session: session)
    }

    /// Disconnects one session without affecting other open sessions.
    func disconnect(session: RemoteSession) async throws {
        guard sessions[session.id] === session else { return }
        guard !session.isConnecting else {
            throw DockBridgeError.Other(message: String(localized: "A connection is still in progress."))
        }

        var disconnectError: Error?
        if let client, let rustSessionId = session.sessionId {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try client.disconnect(sessionId: rustSessionId)
                }.value
            } catch {
                disconnectError = error
            }
        }
        removeSession(session)
        if let disconnectError {
            throw disconnectError
        }
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
        guard let client, let rustSessionId = activeSession?.sessionId, isConnected else { return nil }
        for candidate in Self.homeDirectoryCandidates(for: username) {
            let isDirectory = await Task.detached(priority: .userInitiated) {
                (try? client.stat(
                    sessionId: rustSessionId,
                    path: candidate,
                    followSymlinks: true
                ))?.isDirectory == true
            }.value
            if isDirectory {
                return candidate
            }
        }
        return nil
    }

    func upload(
        localPath: String,
        remoteDirectory: String,
        overwritePolicy: TransferOverwritePolicy
    ) async throws {
        let rustOverwritePolicy = overwritePolicy.rustRecord
        try await runOnBridge { client, sessionId in
            try client.uploadEntry(
                sessionId: sessionId,
                localPath: localPath,
                remoteDirectory: remoteDirectory,
                overwritePolicy: rustOverwritePolicy
            )
        }
        await refreshTransferQueue()
    }

    func download(
        remotePath: String,
        localDirectory: String,
        overwritePolicy: TransferOverwritePolicy
    ) async throws {
        let rustOverwritePolicy = overwritePolicy.rustRecord
        try await runOnBridge { client, sessionId in
            try client.downloadEntry(
                sessionId: sessionId,
                remotePath: remotePath,
                localDirectory: localDirectory,
                overwritePolicy: rustOverwritePolicy
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
        return await Task.detached(priority: .userInitiated) {
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
        await Task.detached(priority: .userInitiated) {
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
            handleSessionDisconnected(sessionId: sessionId, reason: reason)
        }
    }

    private func handleSessionDisconnected(sessionId: UInt64, reason: String) {
        guard let target = sessions.values.first(where: { $0.sessionId == sessionId }) else {
            return
        }
        target.markLost(reason: reason)
        if target.id == activeSessionID {
            syncPublishedState(from: target)
        }
    }

    private func resetPublishedSessionFields() {
        initialRemoteDirectory = nil
        connectedUsername = nil
        connectionStatus = .disconnected
        connectedProfileID = nil
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
            let isDirectory = await Task.detached(priority: .userInitiated) {
                (try? client.stat(
                    sessionId: sessionId,
                    path: candidate,
                    followSymlinks: true
                ))?.isDirectory == true
            }.value
            if isDirectory {
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
        guard
            let client,
            let targetSession = activeSession,
            let rustSessionId = targetSession.sessionId
        else {
            throw DockBridgeError.Other(message: String(localized: "Not connected to a remote host."))
        }

        do {
            return try await Task.detached(priority: .userInitiated) {
                try operation(client, rustSessionId)
            }.value
        } catch {
            if error.isConnectionLost {
                let reason = error.dockBridgeUserMessage
                if sessions[targetSession.id] === targetSession,
                   targetSession.sessionId == rustSessionId {
                    targetSession.markLost(reason: reason)
                    if activeSessionID == targetSession.id {
                        syncPublishedState(from: targetSession)
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
        guard !sessions.values.contains(where: \.isConnecting) else {
            throw DockBridgeError.Other(message: String(localized: "A connection is already in progress."))
        }

        try prepareClient()
        guard let client else {
            throw DockBridgeError.Other(message: String(localized: "Rust client is not initialized."))
        }

        let session = RemoteSession(
            profileID: profile.id,
            endpointLabel: profile.endpointLabel
        )
        sessions[session.id] = session
        sessionOrder.append(session.id)
        activeSessionID = session.id
        observe(session)
        session.markConnecting()
        syncPublishedState(from: session)

        var password = password
        var passphrase = passphrase
        defer {
            SensitiveString.clear(&password)
            SensitiveString.clear(&passphrase)
        }

        var newSessionIdForCatch: UInt64?
        do {
            var record = profile.toRecord(password: password, passphrase: passphrase)
            defer { record.clearCredentials() }

            let newSessionId = try await Task.detached(priority: .userInitiated) { [record] in
                var detachedRecord = record
                defer { detachedRecord.clearCredentials() }
                return try client.connect(profile: detachedRecord)
            }.value
            newSessionIdForCatch = newSessionId

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
            newSessionIdForCatch = nil
            if activeSessionID == session.id {
                syncPublishedState(from: session)
            }
            return session
        } catch {
            if let pendingSessionId = newSessionIdForCatch {
                _ = try? await Task.detached(priority: .userInitiated) {
                    try client.disconnect(sessionId: pendingSessionId)
                }.value
            }
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
        sessionOrder.removeAll { $0 == session.id }
        sessionCancellables.removeValue(forKey: session.id)
        if activeSessionID == session.id {
            activeSessionID = nil
        }
        if let next = allSessions.last {
            setActiveSession(next)
        } else {
            resetPublishedSessionFields()
            client = nil
        }
    }

    /// Copies the given session's state into the legacy published properties
    /// that existing views/ViewModels observe.
    private func syncPublishedState(from session: RemoteSession) {
        connectedProfileID = session.isConnected || session.isConnecting ? session.profileID : nil
        connectionStatus = session.connectionStatus
        lastDisconnectReason = session.lastDisconnectReason
        initialRemoteDirectory = session.initialRemoteDirectory
        connectedUsername = session.connectedUsername
    }

    private func refreshActiveSessionState() {
        if let session = activeSession {
            syncPublishedState(from: session)
        }
    }
}

private extension TransferOverwritePolicy {
    var rustRecord: TransferOverwritePolicyRecord {
        switch self {
        case .replace, .ask:
            return .replace
        case .failIfExists:
            return .failIfExists
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
            sessions.removeAll()
            sessionOrder.removeAll()
            sessionCancellables.removeAll()
            activeSessionID = nil
            client = nil
            connectionStatus = status
            connectedProfileID = nil
            initialRemoteDirectory = nil
            connectedUsername = nil
            return
        }
        let session = RemoteSession(profileID: profileID, endpointLabel: "test@example.com")
        sessions[session.id] = session
        sessionOrder.append(session.id)
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
        guard let session = activeSession else { return }
        if let id {
            session.markConnected(
                sessionId: id,
                username: session.connectedUsername ?? "test",
                initialDirectory: session.initialRemoteDirectory ?? "/"
            )
        } else {
            session.markDisconnected()
        }
        syncPublishedState(from: session)
    }

    func simulateSessionDisconnectedForTesting(sessionId: UInt64, reason: String) {
        // Synchronous so tests can assert immediately after the call.
        handleSessionDisconnected(sessionId: sessionId, reason: reason)
    }
}
#endif
