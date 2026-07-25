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
            settingsService: settingsService
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

    func testSkipUpdatePersistsSkippedVersionAndSuppressesRelaunch() async {
        mockSession.responseJSON = newerReleaseJSON

        await viewModel.checkOnLaunch(isHostKeyBlocking: false)
        viewModel.skipUpdate()

        XCTAssertEqual(settingsService.loadSkippedUpdateVersion(), "0.2.0")
        XCTAssertFalse(viewModel.showUpdateSheet)

        viewModel = UpdateCheckViewModel(
            updateService: updateService,
            downloadService: mockDownloadService,
            settingsService: settingsService
        )
        await viewModel.checkOnLaunch(isHostKeyBlocking: false)

        XCTAssertFalse(viewModel.showUpdateSheet)
    }

    func testCheckOnLaunchIgnoresNetworkFailure() async {
        mockSession.shouldFail = true

        await viewModel.checkOnLaunch(isHostKeyBlocking: false)

        XCTAssertNil(viewModel.pendingUpdate)
        XCTAssertFalse(viewModel.showUpdateSheet)
    }

    func testDownloadUpdateSurfacesVerificationFailure() async {
        mockSession.responseJSON = newerReleaseJSON
        mockDownloadService.error = .signatureVerificationFailed(.unsignedBundle)

        await viewModel.checkOnLaunch(isHostKeyBlocking: false)
        await viewModel.downloadUpdate()

        XCTAssertEqual(
            viewModel.downloadErrorMessage,
            AppUpdateDownloadError.signatureVerificationFailed(.unsignedBundle).localizedDescription
        )
        XCTAssertFalse(viewModel.isDownloadingUpdate)
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

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
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

    func downloadVerifyAndReveal(update: AppUpdateInfo) async throws {
        if let error {
            throw error
        }
    }
}
