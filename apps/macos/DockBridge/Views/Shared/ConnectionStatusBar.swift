import SwiftUI

struct ConnectionStatusBar: View {
    let status: ConnectionStatus
    var transferSummary: String?

    var body: some View {
        HStack(spacing: 8) {
            // The indicator is the single accessibility owner for connection
            // status (Issue #231); the visible title below is decorative.
            ConnectionStatusIndicator(status: status)

            Text(status.statusTitle)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .accessibilityHidden(true)

            if let transferSummary {
                Text(transferSummary)
                    .font(DesignTokens.Fonts.monospacedDigit)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .accessibilityLabel("Transfer activity: \(transferSummary)")
            }

            Spacer()
        }
        .padding(.horizontal, DesignTokens.Spacing.statusBarHorizontal)
        .padding(.vertical, DesignTokens.Spacing.statusBarVertical)
        .background(.bar)
    }
}
