import SwiftUI

struct UpdateAvailableView: View {
    let update: AppUpdateInfo
    let currentVersion: String
    var releaseNotes: String? = nil
    let isDownloading: Bool
    let downloadErrorMessage: String?
    let onDownload: () -> Void
    let onLater: () -> Void

    var body: some View {
        DialogCard(title: "Update Available") {
            Text("A newer version of DockBridge is available.")
                .fixedSize(horizontal: false, vertical: true)

            DialogDetailSection("Version") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Current: \(currentVersion)")
                    Text("Latest: \(update.version)")
                        .bold()
                }
            }

            if let releaseNotes, !releaseNotes.isEmpty {
                DialogDetailSection("Release Notes") {
                    ScrollView {
                        Text(releaseNotes)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 160)
                }
            }

            DialogFootnote(
                text: "Download the latest DMG, verify its signature, then replace the app in Applications."
            )

            if let downloadErrorMessage {
                Text(downloadErrorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isDownloading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Downloading and verifying update...")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
        } footer: {
            Button("Later", role: .cancel, action: onLater)
                .disabled(isDownloading)
            Button("Download", action: onDownload)
                .keyboardShortcut(.defaultAction)
                .disabled(isDownloading)
        }
    }
}
