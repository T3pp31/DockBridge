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

private extension ConnectionStatus {
    var systemImageName: String {
        switch self {
        case .disconnected:
            return "circle"
        case .connecting:
            return "arrow.triangle.2.circlepath"
        case .connected:
            return "checkmark.circle.fill"
        }
    }

    var indicatorColor: Color {
        switch self {
        case .disconnected:
            return Color(nsColor: .secondaryLabelColor)
        case .connecting:
            return Color(nsColor: .systemOrange)
        case .connected:
            return Color(nsColor: .systemGreen)
        }
    }

    var accessibilityStatusLabel: String {
        switch self {
        case .disconnected:
            return "Disconnected"
        case .connecting(let endpoint):
            return "Connecting to \(endpoint)"
        case .connected(let endpoint):
            return "Connected to \(endpoint)"
        }
    }
}
