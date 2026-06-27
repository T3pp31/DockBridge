import SwiftUI

struct UpdateAvailableView: View {
    let update: AppUpdateInfo
    let currentVersion: String
    let isDownloading: Bool
    let downloadErrorMessage: String?
    let onDownload: () -> Void
    let onLater: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Update Available")
                .font(.title2)
                .bold()

            Text("A newer version of DockBridge is available.")
                .fixedSize(horizontal: false, vertical: true)

            GroupBox("Version") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Current: \(currentVersion)")
                    Text("Latest: \(update.version)")
                        .bold()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("Download the latest DMG, verify its signature, then replace the app in Applications.")
                .foregroundStyle(.secondary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

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

            HStack {
                Spacer()
                Button("Later", role: .cancel, action: onLater)
                    .disabled(isDownloading)
                Button("Download", action: onDownload)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isDownloading)
            }
        }
        .padding(24)
        .frame(minWidth: 480)
    }
}
