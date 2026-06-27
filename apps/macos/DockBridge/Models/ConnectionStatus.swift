import Foundation

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
}
