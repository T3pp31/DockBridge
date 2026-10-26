import AppKit
import Foundation

@MainActor
final class UpdateCheckViewModel: ObservableObject {
    @Published private(set) var pendingUpdate: AppUpdateInfo?
    @Published var showUpdateSheet = false
    @Published private(set) var isDownloadingUpdate = false
    @Published var downloadErrorMessage: String?

    private let updateService: AppUpdateService
    private let downloadService: AppUpdateDownloading
    private let settingsService: AppSettingsService
    /// Tracks whether the startup host-key prompt has been resolved, so a
    /// slow update check can still present after dismissal (issue #636).
    private var isHostKeyResolved = false

    init(
        updateService: AppUpdateService = AppUpdateService(),
        downloadService: AppUpdateDownloading = AppUpdateDownloadService(),
        settingsService: AppSettingsService = .shared
    ) {
        self.updateService = updateService
        self.downloadService = downloadService
        self.settingsService = settingsService
    }

    func checkOnLaunch(isHostKeyBlocking: Bool) async {
        do {
            let update = try await updateService.checkForUpdate(
                skippedVersion: settingsService.loadSkippedUpdateVersion()
            )
            guard let update else { return }
            pendingUpdate = update
            presentPendingUpdateIfAllowed()
        } catch {
            AppLogging.update.error("update check failed on launch: \(error.localizedDescription, privacy: .public)")
        }
    }

    func onHostKeyDismissed() {
        isHostKeyResolved = true
        presentPendingUpdateIfAllowed()
    }

    var inAppUpdateInstallationEnabled: Bool {
        AppUpdateConfig.inAppUpdateInstallationEnabled
    }

    func downloadUpdate() async {
        guard let pendingUpdate, !isDownloadingUpdate else { return }

        if !inAppUpdateInstallationEnabled
            || pendingUpdate.downloadURL == pendingUpdate.releasePageURL {
            NSWorkspace.shared.open(pendingUpdate.releasePageURL)
            if !inAppUpdateInstallationEnabled {
                downloadErrorMessage = """
                In-app installation is disabled until release builds are signed and notarized. \
                Download the update manually from the release page and verify it before installing.
                """
            }
            return
        }

        isDownloadingUpdate = true
        downloadErrorMessage = nil
        defer { isDownloadingUpdate = false }

        do {
            try await downloadService.downloadVerifyAndReveal(update: pendingUpdate)
        } catch {
            downloadErrorMessage = error.localizedDescription
        }
    }

    /// "Later": dismiss the sheet WITHOUT persisting a skip, so the update is
    /// offered again on the next launch/check.
    func skipUpdate() {
        dismissSheet()
    }

    /// "Skip This Version": persist the skip so this version is not offered
    /// again (unless the user checks manually or a newer version appears).
    func skipVersion() {
        guard let pendingUpdate else { return }
        settingsService.saveSkippedUpdateVersion(pendingUpdate.version)
        dismissSheet()
    }

    func dismissSheet() {
        showUpdateSheet = false
        downloadErrorMessage = nil
    }

    private func presentPendingUpdateIfAllowed() {
        guard pendingUpdate != nil, isHostKeyResolved else { return }
        showUpdateSheet = true
    }
}
