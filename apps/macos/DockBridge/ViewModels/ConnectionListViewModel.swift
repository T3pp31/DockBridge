import Combine
import Foundation

@MainActor
final class ConnectionListViewModel: ObservableObject {
    @Published private(set) var profiles: [ConnectionProfile] = []
    @Published var selectedProfileID: UUID?
    @Published var searchText = ""
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
    private var cancellables = Set<AnyCancellable>()

    var isConnected: Bool { bridge.isConnected }
    var connectionStatus: ConnectionStatus { bridge.connectionStatus }
    var connectedProfileID: UUID? { bridge.connectedProfileID }

    var filteredProfiles: [ConnectionProfile] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return profiles }
        return profiles.filter { profile in
            profile.displayName.localizedCaseInsensitiveContains(query)
                || profile.endpointLabel.localizedCaseInsensitiveContains(query)
                || profile.host.localizedCaseInsensitiveContains(query)
        }
    }

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

        bridge.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
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
            Select the private key with Browse…. A security-scoped bookmark is required.
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
                if let password {
                    if password.isEmpty {
                        try keychain.deletePassword(account: account)
                    } else {
                        try keychain.savePassword(password, account: account)
                    }
                }
            case .privateKey:
                try keychain.deletePassword(account: account)
                if let passphrase {
                    if passphrase.isEmpty {
                        try keychain.deletePassphrase(account: account)
                    } else {
                        try keychain.savePassphrase(passphrase, account: account)
                    }
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

    // MARK: - Interactive credential prompt (Issue #213)

    enum CredentialPromptKind {
        case password
        case passphrase
    }

    @Published var pendingCredentialPrompt: (profile: ConnectionProfile, kind: CredentialPromptKind)?

    /// One-time credential supplied by the prompt for the next connect attempt.
    private var promptPasswordOverride: String?
    private var promptPassphraseOverride: String?

    func beginPasswordPrompt(for profile: ConnectionProfile) {
        pendingCredentialPrompt = (profile, .password)
    }

    func beginPassphrasePrompt(for profile: ConnectionProfile) {
        pendingCredentialPrompt = (profile, .passphrase)
    }

    func confirmCredentialPrompt(text: String, saveToKeychain: Bool) {
        guard let prompt = pendingCredentialPrompt else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = keychain.keychainAccount(for: prompt.profile.id, kind: "profile")

        switch prompt.kind {
        case .password:
            promptPasswordOverride = trimmed.isEmpty ? nil : trimmed
            if saveToKeychain, !trimmed.isEmpty {
                try? keychain.savePassword(trimmed, account: account)
            }
        case .passphrase:
            promptPassphraseOverride = trimmed.isEmpty ? nil : trimmed
            if saveToKeychain, !trimmed.isEmpty {
                try? keychain.savePassphrase(trimmed, account: account)
            }
        }

        pendingCredentialPrompt = nil
        Task { await connect(profile: prompt.profile, allowCredentialPrompt: false) }
    }

    func cancelCredentialPrompt() {
        pendingCredentialPrompt = nil
    }

    // MARK: - Connect

    func connect(profile: ConnectionProfile, allowCredentialPrompt: Bool = true) async {
        do {
            if profile.authType == .privateKey {
                guard let bookmark = profile.privateKeyBookmark else {
                    errorMessage = """
                    Access to the private key was denied. Open the connection settings and use Browse… to select the key again.
                    """
                    return
                }

                try await bookmarkService.withAccess(to: bookmark) { keyURL in
                    var connectProfile = profile
                    connectProfile.privateKeyPath = keyURL.path
                    try await performConnect(
                        profile: profile,
                        connectProfile: connectProfile,
                        allowCredentialPrompt: allowCredentialPrompt
                    )
                }
            } else {
                try await performConnect(
                    profile: profile,
                    connectProfile: profile,
                    allowCredentialPrompt: allowCredentialPrompt
                )
            }
        } catch {
            if pendingCredentialPrompt == nil {
                errorMessage = error.dockBridgeUserMessage
            }
        }
    }

    private func performConnect(
        profile: ConnectionProfile,
        connectProfile: ConnectionProfile,
        allowCredentialPrompt: Bool = true
    ) async throws {
        let account = keychain.keychainAccount(for: profile.id, kind: "profile")
        var password = connectProfile.authType == .password
            ? try keychain.loadPassword(account: account)
            : nil
        var passphrase = connectProfile.authType == .privateKey
            ? try keychain.loadPassphrase(account: account)
            : nil

        if password == nil, let override = promptPasswordOverride {
            password = override
            promptPasswordOverride = nil
        }
        if passphrase == nil, let override = promptPassphraseOverride {
            passphrase = override
            promptPassphraseOverride = nil
        }

        defer {
            SensitiveString.clear(&password)
            SensitiveString.clear(&passphrase)
        }

        if allowCredentialPrompt, connectProfile.authType == .password,
           password == nil || password?.isEmpty == true {
            beginPasswordPrompt(for: profile)
            return
        }

        do {
            try await bridge.connect(profile: connectProfile, password: password, passphrase: passphrase)
        } catch {
            if allowCredentialPrompt, Self.isAuthenticationError(error) {
                if connectProfile.authType == .password {
                    beginPasswordPrompt(for: profile)
                } else if connectProfile.authType == .privateKey {
                    beginPassphrasePrompt(for: profile)
                }
            }
            throw error
        }

        var updated = profile
        updated.lastConnectedAt = Date()
        profiles = try store.upsert(updated)
        selectedProfileID = updated.id
    }

    private static func isAuthenticationError(_ error: Error) -> Bool {
        let message = error.dockBridgeUserMessage.lowercased()
        return message.contains("username and password")
            || message.contains("authentication")
            || message.contains("auth failed")
    }

    private func profileUsesRsaPrivateKey(_ profile: ConnectionProfile) -> Bool? {
        guard let bookmark = profile.privateKeyBookmark else {
            errorMessage = """
            Access to the private key was denied. Open the connection settings and use Browse… to select the key again.
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

    /// One-click reconnect to the selected (or last-connected) profile
    /// (Issue #223). Safe to call while connected: it disconnects first.
    func reconnect() {
        guard let profile = profiles.first(where: { $0.id == selectedProfileID })
            ?? profiles.first(where: { $0.id == connectedProfileID })
            ?? profiles.first
        else { return }
        Task {
            if connectionStatus.isConnected || connectionStatus.isConnecting {
                await disconnect()
            }
            await connect(profile: profile)
        }
    }
}
