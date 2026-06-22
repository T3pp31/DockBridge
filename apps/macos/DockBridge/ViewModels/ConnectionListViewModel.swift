import Foundation

@MainActor
final class ConnectionListViewModel: ObservableObject {
    @Published private(set) var profiles: [ConnectionProfile] = []
    @Published var selectedProfileID: UUID?
    @Published var errorMessage: String?
    @Published var showRootWarning = false
    @Published var showRsaKeyWarning = false
    @Published var showEndpointChangeWarning = false
    @Published var showInitialTrustConfirmation = false
    @Published var showNewProfileTrustConfirmation = false
    @Published var pendingConnectProfile: ConnectionProfile?
    @Published var pendingEndpointChange: ProfileEndpointChange?

    private let store: ConnectionStore
    private let keychain: KeychainService
    private let bridge: RustBridgeService
    private let bookmarkService: SecurityScopedBookmarkService
    private var pendingEndpointChanges: [ProfileEndpointChange] = []
    private var pendingInitialTrustProfiles: [ConnectionProfile] = []
    private var pendingNewProfileTrustProfiles: [ConnectionProfile] = []
    private var rootWarningAcknowledged = false
    private var rsaWarningAcknowledged = false

    var isConnected: Bool { bridge.isConnected }
    var connectionStatus: ConnectionStatus { bridge.connectionStatus }
    var connectedProfileID: UUID? { bridge.connectedProfileID }

    init(
        store: ConnectionStore = .shared,
        keychain: KeychainService = .shared,
        bookmarkService: SecurityScopedBookmarkService = .shared,
        bridge: RustBridgeService
    ) {
        self.store = store
        self.keychain = keychain
        self.bookmarkService = bookmarkService
        self.bridge = bridge
    }

