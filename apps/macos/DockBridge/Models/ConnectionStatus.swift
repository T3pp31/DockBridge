import Foundation
import SwiftUI

enum ConnectionStatus: Equatable {
    case disconnected
    case connecting(endpoint: String)
    case connected(endpoint: String)

    var isConnected: Bool {
        if case .connected = self { true } else { false }
    }

    var isConnecting: Bool {
        if case .connecting = self { true } else { false }
    }

    var endpointLabel: String? {
        switch self {
        case .disconnected:
            return nil
        case .connecting(let endpoint), .connected(let endpoint):
            return endpoint
        }
    }

    var statusTitle: String {
        switch self {
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting…"
        case .connected(let endpoint):
            return "Connected: \(endpoint)"
        }
    }

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
