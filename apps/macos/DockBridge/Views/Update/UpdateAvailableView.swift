import SwiftUI

struct UpdateAvailableView: View {
    let update: AppUpdateInfo
    let currentVersion: String
    var releaseNotes: String? = nil
    var inAppUpdateInstallationEnabled: Bool = false
    let isDownloading: Bool
    let downloadErrorMessage: String?
    let onDownload: () -> Void
    let onLater: () -> Void
    let onSkipVersion: () -> Void

    var body: some View {
        DialogCard(title: String(localized: "Update Available")) {
            Text(String(localized: "A newer version of DockBridge is available."))
                .fixedSize(horizontal: false, vertical: true)

            DialogDetailSection(String(localized: "Version")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(format: String(localized: "Current: %@"), currentVersion))
                    Text(String(format: String(localized: "Latest: %@"), update.version))
                        .bold()
                }
            }

            if let releaseNotes, !releaseNotes.isEmpty {
                DialogDetailSection(String(localized: "Release Notes")) {
                    ScrollView {
                        Text(releaseNotes)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 160)
                }
            }

            if inAppUpdateInstallationEnabled {
                DialogFootnote(
                    text: String(localized: "Download the latest DMG, verify its signature, then replace the app in Applications.")
                )
            } else {
                DialogFootnote(
                    text: String(localized: "In-app installation is disabled until signed and notarized releases are available. Open the release page to download the DMG manually and verify it before installing.")
                )
            }

            if let downloadErrorMessage {
                Text(downloadErrorMessage)
                    .foregroundStyle(DesignTokens.Status.error)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isDownloading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(String(localized: "Downloading and verifying update..."))
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
        } footer: {
            Button(String(localized: "Later"), role: .cancel, action: onLater)
                .disabled(isDownloading)
            Button(String(localized: "Skip This Version"), action: onSkipVersion)
                .disabled(isDownloading)
            Button(
                inAppUpdateInstallationEnabled
                    ? String(localized: "Download")
                    : String(localized: "Open Release Page"),
                action: onDownload
            )
                .keyboardShortcut(.defaultAction)
                .disabled(isDownloading)
        }
    }
}
