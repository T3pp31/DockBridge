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
        mockSession.responseJSON = newerReleaseJSON

        await viewModel.checkOnLaunch(isHostKeyBlocking: false)
        XCTAssertEqual(viewModel.pendingUpdate?.version, "0.2.0")
        XCTAssertTrue(viewModel.showUpdateSheet)
        viewModel.skipVersion()

        XCTAssertEqual(settingsService.loadSkippedUpdateVersion(), "0.2.0")
        XCTAssertFalse(viewModel.showUpdateSheet)

        viewModel = UpdateCheckViewModel(
            updateService: updateService,
            downloadService: mockDownloadService,
            settingsService: settingsService,
            currentVersion: "0.1.0"
        )
        await viewModel.checkOnLaunch(isHostKeyBlocking: false)

        XCTAssertNil(viewModel.pendingUpdate)
        XCTAssertFalse(viewModel.showUpdateSheet)
    }

    func testLaterDismissesWithoutPersistingSkip() async {
        mockSession.responseJSON = newerReleaseJSON

        await viewModel.checkOnLaunch(isHostKeyBlocking: false)
        viewModel.skipUpdate()

        // "Later" dismisses the sheet but does NOT save the skipped version.
        XCTAssertNil(settingsService.loadSkippedUpdateVersion())
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

        for currentVersion in ["0.2.0", "0.3.0"] {
            viewModel = UpdateCheckViewModel(
                updateService: updateService,
                downloadService: mockDownloadService,
                settingsService: settingsService,
                currentVersion: currentVersion
            )

            await viewModel.checkOnLaunch(isHostKeyBlocking: false)

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
    var shouldFail = false
    var onRequest: (@Sendable () async -> Void)?

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        await onRequest?()
        if shouldFail {
            throw URLError(.notConnectedToInternet)
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(responseJSON.utf8), response)
    }
}

private final class MockAppUpdateDownloadService: AppUpdateDownloading, @unchecked Sendable {
    var error: AppUpdateDownloadError?
    var downloadedUpdates: [AppUpdateInfo] = []

    func downloadVerifyAndReveal(update: AppUpdateInfo) async throws {
        downloadedUpdates.append(update)
        if let error {
            throw error
        }
    }
}
