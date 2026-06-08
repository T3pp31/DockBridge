import Foundation

struct AppConfig: Codable, Equatable, Sendable {
    var connectionTimeoutSecs: UInt64
    var transferRetryCount: UInt32
    var defaultLocalPath: String
    var confirmBeforeDelete: Bool
    var showHiddenFiles: Bool

    static let `default` = AppConfig(
        connectionTimeoutSecs: 30,
        transferRetryCount: 3,
        defaultLocalPath: FileManager.default.homeDirectoryForCurrentUser.path,
        confirmBeforeDelete: true,
        showHiddenFiles: false
    )

    func toRecord(knownHostsPath: String) -> AppConfigRecord {
        AppConfigRecord(
            connectionTimeoutSecs: connectionTimeoutSecs,
            transferRetryCount: transferRetryCount,
            knownHostsPath: knownHostsPath
        )
    }
}
