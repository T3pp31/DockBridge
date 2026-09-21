import AppKit
import Combine
import Foundation

@MainActor
final class ConnectionListViewModel: ObservableObject {
    @Published private(set) var profiles: [ConnectionProfile] = []
    /// Profile awaiting delete confirmation (non-nil while the dialog is shown).
    @Published var confirmDeleteProfile: ConnectionProfile? = nil
    @Published var selectedProfileID: UUID?
    @Published var searchText = ""
    @Published var errorMessage: String?
    @Published var importResultMessage: String?
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
    private let rsaKeyInspector: @Sendable (
        ConnectionProfile,
        KeychainService,
        SecurityScopedBookmarkService
    ) -> Bool?
    private var pendingEndpointChanges: [ProfileEndpointChange] = []
    private var pendingInitialTrustProfiles: [ConnectionProfile] = []
    private var pendingNewProfileTrustProfiles: [ConnectionProfile] = []
    private var rootWarningAcknowledged = false
    private var rsaWarningAcknowledged = false
    private var connectRequestGeneration = 0
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
        bridge: RustBridgeService,
        rsaKeyInspector: @escaping @Sendable (
            ConnectionProfile,
            KeychainService,
            SecurityScopedBookmarkService
        ) -> Bool? = ConnectionListViewModel.inspectRsa
    ) {
        self.store = store
        self.keychain = keychain
        self.bookmarkService = bookmarkService
        self.bridge = bridge
        self.rsaKeyInspector = rsaKeyInspector

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

    /// Imports connection profiles from an OpenSSH `~/.ssh/config` file the
    /// user selects (sandbox requires an explicit picker). Only plain `Host`
    /// aliases with a `HostName` are imported; wildcards are skipped.
    func importFromSSHConfig() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Import")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let readResult = await Task.detached(priority: .userInitiated) {
            () -> (contents: String?, error: String?) in
            do {
                return (contents: try String(contentsOf: url, encoding: .utf8), error: nil)
            } catch {
                return (contents: nil, error: error.localizedDescription)
            }
        }.value

        guard let contents = readResult.contents else {
            let format = String(localized: "Could not read SSH config file: %@")
            errorMessage = String(
                format: format,
                readResult.error ?? String(localized: "Unknown error")
            )
            return
        }
        importSSHConfig(contents: contents)
    }

    /// Parses and persists imported profiles. Kept separate from the file
    /// picker so duplicate handling and result reporting can be unit tested.
    func importSSHConfig(contents: String) {
        errorMessage = nil
        importResultMessage = nil

        let hosts = SSHConfigParser.parse(contents)
        guard !hosts.isEmpty else {
            errorMessage = String(localized: "No importable Host blocks found. Match and Include sections are not expanded.")
            return
        }

        let imported = SSHConfigParser.toProfiles(hosts)
        var updated = profiles
        var knownNames = Set(profiles.map { normalizedProfileName($0.name) })
        var added: [ConnectionProfile] = []
        var skipped: [String] = []
        for profile in imported {
            // Skip aliases that already exist (re-importing the same config
            // or an alias colliding with a manual/imported profile must not
            // duplicate). OpenSSH host aliases are compared case-insensitively.
            let normalizedName = normalizedProfileName(profile.name)
            guard !knownNames.contains(normalizedName) else {
                skipped.append(profile.name)
                continue
            }
            knownNames.insert(normalizedName)
            updated.append(profile)
            added.append(profile)
        }

        guard !added.isEmpty else {
            let format = String(localized: "No profiles were imported; all %lld host alias(es) already exist.")
            importResultMessage = String(format: format, Int64(skipped.count))
            return
        }

        do {
            try store.saveProfiles(updated)
            profiles = updated
            selectedProfileID = added.first?.id

            var resultParts = [
                String(
                    format: String(localized: "Imported %lld profile(s)."),
                    Int64(added.count)
                ),
            ]
            if let firstSkipped = skipped.first {
                resultParts.append(String(
                    format: String(localized: "Skipped %lld existing alias(es), including %@."),
                    Int64(skipped.count),
                    firstSkipped
                ))
            }
            let privateKeyCount = added.filter { $0.authType == .privateKey }.count
            if privateKeyCount > 0 {
                resultParts.append(String(
                    format: String(localized: "Open each of the %lld private-key profile(s) and use Browse… to grant file access."),
                    Int64(privateKeyCount)
                ))
            }
            importResultMessage = resultParts.joined(separator: " ")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func normalizedProfileName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func save(_ profile: ConnectionProfile, password: String?, passphrase: String?) {
        if profile.requiresPrivateKeyBookmark, !profile.hasPrivateKeyBookmark {
            errorMessage = String(localized: "Select the private key with Browse…. A security-scoped bookmark is required.")
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

    /// Asks the user to confirm before deleting a profile (and its Keychain
    /// credentials). The actual `delete(profile:)` runs only after approval.
    func requestDelete(profile: ConnectionProfile) {
        confirmDeleteProfile = profile
    }

    func delete(profile: ConnectionProfile) {
        defer { confirmDeleteProfile = nil }
        do {
            profiles = try store.delete(id: profile.id)
            let account = keychain.keychainAccount(for: profile.id, kind: "profile")
            do {

                try keychain.deletePassword(account: account)

            } catch {

                AppLogging.keychain.error("failed to delete keychain password: \(error.localizedDescription, privacy: .public)")

            }

            do {

                try keychain.deletePassphrase(account: account)

            } catch {

                AppLogging.keychain.error("failed to delete keychain passphrase: \(error.localizedDescription, privacy: .public)")

            }
            if selectedProfileID == profile.id {
                selectedProfileID = profiles.first?.id
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestConnect(profile: ConnectionProfile) {
        connectRequestGeneration &+= 1
        pendingConnectProfile = nil
        showRootWarning = false
        showRsaKeyWarning = false
        rootWarningAcknowledged = false
        rsaWarningAcknowledged = false
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
        resumePendingConnect()
    }

    private func resumePendingConnect() {
        let generation = connectRequestGeneration
        Task { await continueConnectAfterWarnings(generation: generation) }
    }

    private func continueConnectAfterWarnings(generation: Int) async {
        guard generation == connectRequestGeneration else { return }
        guard let profile = pendingConnectProfile else { return }

        if profile.isRootUser, !rootWarningAcknowledged {
            showRootWarning = true
            return
        }

        if profile.authType == .privateKey, !rsaWarningAcknowledged {
            // The private-key pre-check decrypts the key (bcrypt KDF) and reads
            // the Keychain; run it off the main actor so Connect does not
            // freeze the UI (beachball) while inspecting an encrypted key.
            let inspector = rsaKeyInspector
            let keychain = keychain
            let bookmarkService = bookmarkService
            let usesRsa = await Task.detached(priority: .userInitiated) {
                inspector(profile, keychain, bookmarkService)
            }.value
            guard generation == connectRequestGeneration,
                  pendingConnectProfile?.id == profile.id else { return }
            switch usesRsa {
            case .some(true):
                showRsaKeyWarning = true
                return
            case .some(false):
                break
            case .none:
                // Cannot determine the algorithm (e.g. an encrypted key with no
                // saved passphrase). Skip the RSA warning and proceed to
                // connect; authentication failure surfaces the passphrase
                // prompt instead of blocking the flow here.
                break
            }
        }

        guard generation == connectRequestGeneration,
              let profileToConnect = pendingConnectProfile,
              profileToConnect.id == profile.id else { return }
        clearPendingConnectState()
        Task { await connect(profile: profileToConnect) }
    }

    func cancelPendingConnect() {
        clearPendingConnectState()
    }

    private func clearPendingConnectState() {
        connectRequestGeneration &+= 1
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
        resumePendingConnect()
    }

    func confirmRsaConnect() {
        showRsaKeyWarning = false
        rsaWarningAcknowledged = true
        resumePendingConnect()
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

        // Only the empty check trims: SSH passwords/passphrases may legitimately
        // contain leading/trailing whitespace, which must be preserved both in
        // the Keychain and in the override used for the connection.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let account = keychain.keychainAccount(for: prompt.profile.id, kind: "profile")
        let profile = prompt.profile
        let kind = prompt.kind

        if saveToKeychain {
            do {
                switch kind {
                case .password:
                    try keychain.savePassword(text, account: account)
                case .passphrase:
                    try keychain.savePassphrase(text, account: account)
                }
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }

        switch kind {
        case .password:
            promptPasswordOverride = text
        case .passphrase:
            promptPassphraseOverride = text
        }

        pendingCredentialPrompt = nil
        Task { await connect(profile: profile, allowCredentialPrompt: false) }
    }

    func cancelCredentialPrompt() {
        pendingCredentialPrompt = nil
    }

    // MARK: - Connect

    func connect(profile: ConnectionProfile, allowCredentialPrompt: Bool = true) async {
        do {
            if profile.authType == .privateKey {
                guard let bookmark = profile.privateKeyBookmark else {
                    errorMessage = String(localized: "Access to the private key was denied. Open the connection settings and use Browse… to select the key again.")
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

        // A one-time override from the credential prompt always takes
        // precedence over a saved (possibly stale) Keychain value (issue #571).
        if let override = promptPasswordOverride {
            password = override
            promptPasswordOverride = nil
        }
        if let override = promptPassphraseOverride {
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
            if allowCredentialPrompt, error.isAuthenticationFailure {
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

    /// Runs off the main actor; returns `.some(true)` when the private key is
    /// RSA, `.some(false)` otherwise, and `nil` when the key cannot be
    /// inspected (missing bookmark / undecryptable key).
    private nonisolated static func inspectRsa(
        profile: ConnectionProfile,
        keychain: KeychainService,
        bookmarkService: SecurityScopedBookmarkService
    ) -> Bool? {
        guard let bookmark = profile.privateKeyBookmark else {
            // Pre-check only: without a bookmark we cannot inspect the key.
            // Treat as unknown and let the real connection flow produce the error.
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
            // Pre-check only: an undecryptable key (e.g. encrypted key with no
            // saved passphrase) returns "unknown" so the connection proceeds to
            // the passphrase prompt. No user-facing error is raised here.
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

    func saveSessionPaths(for profileID: UUID, localPath: String?, remotePath: String?) {
        guard var profile = profiles.first(where: { $0.id == profileID }) else { return }
        if let localPath {
            profile.lastLocalPath = localPath
        }
        if let remotePath {
            profile.lastRemotePath = remotePath
        }
        do {
            profiles = try store.upsert(profile)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
