import Foundation

struct AppConfig: Codable, Equatable, Sendable {
    var connectionTimeoutSecs: UInt64
    var sessionHealthCheckIntervalSecs: UInt64
    var transferRetryCount: UInt32
    var transferChunkSizeBytes: UInt64
    var defaultLocalPath: String
    var defaultLocalBookmark: Data?
    var confirmBeforeDelete: Bool
    var showHiddenFiles: Bool
    var mergeOpensshKnownHostsOnConnect: Bool
    var opensshKnownHostsPath: String
    var opensshKnownHostsBookmark: Data?

    static let `default` = AppConfig(
        connectionTimeoutSecs: 30,
        sessionHealthCheckIntervalSecs: 10,
        transferRetryCount: 3,
        transferChunkSizeBytes: 262_144,
        defaultLocalPath: DefaultLocalPathResolver.containerHomeURL().path,
        defaultLocalBookmark: nil,
        confirmBeforeDelete: true,
        showHiddenFiles: false,
        mergeOpensshKnownHostsOnConnect: true,
        opensshKnownHostsPath: "~/.ssh/known_hosts",
        opensshKnownHostsBookmark: nil
    )

    func toRecord(knownHostsPath: String, opensshKnownHostsPath: String) -> AppConfigRecord {
        AppConfigRecord(
            connectionTimeoutSecs: connectionTimeoutSecs,
            sessionHealthCheckIntervalSecs: sessionHealthCheckIntervalSecs,
            transferRetryCount: transferRetryCount,
            transferChunkSizeBytes: transferChunkSizeBytes,
            knownHostsPath: knownHostsPath,
            opensshKnownHostsPath: opensshKnownHostsPath,
            mergeOpensshKnownHostsOnConnect: mergeOpensshKnownHostsOnConnect,
            knownHostsStrictMode: false,
            failConnectOnOpensshMergeError: false
        )
    }
}
