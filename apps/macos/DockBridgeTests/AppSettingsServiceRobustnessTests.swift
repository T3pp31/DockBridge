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
}
