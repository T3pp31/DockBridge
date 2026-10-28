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

    private enum CodingKeys: String, CodingKey {
        case connectionTimeoutSecs
        case sessionHealthCheckIntervalSecs
        case transferRetryCount
        case transferChunkSizeBytes
        case transferDownloadPipelineDepth
        case transferUploadPipelineDepth
        case sshInactivityTimeoutSecs
        case sshKeepaliveIntervalSecs
        case defaultLocalPath
        case defaultLocalBookmark
        case confirmBeforeDelete
        case showHiddenFiles
        case mergeOpensshKnownHostsOnConnect
        case opensshKnownHostsPath
        case opensshKnownHostsBookmark
        case knownHostsStrictMode
        case failConnectOnOpensshMergeError
        case directoryWalkMaxFiles
        case directoryWalkMaxDepth
        case directoryWalkMaxTotalBytes
        case transferOverwritePolicy
        case notifyWhenTransfersFinish
        case playTransferNotificationSound
    }

    static let `default` = AppConfig()

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

// Keep custom decoding outside the struct so its memberwise initializer
// remains available to existing settings callers.
extension AppConfig {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.default
        connectionTimeoutSecs = try container.decodeIfPresent(UInt64.self, forKey: .connectionTimeoutSecs) ?? defaults.connectionTimeoutSecs
        sessionHealthCheckIntervalSecs = try container.decodeIfPresent(UInt64.self, forKey: .sessionHealthCheckIntervalSecs) ?? defaults.sessionHealthCheckIntervalSecs
        transferRetryCount = try container.decodeIfPresent(UInt32.self, forKey: .transferRetryCount) ?? defaults.transferRetryCount
        transferChunkSizeBytes = try container.decodeIfPresent(UInt64.self, forKey: .transferChunkSizeBytes) ?? defaults.transferChunkSizeBytes
        transferDownloadPipelineDepth = try container.decodeIfPresent(UInt64.self, forKey: .transferDownloadPipelineDepth) ?? defaults.transferDownloadPipelineDepth
        transferUploadPipelineDepth = try container.decodeIfPresent(
            UInt64.self,
            forKey: .transferUploadPipelineDepth
        ) ?? defaults.transferUploadPipelineDepth
        if container.contains(.sshInactivityTimeoutSecs) {
            sshInactivityTimeoutSecs = try container.decodeIfPresent(
                UInt64.self,
                forKey: .sshInactivityTimeoutSecs
            )
        } else {
            sshInactivityTimeoutSecs = defaults.sshInactivityTimeoutSecs
        }
        sshKeepaliveIntervalSecs = try container.decodeIfPresent(UInt64.self, forKey: .sshKeepaliveIntervalSecs) ?? defaults.sshKeepaliveIntervalSecs
        defaultLocalPath = try container.decodeIfPresent(String.self, forKey: .defaultLocalPath) ?? defaults.defaultLocalPath
        defaultLocalBookmark = try container.decodeIfPresent(Data.self, forKey: .defaultLocalBookmark)
        confirmBeforeDelete = try container.decodeIfPresent(Bool.self, forKey: .confirmBeforeDelete) ?? defaults.confirmBeforeDelete
        showHiddenFiles = try container.decodeIfPresent(Bool.self, forKey: .showHiddenFiles) ?? defaults.showHiddenFiles
        mergeOpensshKnownHostsOnConnect = try container.decodeIfPresent(Bool.self, forKey: .mergeOpensshKnownHostsOnConnect) ?? defaults.mergeOpensshKnownHostsOnConnect
        opensshKnownHostsPath = try container.decodeIfPresent(String.self, forKey: .opensshKnownHostsPath) ?? defaults.opensshKnownHostsPath
        opensshKnownHostsBookmark = try container.decodeIfPresent(
            Data.self,
            forKey: .opensshKnownHostsBookmark
        )
        knownHostsStrictMode = try container.decodeIfPresent(Bool.self, forKey: .knownHostsStrictMode) ?? defaults.knownHostsStrictMode
        failConnectOnOpensshMergeError = try container.decodeIfPresent(Bool.self, forKey: .failConnectOnOpensshMergeError) ?? defaults.failConnectOnOpensshMergeError
        directoryWalkMaxFiles = try container.decodeIfPresent(UInt64.self, forKey: .directoryWalkMaxFiles) ?? defaults.directoryWalkMaxFiles
        directoryWalkMaxDepth = try container.decodeIfPresent(UInt32.self, forKey: .directoryWalkMaxDepth) ?? defaults.directoryWalkMaxDepth
        directoryWalkMaxTotalBytes = try container.decodeIfPresent(UInt64.self, forKey: .directoryWalkMaxTotalBytes) ?? defaults.directoryWalkMaxTotalBytes
        transferOverwritePolicy = try container.decodeIfPresent(
            TransferOverwritePolicy.self,
            forKey: .transferOverwritePolicy
        ) ?? defaults.transferOverwritePolicy
        notifyWhenTransfersFinish = try container.decodeIfPresent(
            Bool.self,
            forKey: .notifyWhenTransfersFinish
        ) ?? defaults.notifyWhenTransfersFinish
        playTransferNotificationSound = try container.decodeIfPresent(
            Bool.self,
            forKey: .playTransferNotificationSound
        ) ?? defaults.playTransferNotificationSound
    }

    init() {
        connectionTimeoutSecs = 30
        sessionHealthCheckIntervalSecs = 10
        transferRetryCount = 3
        transferChunkSizeBytes = 262_144
        transferDownloadPipelineDepth = 64
        transferUploadPipelineDepth = 64
        sshInactivityTimeoutSecs = 600
        sshKeepaliveIntervalSecs = 30
        defaultLocalPath = DefaultLocalPathResolver.containerHomeURL().path
        defaultLocalBookmark = nil
        confirmBeforeDelete = true
        showHiddenFiles = false
        mergeOpensshKnownHostsOnConnect = true
        opensshKnownHostsPath = "~/.ssh/known_hosts"
        opensshKnownHostsBookmark = nil
        knownHostsStrictMode = true
        failConnectOnOpensshMergeError = true
        directoryWalkMaxFiles = 100_000
        directoryWalkMaxDepth = 64
        directoryWalkMaxTotalBytes = 107_374_182_400
        transferOverwritePolicy = .replace
        notifyWhenTransfersFinish = true
        playTransferNotificationSound = true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(connectionTimeoutSecs, forKey: .connectionTimeoutSecs)
        try container.encode(sessionHealthCheckIntervalSecs, forKey: .sessionHealthCheckIntervalSecs)
        try container.encode(transferRetryCount, forKey: .transferRetryCount)
        try container.encode(transferChunkSizeBytes, forKey: .transferChunkSizeBytes)
        try container.encode(transferDownloadPipelineDepth, forKey: .transferDownloadPipelineDepth)
        try container.encode(transferUploadPipelineDepth, forKey: .transferUploadPipelineDepth)
        // Encode nil explicitly so a disabled timeout survives a round trip.
        try container.encode(sshInactivityTimeoutSecs, forKey: .sshInactivityTimeoutSecs)
        try container.encode(sshKeepaliveIntervalSecs, forKey: .sshKeepaliveIntervalSecs)
        try container.encode(defaultLocalPath, forKey: .defaultLocalPath)
        try container.encodeIfPresent(defaultLocalBookmark, forKey: .defaultLocalBookmark)
        try container.encode(confirmBeforeDelete, forKey: .confirmBeforeDelete)
        try container.encode(showHiddenFiles, forKey: .showHiddenFiles)
        try container.encode(mergeOpensshKnownHostsOnConnect, forKey: .mergeOpensshKnownHostsOnConnect)
        try container.encode(opensshKnownHostsPath, forKey: .opensshKnownHostsPath)
        try container.encodeIfPresent(opensshKnownHostsBookmark, forKey: .opensshKnownHostsBookmark)
        try container.encode(knownHostsStrictMode, forKey: .knownHostsStrictMode)
        try container.encode(failConnectOnOpensshMergeError, forKey: .failConnectOnOpensshMergeError)
        try container.encode(directoryWalkMaxFiles, forKey: .directoryWalkMaxFiles)
        try container.encode(directoryWalkMaxDepth, forKey: .directoryWalkMaxDepth)
        try container.encode(directoryWalkMaxTotalBytes, forKey: .directoryWalkMaxTotalBytes)
        try container.encode(transferOverwritePolicy, forKey: .transferOverwritePolicy)
        try container.encode(notifyWhenTransfersFinish, forKey: .notifyWhenTransfersFinish)
        try container.encode(playTransferNotificationSound, forKey: .playTransferNotificationSound)
    }
}
