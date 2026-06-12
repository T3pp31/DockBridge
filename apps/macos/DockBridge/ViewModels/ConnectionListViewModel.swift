import Foundation

@MainActor
final class ConnectionListViewModel: ObservableObject {
    @Published private(set) var profiles: [ConnectionProfile] = []
    @Published var selectedProfileID: UUID?
    @Published var errorMessage: String?
    @Published var showRootWarning = false
    @Published var showEndpointChangeWarning = false
    @Published var pendingConnectProfile: ConnectionProfile?
    @Published var pendingEndpointChange: ProfileEndpointChange?

    private let store: ConnectionStore
    private let keychain: KeychainService
    private let bridge: RustBridgeService
    private let bookmarkService: SecurityScopedBookmarkService
    private var pendingEndpointChanges: [ProfileEndpointChange] = []

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
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func save(_ profile: ConnectionProfile, password: String?, passphrase: String?) {
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

        if profile.isRootUser {
            pendingConnectProfile = profile
            showRootWarning = true
        } else {
            Task { await connect(profile: profile) }
        }
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

    private func presentNextEndpointChangeWarning() {
        guard let next = pendingEndpointChanges.first else { return }
        pendingEndpointChange = next
        showEndpointChangeWarning = true
    }

    func confirmRootConnect() {
        guard let profile = pendingConnectProfile else { return }
        pendingConnectProfile = nil
        showRootWarning = false
        Task { await connect(profile: profile) }
    }

    func connect(profile: ConnectionProfile) async {
        do {
            var connectProfile = profile
            if profile.authType == .privateKey {
                guard let resolvedProfile = resolvePrivateKeyProfile(profile) else {
                    return
                }
                connectProfile = resolvedProfile
            }

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
        } catch {
            errorMessage = error.dockBridgeUserMessage
        }
    }

    private func resolvePrivateKeyProfile(_ profile: ConnectionProfile) -> ConnectionProfile? {
        if let bookmark = profile.privateKeyBookmark {
            do {
                let keyURL = try bookmarkService.resolveBookmark(bookmark)
                var resolved = profile
                resolved.privateKeyPath = keyURL.path
                return resolved
            } catch {
                errorMessage = error.localizedDescription
                return nil
            }
        }

        if let path = profile.privateKeyPath,
           FileManager.default.isReadableFile(atPath: path) {
            return profile
        }

        errorMessage = """
        秘密鍵へのアクセス権がありません。接続設定を開き、秘密鍵を再選択してください。
        """
        return nil
    }

    func disconnect() async {
        do {
            try await bridge.disconnect()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
