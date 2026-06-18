import AppKit
import Foundation

@MainActor
final class UpdateCheckViewModel: ObservableObject {
    @Published private(set) var pendingUpdate: AppUpdateInfo?
    @Published var showUpdateSheet = false

    private let updateService: AppUpdateService
    private let settingsService: AppSettingsService

    init(
        updateService: AppUpdateService = AppUpdateService(),
        settingsService: AppSettingsService = .shared
    ) {
        self.updateService = updateService
        self.settingsService = settingsService
    }

    func checkOnLaunch(isHostKeyBlocking: Bool) async {
        do {
            let update = try await updateService.checkForUpdate(
                skippedVersion: settingsService.loadSkippedUpdateVersion()
            )
            guard let update else { return }
            pendingUpdate = update
            presentIfAllowed(isHostKeyBlocking: isHostKeyBlocking)
        } catch {
            return
        }
    }

    func onHostKeyDismissed() {
        presentIfAllowed(isHostKeyBlocking: false)
    }

    func downloadUpdate() {
        guard let pendingUpdate else { return }
        NSWorkspace.shared.open(pendingUpdate.downloadURL)
    }

    func skipUpdate() {
        guard let pendingUpdate else { return }
        settingsService.saveSkippedUpdateVersion(pendingUpdate.version)
        dismissSheet()
    }

    func dismissSheet() {
        showUpdateSheet = false
    }

    private func presentIfAllowed(isHostKeyBlocking: Bool) {
        guard pendingUpdate != nil, !isHostKeyBlocking else { return }
        showUpdateSheet = true
    }
}
