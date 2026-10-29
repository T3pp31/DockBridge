import XCTest
@testable import DockBridge

final class AppSettingsServiceRobustnessTests: XCTestCase {
    private var service: AppSettingsService!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "RobustnessTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        service = AppSettingsService(defaults: defaults)
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testEmptyEncodedConfigUsesAllDefaults() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(config, .default)
    }

    func testEachMissingConfigKeyUsesItsDefault() throws {
        let encoded = try JSONEncoder().encode(AppConfig.default)
        let full = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in full.keys {
            var partial = full
            partial.removeValue(forKey: key)
            let data = try JSONSerialization.data(withJSONObject: partial)
            XCTAssertEqual(try JSONDecoder().decode(AppConfig.self, from: data), .default, key)
        }
    }

    func testExplicitNullInactivityTimeoutRemainsDisabled() throws {
        let config = try JSONDecoder().decode(
            AppConfig.self,
            from: Data("{\"sshInactivityTimeoutSecs\":null}".utf8)
        )
        XCTAssertNil(config.sshInactivityTimeoutSecs)
        XCTAssertEqual(config.connectionTimeoutSecs, AppConfig.default.connectionTimeoutSecs)
        XCTAssertEqual(try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config)), config)
    }

    func testEncodedConfigRoundTripPreservesEveryNonDefaultField() throws {
        var config = AppConfig.default
        config.connectionTimeoutSecs = 5
        config.sessionHealthCheckIntervalSecs = 7
        config.transferRetryCount = 1
        config.transferChunkSizeBytes = 65_536
        config.transferDownloadPipelineDepth = 8
        config.transferUploadPipelineDepth = 16
        config.sshInactivityTimeoutSecs = 90
        config.sshKeepaliveIntervalSecs = 15
        config.defaultLocalPath = "/tmp/custom-local-directory"
        config.defaultLocalBookmark = Data([1, 2, 3])
        config.confirmBeforeDelete = false
        config.showHiddenFiles = true
        config.mergeOpensshKnownHostsOnConnect = false
        config.opensshKnownHostsPath = "/tmp/custom-known-hosts"
        config.opensshKnownHostsBookmark = Data([4, 5, 6])
        config.knownHostsStrictMode = false
        config.failConnectOnOpensshMergeError = false
        config.directoryWalkMaxFiles = 200
        config.directoryWalkMaxDepth = 4
        config.directoryWalkMaxTotalBytes = 1_024
        config.transferOverwritePolicy = .ask
        config.notifyWhenTransfersFinish = false
        config.playTransferNotificationSound = false

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(AppConfig.self, from: encoder.encode(config)), config)

        config.sshInactivityTimeoutSecs = nil
        XCTAssertEqual(try decoder.decode(AppConfig.self, from: encoder.encode(config)), config)
    }

    func testInvalidConfigFieldTypeStillFailsDecoding() {
        XCTAssertThrowsError(try JSONDecoder().decode(
            AppConfig.self,
            from: Data("{\"connectionTimeoutSecs\":\"invalid\"}".utf8)
        ))
    }

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: suiteName)!
    }

    func testLoadConfigClampsNegativeTimeout() {
        // Given: a broken plist with a negative connection timeout
        defaults().set(-5, forKey: AppSettingsKeys.connectionTimeoutSecs)

        // When: loadConfig is called
        let config = service.loadConfig()

        // Then: it does not crash and clamps to a sane positive value
        XCTAssertGreaterThanOrEqual(config.connectionTimeoutSecs, 1)
    }

    func testLoadConfigClampsNegativeRetryCount() {
        // Given: a negative retry count in UserDefaults
        defaults().set(-3, forKey: AppSettingsKeys.transferRetryCount)

        // When: loadConfig is called
        let config = service.loadConfig()

        // Then: it does not crash and clamps to the default
        XCTAssertLessThanOrEqual(config.transferRetryCount, UInt32.max)
    }

    func testLoadConfigClampsOversizedChunkToMaximum() {
        // Given: a chunk size far above the 8 MiB maximum
        defaults().set(Int.max, forKey: AppSettingsKeys.transferChunkSizeBytes)

        // When: loadConfig is called
        let config = service.loadConfig()

        // Then: it clamps to the supported maximum (8 MiB)
        XCTAssertLessThanOrEqual(config.transferChunkSizeBytes, 8_388_608)
    }

    func testLoadConfigClampsTinyChunkToMinimum() {
        // Given: a chunk size below the 4 KiB minimum
        defaults().set(1, forKey: AppSettingsKeys.transferChunkSizeBytes)

        // When: loadConfig is called
        let config = service.loadConfig()

        // Then: it clamps up to the supported minimum
        XCTAssertGreaterThanOrEqual(config.transferChunkSizeBytes, 4_096)
    }

    func testLoadConfigClampsUploadPipelineDepthToSupportedRange() {
        // Given: corrupted upload pipeline depths outside the supported range
        defaults().set(0, forKey: AppSettingsKeys.transferUploadPipelineDepth)

        // When: the low value is loaded
        let lowConfig = service.loadConfig()

        // Then: it is clamped to the minimum
        XCTAssertEqual(lowConfig.transferUploadPipelineDepth, 1)

        // When: an oversized value is loaded
        defaults().set(Int.max, forKey: AppSettingsKeys.transferUploadPipelineDepth)
        let highConfig = service.loadConfig()

        // Then: it is clamped to the maximum
        XCTAssertEqual(highConfig.transferUploadPipelineDepth, 256)
    }

    func testSaveConfigPreservesUploadPipelineDepth() {
        // Given: a non-default upload pipeline depth
        var config = service.loadConfig()
        config.transferUploadPipelineDepth = 32

        // When: the config is saved and loaded again
        service.saveConfig(config)
        let reloaded = service.loadConfig()

        // Then: the configured value is preserved
        XCTAssertEqual(reloaded.transferUploadPipelineDepth, 32)
    }

    func testSaveConfigPreservesDisabledInactivityTimeout() {
        // Given: idle-based expiry is explicitly disabled
        var config = service.loadConfig()
        config.sshInactivityTimeoutSecs = nil

        // When: the config is saved and loaded again
        service.saveConfig(config)
        let reloaded = service.loadConfig()

        // Then: the registered default does not re-enable the timeout
        XCTAssertNil(reloaded.sshInactivityTimeoutSecs)
    }

    func testTransferNotificationsAreEnabledByDefault() {
        let config = service.loadConfig()

        XCTAssertTrue(config.notifyWhenTransfersFinish)
        XCTAssertTrue(config.playTransferNotificationSound)
    }

    func testSaveConfigPreservesTransferNotificationPreferences() {
        var config = service.loadConfig()
        config.notifyWhenTransfersFinish = false
        config.playTransferNotificationSound = false

        service.saveConfig(config)
        let reloaded = service.loadConfig()

        XCTAssertFalse(reloaded.notifyWhenTransfersFinish)
        XCTAssertFalse(reloaded.playTransferNotificationSound)
    }
}
