import Foundation

enum DockBridgePaths {
    static var appSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let directory = base.appendingPathComponent("DockBridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static var knownHostsFile: URL {
        appSupportDirectory.appendingPathComponent("known_hosts.json", isDirectory: false)
    }
}

enum AppSettingsKeys {
    static let connectionTimeoutSecs = "connectionTimeoutSecs"
    static let sessionHealthCheckIntervalSecs = "sessionHealthCheckIntervalSecs"
    static let transferRetryCount = "transferRetryCount"
    static let transferChunkSizeBytes = "transferChunkSizeBytes"
    static let defaultLocalPath = "defaultLocalPath"
    static let defaultLocalBookmark = "defaultLocalBookmark"
    static let confirmBeforeDelete = "confirmBeforeDelete"
    static let showHiddenFiles = "showHiddenFiles"
    static let mergeOpensshKnownHostsOnConnect = "mergeOpensshKnownHostsOnConnect"
    static let opensshKnownHostsPath = "opensshKnownHostsPath"
    static let opensshKnownHostsBookmark = "opensshKnownHostsBookmark"
}

final class AppSettingsService: @unchecked Sendable {
    static let shared = AppSettingsService()

    private let defaults: UserDefaults
    private let bookmarkService: SecurityScopedBookmarkService

    init(
        defaults: UserDefaults = .standard,
        bookmarkService: SecurityScopedBookmarkService = .shared
    ) {
        self.defaults = defaults
        self.bookmarkService = bookmarkService
        registerDefaults()
    }

    private func registerDefaults() {
        defaults.register(defaults: [
            AppSettingsKeys.connectionTimeoutSecs: Int(AppConfig.default.connectionTimeoutSecs),
            AppSettingsKeys.sessionHealthCheckIntervalSecs: Int(AppConfig.default.sessionHealthCheckIntervalSecs),
            AppSettingsKeys.transferRetryCount: Int(AppConfig.default.transferRetryCount),
            AppSettingsKeys.transferChunkSizeBytes: Int(AppConfig.default.transferChunkSizeBytes),
            AppSettingsKeys.defaultLocalPath: AppConfig.default.defaultLocalPath,
            AppSettingsKeys.confirmBeforeDelete: AppConfig.default.confirmBeforeDelete,
            AppSettingsKeys.showHiddenFiles: AppConfig.default.showHiddenFiles,
            AppSettingsKeys.mergeOpensshKnownHostsOnConnect: AppConfig.default.mergeOpensshKnownHostsOnConnect,
            AppSettingsKeys.opensshKnownHostsPath: AppConfig.default.opensshKnownHostsPath,
        ])
    }

    var appSupportDirectory: URL {
        DockBridgePaths.appSupportDirectory
    }

    func loadConfig() -> AppConfig {
        AppConfig(
            connectionTimeoutSecs: UInt64(defaults.integer(forKey: AppSettingsKeys.connectionTimeoutSecs)),
            sessionHealthCheckIntervalSecs: UInt64(
                defaults.integer(forKey: AppSettingsKeys.sessionHealthCheckIntervalSecs)
            ),
            transferRetryCount: UInt32(defaults.integer(forKey: AppSettingsKeys.transferRetryCount)),
            transferChunkSizeBytes: UInt64(
                defaults.object(forKey: AppSettingsKeys.transferChunkSizeBytes) as? Int
                    ?? Int(AppConfig.default.transferChunkSizeBytes)
            ),
            defaultLocalPath: defaults.string(forKey: AppSettingsKeys.defaultLocalPath)
                ?? AppConfig.default.defaultLocalPath,
            defaultLocalBookmark: defaults.data(forKey: AppSettingsKeys.defaultLocalBookmark),
            confirmBeforeDelete: defaults.bool(forKey: AppSettingsKeys.confirmBeforeDelete),
            showHiddenFiles: defaults.bool(forKey: AppSettingsKeys.showHiddenFiles),
            mergeOpensshKnownHostsOnConnect: defaults.object(
                forKey: AppSettingsKeys.mergeOpensshKnownHostsOnConnect
            ) as? Bool ?? AppConfig.default.mergeOpensshKnownHostsOnConnect,
            opensshKnownHostsPath: defaults.string(forKey: AppSettingsKeys.opensshKnownHostsPath)
                ?? AppConfig.default.opensshKnownHostsPath,
            opensshKnownHostsBookmark: defaults.data(forKey: AppSettingsKeys.opensshKnownHostsBookmark)
        )
    }

    func saveConfig(_ config: AppConfig) {
        defaults.set(Int(config.connectionTimeoutSecs), forKey: AppSettingsKeys.connectionTimeoutSecs)
        defaults.set(Int(config.sessionHealthCheckIntervalSecs), forKey: AppSettingsKeys.sessionHealthCheckIntervalSecs)
        defaults.set(Int(config.transferRetryCount), forKey: AppSettingsKeys.transferRetryCount)
        defaults.set(Int(config.transferChunkSizeBytes), forKey: AppSettingsKeys.transferChunkSizeBytes)
        defaults.set(config.defaultLocalPath, forKey: AppSettingsKeys.defaultLocalPath)
        defaults.set(config.defaultLocalBookmark, forKey: AppSettingsKeys.defaultLocalBookmark)
        defaults.set(config.confirmBeforeDelete, forKey: AppSettingsKeys.confirmBeforeDelete)
        defaults.set(config.showHiddenFiles, forKey: AppSettingsKeys.showHiddenFiles)
        defaults.set(config.mergeOpensshKnownHostsOnConnect, forKey: AppSettingsKeys.mergeOpensshKnownHostsOnConnect)
        defaults.set(config.opensshKnownHostsPath, forKey: AppSettingsKeys.opensshKnownHostsPath)
        defaults.set(config.opensshKnownHostsBookmark, forKey: AppSettingsKeys.opensshKnownHostsBookmark)
    }

    func resolvedOpensshKnownHostsPath(for config: AppConfig) -> String {
        if let bookmark = config.opensshKnownHostsBookmark,
           let url = try? bookmarkService.resolveBookmark(bookmark) {
            return url.standardizedFileURL.path
        }
        return NSString(string: config.opensshKnownHostsPath).expandingTildeInPath
    }

    func buildAppConfigRecord(knownHostsPath: String) -> AppConfigRecord {
        let config = loadConfig()
        return config.toRecord(
            knownHostsPath: knownHostsPath,
            opensshKnownHostsPath: resolvedOpensshKnownHostsPath(for: config)
        )
    }
}
