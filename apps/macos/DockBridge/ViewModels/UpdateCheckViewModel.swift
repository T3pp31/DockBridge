import AppKit
import Foundation
import os

@MainActor
final class UpdateCheckViewModel: ObservableObject {
    struct ManualCheckAlert: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let message: String

        static func == (lhs: ManualCheckAlert, rhs: ManualCheckAlert) -> Bool {
            lhs.title == rhs.title && lhs.message == rhs.message
        }
    }

    static let defaultLaunchCheckInterval: TimeInterval = 24 * 60 * 60

    @Published private(set) var pendingUpdate: AppUpdateInfo?
    @Published var showUpdateSheet = false
    @Published private(set) var isDownloadingUpdate = false
    @Published var downloadErrorMessage: String?
    @Published private(set) var isCheckingManually = false
    @Published var manualCheckAlert: ManualCheckAlert?

    private let updateService: AppUpdateService
    private let downloadService: AppUpdateDownloading
    private let settingsService: AppSettingsService
    private let currentVersion: String
    private let inAppInstallEnabledProvider: () -> Bool
    private let openURL: (URL) -> Void
    private let now: () -> Date
    private let launchCheckInterval: TimeInterval
    /// Tracks whether the startup host-key prompt has been resolved, so a
    /// slow update check can still present after dismissal (issue #636).
    private var isHostKeyResolved = false
    /// Monotonic token so a newer manual check supersedes any in-flight launch check.
    private var checkGeneration: UInt64 = 0
    private var isCheckingOnLaunch = false

    init(
        updateService: AppUpdateService = AppUpdateService(),
        downloadService: AppUpdateDownloading = AppUpdateDownloadService(),
        settingsService: AppSettingsService = .shared,
        currentVersion: String = VersionComparator.currentAppVersion,
        inAppUpdateInstallationEnabled: Bool? = nil,
        openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        now: @escaping () -> Date = { Date() },
        launchCheckInterval: TimeInterval = UpdateCheckViewModel.defaultLaunchCheckInterval
    ) {
        self.updateService = updateService
        self.downloadService = downloadService
        self.settingsService = settingsService
        self.currentVersion = currentVersion
        self.inAppInstallEnabledProvider = {
            inAppUpdateInstallationEnabled ?? AppUpdateConfig.inAppUpdateInstallationEnabled
        }
        self.openURL = openURL
        self.now = now
        self.launchCheckInterval = launchCheckInterval
    }

    func checkOnLaunch(isHostKeyBlocking: Bool) async {
        isHostKeyResolved = !isHostKeyBlocking
        guard !isCheckingOnLaunch, !isCheckingManually, !isDownloadingUpdate, pendingUpdate == nil else {
            return
        }
        let currentTime = now()
        if let backoffUntil = settingsService.loadUpdateCheckBackoffUntil() {
            let remaining = backoffUntil.timeIntervalSince(currentTime)
            if remaining > 0 {
                if remaining <= AppUpdateService.maxRateLimitBackoff {
                    AppLogging.update.info(
                        "skipping launch update check due to rate-limit backoff until \(backoffUntil, privacy: .public)"
                    )
                    return
                }
                // Clock skew or corrupt future timestamp exceeds max backoff; clear it.
                settingsService.saveUpdateCheckBackoffUntil(nil)
            }
        }
        if let lastCheck = settingsService.loadLastUpdateCheckAt(),
           currentTime >= lastCheck,
           currentTime.timeIntervalSince(lastCheck) < launchCheckInterval {
            AppLogging.update.debug("skipping launch update check; last check was within 24 hours")
            return
        }

        checkGeneration &+= 1
        let generation = checkGeneration
        isCheckingOnLaunch = true
        defer { isCheckingOnLaunch = false }

        do {
            let update = try await updateService.checkForUpdate(
                currentVersion: currentVersion,
                skippedVersion: settingsService.loadSkippedUpdateVersion()
            )
            guard generation == checkGeneration, !isDownloadingUpdate else { return }
            settingsService.saveUpdateCheckBackoffUntil(nil)
            guard let update else {
                pendingUpdate = nil
                showUpdateSheet = false
                settingsService.saveLastUpdateCheckAt(now())
                return
            }
            pendingUpdate = update
            presentPendingUpdateIfAllowed()
        } catch let error as AppUpdateServiceError {
            guard generation == checkGeneration else { return }
            recordRateLimitBackoffIfNeeded(for: error)
            AppLogging.update.error("update check failed on launch: \(error.localizedDescription, privacy: .public)")
        } catch {
            guard generation == checkGeneration else { return }
            AppLogging.update.error("update check failed on launch: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Explicitly triggered from the app menu ("Check for Updates…").
    /// Always runs immediately (ignoring the 24-hour launch throttle, active
    /// rate-limit backoff, and skipped version) and reports up-to-date or error
    /// states via `manualCheckAlert`.
    func checkManually() async {
        guard !isCheckingManually, !isDownloadingUpdate else { return }
        checkGeneration &+= 1
        let generation = checkGeneration
        isCheckingManually = true
        defer { isCheckingManually = false }

        isHostKeyResolved = true
        manualCheckAlert = nil

        do {
            let update = try await updateService.checkForUpdate(
                currentVersion: currentVersion,
                skippedVersion: nil
            )
            guard generation == checkGeneration, !isDownloadingUpdate else { return }
            settingsService.saveUpdateCheckBackoffUntil(nil)
            if let update {
                pendingUpdate = update
                showUpdateSheet = true
            } else {
                pendingUpdate = nil
                showUpdateSheet = false
                settingsService.saveLastUpdateCheckAt(now())
                let versionLabel = VersionComparator.normalize(currentVersion)
                manualCheckAlert = ManualCheckAlert(
                    title: String(localized: "You're Up to Date"),
                    message: String(
                        format: String(localized: "DockBridge %@ is currently the newest version available."),
                        versionLabel
                    )
                )
            }
        } catch let error as AppUpdateServiceError {
            guard generation == checkGeneration else { return }
            recordRateLimitBackoffIfNeeded(for: error)
            AppLogging.update.error("manual update check failed: \(error.localizedDescription, privacy: .public)")
            manualCheckAlert = ManualCheckAlert(
                title: String(localized: "Update Check Failed"),
                message: error.localizedDescription
            )
        } catch {
            guard generation == checkGeneration else { return }
            AppLogging.update.error("manual update check failed: \(error.localizedDescription, privacy: .public)")
            manualCheckAlert = ManualCheckAlert(
                title: String(localized: "Update Check Failed"),
                message: String(
                    format: String(localized: "Could not check for updates: %@"),
                    error.localizedDescription
                )
            )
        }
    }

    func onHostKeyDismissed() {
        isHostKeyResolved = true
        presentPendingUpdateIfAllowed()
    }

    var inAppUpdateInstallationEnabled: Bool {
        inAppInstallEnabledProvider()
    }

    func downloadUpdate() async {
        guard let pendingUpdate, !isDownloadingUpdate else { return }

        if !inAppUpdateInstallationEnabled
            || pendingUpdate.downloadURL == pendingUpdate.releasePageURL {
            AppLogging.update.info(
                "opening update release page: \(pendingUpdate.releasePageURL.absoluteString, privacy: .public)"
            )
            openURL(pendingUpdate.releasePageURL)
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

    /// "Later": dismiss the sheet WITHOUT persisting a skip or throttle timestamp,
    /// so the update is offered again on the next launch/check.
    func skipUpdate() {
        settingsService.saveLastUpdateCheckAt(nil)
        dismissSheet()
    }

    /// "Skip This Version": persist the skip and check timestamp so this version
    /// is not offered again (unless the user checks manually or a newer version appears).
    func skipVersion() {
        guard let pendingUpdate else { return }
        settingsService.saveSkippedUpdateVersion(pendingUpdate.version)
        settingsService.saveLastUpdateCheckAt(now())
        dismissSheet()
    }

    func dismissSheet() {
        pendingUpdate = nil
        showUpdateSheet = false
        downloadErrorMessage = nil
    }

    private func presentPendingUpdateIfAllowed() {
        guard pendingUpdate != nil, isHostKeyResolved else { return }
        showUpdateSheet = true
    }

    private func recordRateLimitBackoffIfNeeded(for error: AppUpdateServiceError) {
        guard case .rateLimited(let retryAfter) = error else { return }
        let checkTime = now()
        let delay = AppUpdateService.parseRetryAfter(retryAfter, now: checkTime)
        if delay > 0 {
            settingsService.saveUpdateCheckBackoffUntil(checkTime.addingTimeInterval(delay))
        }
    }
}
