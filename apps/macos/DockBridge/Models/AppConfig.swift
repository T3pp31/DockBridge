import Foundation

struct AppConfig: Codable, Equatable, Sendable {
    var connectionTimeoutSecs: UInt64
    var sessionHealthCheckIntervalSecs: UInt64
    var transferRetryCount: UInt32
    var transferChunkSizeBytes: UInt64
    var transferDownloadPipelineDepth: UInt64
    var transferUploadPipelineDepth: UInt64 = 64
    var sshInactivityTimeoutSecs: UInt64?
    var sshKeepaliveIntervalSecs: UInt64
    var defaultLocalPath: String
    var defaultLocalBookmark: Data?
    var confirmBeforeDelete: Bool
    var showHiddenFiles: Bool
    var mergeOpensshKnownHostsOnConnect: Bool
    var opensshKnownHostsPath: String
    var opensshKnownHostsBookmark: Data?
    var knownHostsStrictMode: Bool
    var failConnectOnOpensshMergeError: Bool
    var directoryWalkMaxFiles: UInt64
    var directoryWalkMaxDepth: UInt32
    var directoryWalkMaxTotalBytes: UInt64
    var transferOverwritePolicy: TransferOverwritePolicy = .replace
    var notifyWhenTransfersFinish: Bool = true
    var playTransferNotificationSound: Bool = true

    static let `default` = AppConfig(
        connectionTimeoutSecs: 30,
        sessionHealthCheckIntervalSecs: 10,
        transferRetryCount: 3,
        transferChunkSizeBytes: 262_144,
        transferDownloadPipelineDepth: 64,
        transferUploadPipelineDepth: 64,
        sshInactivityTimeoutSecs: 600,
        sshKeepaliveIntervalSecs: 30,
        defaultLocalPath: DefaultLocalPathResolver.containerHomeURL().path,
        defaultLocalBookmark: nil,
        confirmBeforeDelete: true,
        showHiddenFiles: false,
        mergeOpensshKnownHostsOnConnect: true,
        opensshKnownHostsPath: "~/.ssh/known_hosts",
        opensshKnownHostsBookmark: nil,
        knownHostsStrictMode: true,
        failConnectOnOpensshMergeError: true,
        directoryWalkMaxFiles: 100_000,
        directoryWalkMaxDepth: 64,
        directoryWalkMaxTotalBytes: 107_374_182_400,
        transferOverwritePolicy: .replace,
        notifyWhenTransfersFinish: true,
        playTransferNotificationSound: true
    )

    /// Builds the UniFFI config record. The overwrite policy is passed per
    /// transfer after the Swift UI resolves the `ask` behavior.
    func toRecord(knownHostsPath: String, opensshKnownHostsPath: String) -> AppConfigRecord {
        AppConfigRecord(
            connectionTimeoutSecs: connectionTimeoutSecs,
            sessionHealthCheckIntervalSecs: sessionHealthCheckIntervalSecs,
            transferRetryCount: transferRetryCount,
            transferChunkSizeBytes: transferChunkSizeBytes,
            transferDownloadPipelineDepth: transferDownloadPipelineDepth,
            transferUploadPipelineDepth: transferUploadPipelineDepth,
            sshInactivityTimeoutSecs: sshInactivityTimeoutSecs,
            sshKeepaliveIntervalSecs: sshKeepaliveIntervalSecs,
            knownHostsPath: knownHostsPath,
            opensshKnownHostsPath: opensshKnownHostsPath,
            mergeOpensshKnownHostsOnConnect: mergeOpensshKnownHostsOnConnect,
            knownHostsStrictMode: knownHostsStrictMode,
            failConnectOnOpensshMergeError: failConnectOnOpensshMergeError,
            directoryWalkMaxFiles: directoryWalkMaxFiles,
            directoryWalkMaxDepth: directoryWalkMaxDepth,
            directoryWalkMaxTotalBytes: directoryWalkMaxTotalBytes
        )
    }
}
