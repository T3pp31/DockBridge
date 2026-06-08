import Foundation

@MainActor
final class ConnectionListViewModel: ObservableObject {
    @Published private(set) var profiles: [ConnectionProfile] = []
    @Published var selectedProfileID: UUID?
    @Published var errorMessage: String?
    @Published var showRootWarning = false
    @Published var pendingConnectProfile: ConnectionProfile?

    private let store: ConnectionStore
    private let keychain: KeychainService
    private let bridge: RustBridgeService

    var isConnected: Bool { bridge.isConnected }

    init(
        store: ConnectionStore = .shared,
        keychain: KeychainService = .shared,
        bridge: RustBridgeService
    ) {
        self.store = store
        self.keychain = keychain
        self.bridge = bridge
    }

    func load() {
        do {
            profiles = try store.loadProfiles()
            if selectedProfileID == nil {
                selectedProfileID = profiles.first?.id
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
            if let password, !password.isEmpty {
                try keychain.savePassword(password, account: account)
            }
            if let passphrase, !passphrase.isEmpty {
                try keychain.savePassphrase(passphrase, account: account)
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
        if profile.isRootUser {
            pendingConnectProfile = profile
            showRootWarning = true
        } else {
            Task { await connect(profile: profile) }
        }
    }

    func confirmRootConnect() {
        guard let profile = pendingConnectProfile else { return }
        pendingConnectProfile = nil
        showRootWarning = false
        Task { await connect(profile: profile) }
    }

    func connect(profile: ConnectionProfile) async {
        do {
            let account = keychain.keychainAccount(for: profile.id, kind: "profile")
            let password = profile.authType == .password
                ? try keychain.loadPassword(account: account)
                : nil
            let passphrase = profile.authType == .privateKey
                ? try keychain.loadPassphrase(account: account)
                : nil

            try await bridge.connect(profile: profile, password: password, passphrase: passphrase)

            var updated = profile
            updated.lastConnectedAt = Date()
            profiles = try store.upsert(updated)
            selectedProfileID = updated.id
        } catch {
            errorMessage = error.dockBridgeUserMessage
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
