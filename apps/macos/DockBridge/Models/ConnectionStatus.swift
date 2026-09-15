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
            return String(localized: "Disconnected")
        case .connecting:
            return String(localized: "Connecting…")
        case .connected(let endpoint):
            let format = String(localized: "Connected: %@")
            return String(format: format, endpoint)
        }
    }
}
