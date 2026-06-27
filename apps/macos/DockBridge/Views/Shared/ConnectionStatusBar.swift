import SwiftUI

struct ConnectionStatusBar: View {
    let status: ConnectionStatus
    var transferSummary: String?

    var body: some View {
        HStack(spacing: 8) {
            ConnectionStatusIndicator(status: status)

            Text(status.statusTitle)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .accessibilityHidden(true)

            if let transferSummary {
                Text(transferSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel("Transfer activity: \(transferSummary)")
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
