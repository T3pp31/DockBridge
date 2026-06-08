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
    static let transferRetryCount = "transferRetryCount"
    static let defaultLocalPath = "defaultLocalPath"
    static let confirmBeforeDelete = "confirmBeforeDelete"
    static let showHiddenFiles = "showHiddenFiles"
}

final class AppSettingsService: @unchecked Sendable {
    static let shared = AppSettingsService()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        registerDefaults()
    }

    private func registerDefaults() {
        defaults.register(defaults: [
            AppSettingsKeys.connectionTimeoutSecs: Int(AppConfig.default.connectionTimeoutSecs),
            AppSettingsKeys.transferRetryCount: Int(AppConfig.default.transferRetryCount),
            AppSettingsKeys.defaultLocalPath: AppConfig.default.defaultLocalPath,
            AppSettingsKeys.confirmBeforeDelete: AppConfig.default.confirmBeforeDelete,
            AppSettingsKeys.showHiddenFiles: AppConfig.default.showHiddenFiles,
        ])
    }

    var appSupportDirectory: URL {
        DockBridgePaths.appSupportDirectory
    }

    func loadConfig() -> AppConfig {
        AppConfig(
            connectionTimeoutSecs: UInt64(defaults.integer(forKey: AppSettingsKeys.connectionTimeoutSecs)),
            transferRetryCount: UInt32(defaults.integer(forKey: AppSettingsKeys.transferRetryCount)),
            defaultLocalPath: defaults.string(forKey: AppSettingsKeys.defaultLocalPath)
                ?? AppConfig.default.defaultLocalPath,
            confirmBeforeDelete: defaults.bool(forKey: AppSettingsKeys.confirmBeforeDelete),
            showHiddenFiles: defaults.bool(forKey: AppSettingsKeys.showHiddenFiles)
        )
    }

    func saveConfig(_ config: AppConfig) {
        defaults.set(Int(config.connectionTimeoutSecs), forKey: AppSettingsKeys.connectionTimeoutSecs)
        defaults.set(Int(config.transferRetryCount), forKey: AppSettingsKeys.transferRetryCount)
        defaults.set(config.defaultLocalPath, forKey: AppSettingsKeys.defaultLocalPath)
        defaults.set(config.confirmBeforeDelete, forKey: AppSettingsKeys.confirmBeforeDelete)
        defaults.set(config.showHiddenFiles, forKey: AppSettingsKeys.showHiddenFiles)
    }

    func buildAppConfigRecord() -> AppConfigRecord {
        let config = loadConfig()
        return config.toRecord(knownHostsPath: DockBridgePaths.knownHostsFile.path)
    }
}
