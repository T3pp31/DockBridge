import Foundation

enum AuthType: String, Codable, CaseIterable, Identifiable, Sendable {
    case password
    case privateKey

    var id: String { rawValue }

    var label: String {
        switch self {
        case .password: String(localized: "Password")
        case .privateKey: String(localized: "Private Key")
        }
    }
}
