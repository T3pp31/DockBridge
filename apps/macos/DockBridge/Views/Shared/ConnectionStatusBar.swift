import SwiftUI

struct ConnectionStatusBar: View {
    let status: ConnectionStatus
    let localPath: String
    let remotePath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 8, height: 8)

                if status.isConnecting {
                    ProgressView()
                        .controlSize(.small)
                }

                Text(status.statusTitle)
                    .font(.subheadline)
                    .foregroundStyle(.primary)

                Spacer()
            }

            PathSummaryRow(label: "Local", path: localPath, showRevealInFinder: true)

            if status.isConnected, let remotePath {
                PathSummaryRow(label: "Remote", path: remotePath)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var indicatorColor: Color {
        switch status {
        case .disconnected:
            return .secondary
        case .connecting:
            return .orange
        case .connected:
            return .green
        }
    }
}
