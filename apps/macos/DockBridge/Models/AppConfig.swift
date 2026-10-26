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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        connectionTimeoutSecs = try container.decode(UInt64.self, forKey: .connectionTimeoutSecs)
        sessionHealthCheckIntervalSecs = try container.decode(UInt64.self, forKey: .sessionHealthCheckIntervalSecs)
        transferRetryCount = try container.decode(UInt32.self, forKey: .transferRetryCount)
        transferChunkSizeBytes = try container.decode(UInt64.self, forKey: .transferChunkSizeBytes)
        transferDownloadPipelineDepth = try container.decode(UInt64.self, forKey: .transferDownloadPipelineDepth)
        transferUploadPipelineDepth = try container.decodeIfPresent(
            UInt64.self,
            forKey: .transferUploadPipelineDepth
        ) ?? 64
        sshInactivityTimeoutSecs = try container.decodeIfPresent(
            UInt64.self,
            forKey: .sshInactivityTimeoutSecs
        )
        sshKeepaliveIntervalSecs = try container.decode(UInt64.self, forKey: .sshKeepaliveIntervalSecs)
        defaultLocalPath = try container.decode(String.self, forKey: .defaultLocalPath)
        defaultLocalBookmark = try container.decodeIfPresent(Data.self, forKey: .defaultLocalBookmark)
        confirmBeforeDelete = try container.decode(Bool.self, forKey: .confirmBeforeDelete)
        showHiddenFiles = try container.decode(Bool.self, forKey: .showHiddenFiles)
        mergeOpensshKnownHostsOnConnect = try container.decode(
            Bool.self,
            forKey: .mergeOpensshKnownHostsOnConnect
        )
        opensshKnownHostsPath = try container.decode(String.self, forKey: .opensshKnownHostsPath)
        opensshKnownHostsBookmark = try container.decodeIfPresent(
            Data.self,
            forKey: .opensshKnownHostsBookmark
        )
        knownHostsStrictMode = try container.decode(Bool.self, forKey: .knownHostsStrictMode)
        failConnectOnOpensshMergeError = try container.decode(
            Bool.self,
            forKey: .failConnectOnOpensshMergeError
        )
        directoryWalkMaxFiles = try container.decode(UInt64.self, forKey: .directoryWalkMaxFiles)
        directoryWalkMaxDepth = try container.decode(UInt32.self, forKey: .directoryWalkMaxDepth)
        directoryWalkMaxTotalBytes = try container.decode(UInt64.self, forKey: .directoryWalkMaxTotalBytes)
        transferOverwritePolicy = try container.decodeIfPresent(
            TransferOverwritePolicy.self,
            forKey: .transferOverwritePolicy
        ) ?? .replace
        notifyWhenTransfersFinish = try container.decodeIfPresent(
            Bool.self,
            forKey: .notifyWhenTransfersFinish
        ) ?? true
        playTransferNotificationSound = try container.decodeIfPresent(
            Bool.self,
            forKey: .playTransferNotificationSound
        ) ?? true
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
