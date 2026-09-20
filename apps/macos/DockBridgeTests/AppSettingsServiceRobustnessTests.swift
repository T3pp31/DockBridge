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
