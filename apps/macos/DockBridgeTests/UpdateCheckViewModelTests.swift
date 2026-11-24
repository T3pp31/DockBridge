import XCTest
@testable import DockBridge

@MainActor
final class UpdateCheckViewModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var settingsService: AppSettingsService!
    private var mockSession: MockUpdateURLSession!
    private var updateService: AppUpdateService!
    private var mockDownloadService: MockAppUpdateDownloadService!
    private var viewModel: UpdateCheckViewModel!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "UpdateCheckViewModelTests")!
        defaults.removePersistentDomain(forName: "UpdateCheckViewModelTests")
        settingsService = AppSettingsService(defaults: defaults)
        mockSession = MockUpdateURLSession()
        updateService = AppUpdateService(session: mockSession)
        mockDownloadService = MockAppUpdateDownloadService()
        viewModel = UpdateCheckViewModel(
            updateService: updateService,
            downloadService: mockDownloadService,
            settingsService: settingsService,
            currentVersion: "0.1.0"
        )
    }

    func testCheckOnLaunchDefersSheetWhileHostKeyBlocking() async {
        mockSession.responseJSON = newerReleaseJSON

        await viewModel.checkOnLaunch(isHostKeyBlocking: true)

        XCTAssertEqual(viewModel.pendingUpdate?.version, "0.2.0")
        XCTAssertFalse(viewModel.showUpdateSheet)

        viewModel.onHostKeyDismissed()

        XCTAssertTrue(viewModel.showUpdateSheet)
    }

    func testCheckOnLaunchPresentsWithoutHostKeyPrompt() async {
        mockSession.responseJSON = newerReleaseJSON

        await viewModel.checkOnLaunch(isHostKeyBlocking: false)

        XCTAssertTrue(viewModel.showUpdateSheet)
    }

    func testHostKeyDismissedBeforeUpdateResponseStillPresentsSheet() async {
        mockSession.responseJSON = newerReleaseJSON
        mockSession.onRequest = { [viewModel = viewModel!] in
            await viewModel.onHostKeyDismissed()
        }

        await viewModel.checkOnLaunch(isHostKeyBlocking: true)

        XCTAssertTrue(viewModel.showUpdateSheet)
    }

    func testSkipVersionPersistsSkippedVersionAndSuppressesRelaunch() async {
        var currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        mockSession.responseJSON = newerReleaseJSON
        viewModel = UpdateCheckViewModel(
            updateService: updateService,
            downloadService: mockDownloadService,
            settingsService: settingsService,
            currentVersion: "0.1.0",
            now: { currentTime }
        )

        await viewModel.checkOnLaunch(isHostKeyBlocking: false)
        XCTAssertEqual(mockSession.requestCount, 1)
        XCTAssertEqual(viewModel.pendingUpdate?.version, "0.2.0")
        XCTAssertTrue(viewModel.showUpdateSheet)
        viewModel.skipVersion()

        XCTAssertEqual(settingsService.loadSkippedUpdateVersion(), "0.2.0")
        XCTAssertFalse(viewModel.showUpdateSheet)

        // Advance past the 24h launch throttle so the next launch actually queries
        // the service and proves skippedUpdateVersion itself suppresses relaunch.
        currentTime = currentTime.addingTimeInterval(25 * 60 * 60)
        viewModel = UpdateCheckViewModel(
            updateService: updateService,
            downloadService: mockDownloadService,
            settingsService: settingsService,
            currentVersion: "0.1.0",
            now: { currentTime }
        )
        await viewModel.checkOnLaunch(isHostKeyBlocking: false)

        XCTAssertEqual(mockSession.requestCount, 2)
        XCTAssertNil(viewModel.pendingUpdate)
        XCTAssertFalse(viewModel.showUpdateSheet)
    }

    func testLaterDismissesWithoutPersistingSkip() async {
        mockSession.responseJSON = newerReleaseJSON

        await viewModel.checkOnLaunch(isHostKeyBlocking: false)
        viewModel.skipUpdate()

        // "Later" dismisses the sheet but does NOT save the skipped version.
        XCTAssertNil(settingsService.loadSkippedUpdateVersion())
        XCTAssertNil(settingsService.loadLastUpdateCheckAt())
        XCTAssertFalse(viewModel.showUpdateSheet)

        viewModel = UpdateCheckViewModel(
            updateService: updateService,
            downloadService: mockDownloadService,
            settingsService: settingsService,
            currentVersion: "0.1.0"
        )
        await viewModel.checkOnLaunch(isHostKeyBlocking: false)

        // The update is offered again on the next launch.
        XCTAssertTrue(viewModel.showUpdateSheet)
    }

    func testCheckOnLaunchIgnoresCurrentOrOlderRelease() async {
        mockSession.responseJSON = newerReleaseJSON

        for (index, currentVersion) in ["0.2.0", "0.3.0"].enumerated() {
            settingsService.saveLastUpdateCheckAt(nil)
            viewModel = UpdateCheckViewModel(
                updateService: updateService,
                downloadService: mockDownloadService,
                settingsService: settingsService,
                currentVersion: currentVersion
            )

            await viewModel.checkOnLaunch(isHostKeyBlocking: false)

            XCTAssertEqual(mockSession.requestCount, index + 1, "currentVersion: \(currentVersion)")
            XCTAssertNil(viewModel.pendingUpdate, "currentVersion: \(currentVersion)")
            XCTAssertFalse(viewModel.showUpdateSheet, "currentVersion: \(currentVersion)")
        }
    }

    func testCheckOnLaunchIgnoresNetworkFailure() async {
        mockSession.shouldFail = true

        await viewModel.checkOnLaunch(isHostKeyBlocking: false)

        XCTAssertNil(viewModel.pendingUpdate)
        XCTAssertFalse(viewModel.showUpdateSheet)
    }

    func testDownloadUpdateSurfacesVerificationFailure() async throws {
        // Issue #839 F18: inject inAppUpdateInstallationEnabled=true and URL spy
        // so both verification and browser-fallback branches run unconditionally.
        var openedURLs: [URL] = []
        let enabledViewModel = UpdateCheckViewModel(
            updateService: AppUpdateService(session: mockSession),
            downloadService: mockDownloadService,
            settingsService: settingsService,
            currentVersion: "0.1.0",
            inAppUpdateInstallationEnabled: true,
            openURL: { openedURLs.append($0) }
        )

        mockSession.responseJSON = newerReleaseJSON
        mockDownloadService.error = .signatureVerificationFailed(.unsignedBundle)

        await enabledViewModel.checkOnLaunch(isHostKeyBlocking: false)
        await enabledViewModel.downloadUpdate()

        XCTAssertEqual(mockDownloadService.downloadedUpdates.count, 1)
        XCTAssertTrue(openedURLs.isEmpty)
        XCTAssertEqual(
            enabledViewModel.downloadErrorMessage,
            AppUpdateDownloadError.signatureVerificationFailed(.unsignedBundle).localizedDescription
        )
        XCTAssertFalse(enabledViewModel.isDownloadingUpdate)
    }

    func testDownloadUpdateOpensReleasePageWhenInAppInstallDisabled() async throws {
        // Issue #839 F18: inject inAppUpdateInstallationEnabled=false and spy on openURL.
        var openedURLs: [URL] = []
        let disabledViewModel = UpdateCheckViewModel(
            updateService: AppUpdateService(session: mockSession),
            downloadService: mockDownloadService,
            settingsService: settingsService,
            currentVersion: "0.1.0",
            inAppUpdateInstallationEnabled: false,
            openURL: { openedURLs.append($0) }
        )
        XCTAssertFalse(disabledViewModel.inAppUpdateInstallationEnabled)

        mockSession.responseJSON = newerReleaseJSON
        await disabledViewModel.checkOnLaunch(isHostKeyBlocking: false)
        await disabledViewModel.downloadUpdate()

        XCTAssertEqual(openedURLs, [URL(string: "https://github.com/T3pp31/DockBridge/releases/tag/v0.2.0")!])
        XCTAssertTrue(mockDownloadService.downloadedUpdates.isEmpty)
        XCTAssertNotNil(disabledViewModel.downloadErrorMessage)
        XCTAssertTrue(disabledViewModel.downloadErrorMessage?.contains("In-app installation is disabled") == true)
        XCTAssertFalse(disabledViewModel.isDownloadingUpdate)
    }

    func testInAppInstallationRequiresCompleteSignaturePolicy() {
        let cases: [(team: String, fingerprint: String, signed: Bool, notarized: Bool)] = [
            ("", "", true, true),
            ("TEAMID1234", "", true, true),
            ("", "abc123", true, true),
            ("TEAMID1234", "abc123", false, false),
        ]

        for policy in cases {
            let enabled = ReleaseVerificationPolicy(
                expectedBundleIdentifier: AppUpdateConfig.bundleIdentifier,
                expectedTeamIdentifier: policy.team,
                signingCertificateFingerprintSHA256: policy.fingerprint,
                requireSignedUpdates: policy.signed,
                requireNotarizedUpdates: policy.notarized
            )
            XCTAssertFalse(
                AppUpdateConfig.isInAppUpdateInstallationEnabled(for: enabled),
                "team=\(policy.team.debugDescription) fingerprint=\(policy.fingerprint.debugDescription) signed=\(policy.signed) notarized=\(policy.notarized)"
            )
        }
    }

    func testInAppInstallationEnabledOnlyWithCompletePolicy() {
        for policy in [
            ReleaseVerificationPolicy(
                expectedBundleIdentifier: AppUpdateConfig.bundleIdentifier,
                expectedTeamIdentifier: "TEAMID1234",
                signingCertificateFingerprintSHA256: "abc123",
                requireSignedUpdates: true,
                requireNotarizedUpdates: false
            ),
            ReleaseVerificationPolicy(
                expectedBundleIdentifier: AppUpdateConfig.bundleIdentifier,
                expectedTeamIdentifier: "TEAMID1234",
                signingCertificateFingerprintSHA256: "",
                requireSignedUpdates: false,
                requireNotarizedUpdates: true
            ),
        ] {
            XCTAssertTrue(AppUpdateConfig.isInAppUpdateInstallationEnabled(for: policy))
        }
    }

    // MARK: - Launch throttle, rate-limit backoff, and manual check (#403)

    func testCheckOnLaunchThrottlesWithin24HoursAndRetriesAfterInterval() async {
        var currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        mockSession.responseJSON = newerReleaseJSON
        let throttled = UpdateCheckViewModel(
            updateService: updateService,
            downloadService: mockDownloadService,
            settingsService: settingsService,
            currentVersion: "0.2.0",
            now: { currentTime }
        )

        await throttled.checkOnLaunch(isHostKeyBlocking: false)
        XCTAssertEqual(mockSession.requestCount, 1)
        XCTAssertEqual(settingsService.loadLastUpdateCheckAt(), currentTime)

        // 23 hours later: still within 24h window -> no network request.
        currentTime = currentTime.addingTimeInterval(23 * 60 * 60)
        await throttled.checkOnLaunch(isHostKeyBlocking: false)
        XCTAssertEqual(mockSession.requestCount, 1)

        // 24 hours + 1 second after initial check -> runs again.
        currentTime = Date(timeIntervalSince1970: 1_700_000_000 + 24 * 60 * 60 + 1)
        await throttled.checkOnLaunch(isHostKeyBlocking: false)
        XCTAssertEqual(mockSession.requestCount, 2)
        XCTAssertEqual(settingsService.loadLastUpdateCheckAt(), currentTime)
    }

    func testCheckOnLaunchHonorsRetryAfterBackoffAndClearsOnRecovery() async {
        var currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        mockSession.statusCode = 429
        mockSession.responseHeaders = ["Retry-After": "180"]
        let vm = UpdateCheckViewModel(
            updateService: updateService,
            downloadService: mockDownloadService,
            settingsService: settingsService,
            currentVersion: "0.1.0",
            now: { currentTime }
        )

        await vm.checkOnLaunch(isHostKeyBlocking: false)
        XCTAssertEqual(mockSession.requestCount, 1)
        XCTAssertEqual(
            settingsService.loadUpdateCheckBackoffUntil(),
            currentTime.addingTimeInterval(180)
        )
        XCTAssertNil(settingsService.loadLastUpdateCheckAt())

        // 100s later: still in backoff -> skipped without hitting network.
        currentTime = currentTime.addingTimeInterval(100)
        await vm.checkOnLaunch(isHostKeyBlocking: false)
        XCTAssertEqual(mockSession.requestCount, 1)

        // 181s after initial 429: backoff expired -> recovers and clears backoff.
        currentTime = Date(timeIntervalSince1970: 1_700_000_000 + 181)
        mockSession.statusCode = 200
        mockSession.responseHeaders = nil
        mockSession.responseJSON = newerReleaseJSON
        await vm.checkOnLaunch(isHostKeyBlocking: false)
        XCTAssertEqual(mockSession.requestCount, 2)
        XCTAssertNil(settingsService.loadUpdateCheckBackoffUntil())
        XCTAssertTrue(vm.showUpdateSheet)
    }

    func testCheckOnLaunchDoesNotThrottleAfterTransientNetworkFailure() async {
        let currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        mockSession.shouldFail = true
        let vm = UpdateCheckViewModel(
            updateService: updateService,
            downloadService: mockDownloadService,
            settingsService: settingsService,
            currentVersion: "0.1.0",
            now: { currentTime }
        )

        await vm.checkOnLaunch(isHostKeyBlocking: false)
        XCTAssertEqual(mockSession.requestCount, 1)
        XCTAssertNil(settingsService.loadLastUpdateCheckAt())

        mockSession.shouldFail = false
        mockSession.responseJSON = newerReleaseJSON
        await vm.checkOnLaunch(isHostKeyBlocking: false)
        XCTAssertEqual(mockSession.requestCount, 2)
        XCTAssertTrue(vm.showUpdateSheet)
    }

    func testCheckManuallyBypassesThrottleBackoffAndSkippedVersion() async {
        let currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        settingsService.saveLastUpdateCheckAt(currentTime)
        settingsService.saveUpdateCheckBackoffUntil(currentTime.addingTimeInterval(3_600))
        settingsService.saveSkippedUpdateVersion("0.2.0")
        mockSession.responseJSON = newerReleaseJSON
        let vm = UpdateCheckViewModel(
            updateService: updateService,
            downloadService: mockDownloadService,
            settingsService: settingsService,
            currentVersion: "0.1.0",
            now: { currentTime }
        )

        await vm.checkManually()

        XCTAssertEqual(mockSession.requestCount, 1)
        XCTAssertTrue(vm.showUpdateSheet)
        XCTAssertEqual(vm.pendingUpdate?.version, "0.2.0")
        XCTAssertNil(vm.manualCheckAlert)
        XCTAssertNil(settingsService.loadUpdateCheckBackoffUntil())
        XCTAssertFalse(vm.isCheckingManually)
    }

    func testCheckManuallyShowsUpToDateAndErrorAlerts() async {
        let currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        mockSession.responseJSON = newerReleaseJSON
        let vm = UpdateCheckViewModel(
            updateService: updateService,
            downloadService: mockDownloadService,
            settingsService: settingsService,
            currentVersion: "0.2.0",
            now: { currentTime }
        )

        // Up-to-date alert.
        await vm.checkManually()
        XCTAssertFalse(vm.showUpdateSheet)
        XCTAssertEqual(vm.manualCheckAlert?.title, String(localized: "You're Up to Date"))
        XCTAssertTrue(vm.manualCheckAlert?.message.contains("0.2.0") == true)
        XCTAssertEqual(settingsService.loadLastUpdateCheckAt(), currentTime)

        // Rate-limited alert also schedules backoff.
        mockSession.statusCode = 403
        mockSession.responseHeaders = ["Retry-After": "90"]
        await vm.checkManually()
        XCTAssertEqual(vm.manualCheckAlert?.title, String(localized: "Update Check Failed"))
        XCTAssertEqual(
            vm.manualCheckAlert?.message,
            AppUpdateServiceError.rateLimited(retryAfter: "90").localizedDescription
        )
        XCTAssertEqual(
            settingsService.loadUpdateCheckBackoffUntil(),
            currentTime.addingTimeInterval(90)
        )

        // Generic network failure alert.
        mockSession.statusCode = 200
        mockSession.responseHeaders = nil
        mockSession.shouldFail = true
        await vm.checkManually()
        XCTAssertEqual(vm.manualCheckAlert?.title, String(localized: "Update Check Failed"))
        XCTAssertNotNil(vm.manualCheckAlert?.message)
        XCTAssertFalse(vm.isCheckingManually)
    }

    func testCheckOnLaunchClearsOutOfRangeFutureBackoffFromClockSkew() async {
        let currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        // A corrupt or clock-skewed timestamp > 24h in the future must not disable checks forever.
        settingsService.saveUpdateCheckBackoffUntil(currentTime.addingTimeInterval(48 * 60 * 60))
        mockSession.responseJSON = newerReleaseJSON
        let vm = UpdateCheckViewModel(
            updateService: updateService,
            downloadService: mockDownloadService,
            settingsService: settingsService,
            currentVersion: "0.1.0",
            now: { currentTime }
        )

        await vm.checkOnLaunch(isHostKeyBlocking: false)

        XCTAssertEqual(mockSession.requestCount, 1)
        XCTAssertNil(settingsService.loadUpdateCheckBackoffUntil())
        XCTAssertTrue(vm.showUpdateSheet)
    }

    func testStaleLaunchCheckDoesNotClobberNewerManualCheck() async {
        settingsService.saveSkippedUpdateVersion("0.2.0")
        mockSession.responseJSON = newerReleaseJSON
        let vm = UpdateCheckViewModel(
            updateService: updateService,
            downloadService: mockDownloadService,
            settingsService: settingsService,
            currentVersion: "0.1.0"
        )
        var triggeredManual = false
        mockSession.onRequest = {
            guard !triggeredManual else { return }
            triggeredManual = true
            // While launch check (with skippedVersion=0.2.0) is in flight,
            // run manual check (which ignores skippedVersion) to completion.
            await vm.checkManually()
        }

        await vm.checkOnLaunch(isHostKeyBlocking: false)

        // Manual check presented 0.2.0; stale launch check (which got nil due to skippedVersion)
        // must NOT clear pendingUpdate or collapse the open sheet.
        XCTAssertEqual(vm.pendingUpdate?.version, "0.2.0")
        XCTAssertTrue(vm.showUpdateSheet)
    }

    func testCheckManuallyIsIgnoredWhileDownloadInProgress() async {
        mockSession.responseJSON = newerReleaseJSON
        let vm = UpdateCheckViewModel(
            updateService: updateService,
            downloadService: mockDownloadService,
            settingsService: settingsService,
            currentVersion: "0.1.0",
            inAppUpdateInstallationEnabled: true
        )
        await vm.checkOnLaunch(isHostKeyBlocking: false)
        XCTAssertEqual(mockSession.requestCount, 1)
        XCTAssertEqual(vm.pendingUpdate?.version, "0.2.0")

        mockDownloadService.onDownload = {
            // Attempting a manual check mid-download must be ignored so pendingUpdate stays intact.
            await vm.checkManually()
        }
        await vm.downloadUpdate()

        XCTAssertEqual(mockSession.requestCount, 1)
        XCTAssertEqual(vm.pendingUpdate?.version, "0.2.0")
        XCTAssertFalse(vm.isDownloadingUpdate)
    }

    func testDuplicateCheckOnLaunchIgnoredWhenUpdateAlreadyPending() async {
        mockSession.responseJSON = newerReleaseJSON
        let vm = UpdateCheckViewModel(
            updateService: updateService,
            downloadService: mockDownloadService,
            settingsService: settingsService,
            currentVersion: "0.1.0"
        )
        await vm.checkOnLaunch(isHostKeyBlocking: false)
        XCTAssertEqual(mockSession.requestCount, 1)

        // Opening a second window runs .task -> checkOnLaunch again while pendingUpdate is set.
        await vm.checkOnLaunch(isHostKeyBlocking: false)
        XCTAssertEqual(mockSession.requestCount, 1)
    }

    private var newerReleaseJSON: String {
        """
        {
          "tag_name": "v0.2.0",
          "html_url": "https://github.com/T3pp31/DockBridge/releases/tag/v0.2.0",
          "assets": [
            {
              "name": "DockBridge-0.2.0-macOS.dmg",
              "browser_download_url": "https://github.com/T3pp31/DockBridge/releases/download/v0.2.0/DockBridge-0.2.0-macOS.dmg"
            },
            {
              "name": "DockBridge-0.2.0-macOS.dmg.sha256",
              "browser_download_url": "https://github.com/T3pp31/DockBridge/releases/download/v0.2.0/DockBridge-0.2.0-macOS.dmg.sha256"
            }
          ]
        }
        """
    }
}

private final class MockUpdateURLSession: URLSessionDataProviding, @unchecked Sendable {
    var responseJSON = "{}"
    var statusCode = 200
    var responseHeaders: [String: String]?
    var shouldFail = false
    var requestCount = 0
    var onRequest: (@Sendable () async -> Void)?

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requestCount += 1
        await onRequest?()
        if shouldFail {
            throw URLError(.notConnectedToInternet)
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: responseHeaders
        )!
        return (Data(responseJSON.utf8), response)
    }
}

private final class MockAppUpdateDownloadService: AppUpdateDownloading, @unchecked Sendable {
    var error: AppUpdateDownloadError?
    var downloadedUpdates: [AppUpdateInfo] = []
    var onDownload: (@Sendable () async -> Void)?

    func downloadVerifyAndReveal(update: AppUpdateInfo) async throws {
        downloadedUpdates.append(update)
        await onDownload?()
        if let error {
            throw error
        }
    }
}