    func load() {
        do {
            let result = try store.loadProfilesWithEndpointCheck()
            profiles = result.profiles
            if selectedProfileID == nil {
                selectedProfileID = profiles.first?.id
            }
            if !result.endpointChanges.isEmpty {
                pendingEndpointChanges = result.endpointChanges
                presentNextEndpointChangeWarning()
            } else if !result.pendingInitialTrust.isEmpty {
                pendingInitialTrustProfiles = result.pendingInitialTrust
                showInitialTrustConfirmation = true
            } else if !result.pendingNewProfileTrust.isEmpty {
                pendingNewProfileTrustProfiles = result.pendingNewProfileTrust
                showNewProfileTrustConfirmation = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func save(_ profile: ConnectionProfile, password: String?, passphrase: String?) {
        if profile.requiresPrivateKeyBookmark, !profile.hasPrivateKeyBookmark {
            errorMessage = """
            秘密鍵は「Browse…」から選択してください。セキュリティスコープ付きブックマークが必要です。
            """
            return
        }

        do {
            profiles = try store.upsert(profile)
            selectedProfileID = profile.id

            let account = keychain.keychainAccount(for: profile.id, kind: "profile")
            switch profile.authType {
            case .password:
                try keychain.deletePassphrase(account: account)
                if let password, !password.isEmpty {
                    try keychain.savePassword(password, account: account)
                } else {
                    try keychain.deletePassword(account: account)
                }
            case .privateKey:
                try keychain.deletePassword(account: account)
                if let passphrase, !passphrase.isEmpty {
                    try keychain.savePassphrase(passphrase, account: account)
                } else {
                    try keychain.deletePassphrase(account: account)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(profile: ConnectionProfile) {
        do {
            profiles = try store.delete(id: profile.id)
            let account = keychain.keychainAccount(for: profile.id, kind: "profile")
            try? keychain.deletePassword(account: account)
            try? keychain.deletePassphrase(account: account)
            if selectedProfileID == profile.id {
                selectedProfileID = profiles.first?.id
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestConnect(profile: ConnectionProfile) {
        do {
            if let change = try store.endpointChange(for: profile) {
                pendingConnectProfile = profile
                pendingEndpointChange = change
                showEndpointChangeWarning = true
                return
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        pendingConnectProfile = profile
        rootWarningAcknowledged = false
        rsaWarningAcknowledged = false
        continueConnectAfterWarnings()
    }

    private func continueConnectAfterWarnings() {
        guard let profile = pendingConnectProfile else { return }

        if profile.isRootUser, !rootWarningAcknowledged {
            showRootWarning = true
            return
        }

        if profile.authType == .privateKey, !rsaWarningAcknowledged {
            switch profileUsesRsaPrivateKey(profile) {
            case .some(true):
                showRsaKeyWarning = true
                return
            case .some(false):
                break
            case .none:
                return
            }
        }

        guard let profileToConnect = pendingConnectProfile else { return }
        clearPendingConnectState()
        Task { await connect(profile: profileToConnect) }
    }

    func cancelPendingConnect() {
        clearPendingConnectState()
    }

    private func clearPendingConnectState() {
        pendingConnectProfile = nil
        showRootWarning = false
        showRsaKeyWarning = false
        rootWarningAcknowledged = false
        rsaWarningAcknowledged = false
    }

    func acceptEndpointChange() {
        guard let change = pendingEndpointChange else { return }

        do {
            try store.acceptEndpointChange(change)
            pendingEndpointChanges.removeAll { $0.id == change.id }
            pendingEndpointChange = nil

            if pendingEndpointChanges.isEmpty {
                showEndpointChangeWarning = false
            } else {
                presentNextEndpointChangeWarning()
                return
            }

            if let profile = pendingConnectProfile {
                pendingConnectProfile = nil
                requestConnect(profile: profile)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restoreTrustedEndpoint() {
        guard let change = pendingEndpointChange else { return }

        do {
            profiles = try store.restoreTrustedEndpoint(for: change)
            pendingEndpointChanges.removeAll { $0.id == change.id }
            pendingEndpointChange = nil
            pendingConnectProfile = nil

            if pendingEndpointChanges.isEmpty {
                showEndpointChangeWarning = false
            } else {
                presentNextEndpointChangeWarning()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func confirmInitialTrust() {
        do {
            try store.seedInitialTrust(for: pendingInitialTrustProfiles)
            pendingInitialTrustProfiles = []
            showInitialTrustConfirmation = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func declineInitialTrust() {
        pendingInitialTrustProfiles = []
        showInitialTrustConfirmation = false
    }

    func confirmNewProfileTrust() {
        do {
            try store.trustProfiles(pendingNewProfileTrustProfiles)
            pendingNewProfileTrustProfiles = []
            showNewProfileTrustConfirmation = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func declineNewProfileTrust() {
        pendingNewProfileTrustProfiles = []
        showNewProfileTrustConfirmation = false
    }

    private func presentNextEndpointChangeWarning() {
        guard let next = pendingEndpointChanges.first else { return }
        pendingEndpointChange = next
        showEndpointChangeWarning = true
    }

    func confirmRootConnect() {
        showRootWarning = false
        rootWarningAcknowledged = true
        continueConnectAfterWarnings()
    }

    func confirmRsaConnect() {
        showRsaKeyWarning = false
        rsaWarningAcknowledged = true
        continueConnectAfterWarnings()
    }

    func connect(profile: ConnectionProfile) async {
        do {
            if profile.authType == .privateKey {
                guard let bookmark = profile.privateKeyBookmark else {
                    errorMessage = """
                    秘密鍵へのアクセス権がありません。接続設定を開き、「Browse…」から秘密鍵を再選択してください。
                    """
                    return
                }

                try await bookmarkService.withAccess(to: bookmark) { keyURL in
                    var connectProfile = profile
                    connectProfile.privateKeyPath = keyURL.path
                    try await performConnect(profile: profile, connectProfile: connectProfile)
                }
            } else {
                try await performConnect(profile: profile, connectProfile: profile)
            }
        } catch {
            errorMessage = error.dockBridgeUserMessage
        }
    }

    private func performConnect(profile: ConnectionProfile, connectProfile: ConnectionProfile) async throws {
        let account = keychain.keychainAccount(for: profile.id, kind: "profile")
        var password = connectProfile.authType == .password
            ? try keychain.loadPassword(account: account)
            : nil
        var passphrase = connectProfile.authType == .privateKey
            ? try keychain.loadPassphrase(account: account)
            : nil
        defer {
            SensitiveString.clear(&password)
            SensitiveString.clear(&passphrase)
        }

        try await bridge.connect(profile: connectProfile, password: password, passphrase: passphrase)

        var updated = profile
        updated.lastConnectedAt = Date()
        profiles = try store.upsert(updated)
        selectedProfileID = updated.id
    }

    private func profileUsesRsaPrivateKey(_ profile: ConnectionProfile) -> Bool? {
        guard let bookmark = profile.privateKeyBookmark else {
            errorMessage = """
            秘密鍵へのアクセス権がありません。接続設定を開き、「Browse…」から秘密鍵を再選択してください。
            """
            return nil
        }

        let account = keychain.keychainAccount(for: profile.id, kind: "profile")
        var passphrase: String? = try? keychain.loadPassphrase(account: account)
        defer {
            SensitiveString.clear(&passphrase)
        }

        do {
            return try bookmarkService.withAccess(to: bookmark) { keyURL in
                let algorithm = try inspectPrivateKeyAlgorithm(keyPath: keyURL.path, passphrase: passphrase)
                return algorithm == .rsa
            }
        } catch {
            errorMessage = error.dockBridgeUserMessage
            return nil
        }
    }

    func disconnect() async {
        do {
            try await bridge.disconnect()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
