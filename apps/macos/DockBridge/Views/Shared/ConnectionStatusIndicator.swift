import SwiftUI

struct ConnectionStatusIndicator: View {
    let status: ConnectionStatus
    var showsConnectingProgress = true

    var body: some View {
        Group {
            if status.isConnecting, showsConnectingProgress {
                HStack(spacing: 4) {
                    Image(systemName: status.systemImageName)
                        .foregroundStyle(status.indicatorColor)
                    ProgressView()
                        .controlSize(.small)
                }
            } else {
                Image(systemName: status.systemImageName)
                    .foregroundStyle(status.indicatorColor)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.accessibilityStatusLabel)
    }
}
