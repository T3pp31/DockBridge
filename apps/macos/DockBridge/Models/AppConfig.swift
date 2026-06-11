import Foundation

struct AppConfig: Codable, Equatable, Sendable {
    var connectionTimeoutSecs: UInt64
    var sessionHealthCheckIntervalSecs: UInt64
    var transferRetryCount: UInt32
    var transferChunkSizeBytes: UInt64
    var defaultLocalPath: String
    var confirmBeforeDelete: Bool
    var showHiddenFiles: Bool

    static let `default` = AppConfig(
        connectionTimeoutSecs: 30,
        sessionHealthCheckIntervalSecs: 10,
        transferRetryCount: 3,
        transferChunkSizeBytes: 262_144,
        defaultLocalPath: FileManager.default.homeDirectoryForCurrentUser.path,
        confirmBeforeDelete: true,
        showHiddenFiles: false
    )

    func toRecord(knownHostsPath: String) -> AppConfigRecord {
        AppConfigRecord(
            connectionTimeoutSecs: connectionTimeoutSecs,
            sessionHealthCheckIntervalSecs: sessionHealthCheckIntervalSecs,
            transferRetryCount: transferRetryCount,
            transferChunkSizeBytes: transferChunkSizeBytes,
            knownHostsPath: knownHostsPath
        )
    }
}
