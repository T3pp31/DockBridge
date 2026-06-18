import SwiftUI

struct UpdateAvailableView: View {
    let update: AppUpdateInfo
    let currentVersion: String
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

            Text("Download the latest DMG and replace the app in Applications.")
                .foregroundStyle(.secondary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Later", role: .cancel, action: onLater)
                Button("Download", action: onDownload)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 480)
    }
}
