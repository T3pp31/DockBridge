import SwiftUI

struct ConnectionStatusBar: View {
    let status: ConnectionStatus
    var transferSummary: String?

    var body: some View {
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

            if let transferSummary {
                Text(transferSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
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
