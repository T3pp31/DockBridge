import Foundation

struct ConnectionProfile: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var host: String
    var port: UInt16
    var username: String
    var authType: AuthType
    var privateKeyPath: String?
    var privateKeyBookmark: Data?
    var lastConnectedAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: UInt16 = 22,
        username: String,
        authType: AuthType = .password,
        privateKeyPath: String? = nil,
        privateKeyBookmark: Data? = nil,
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authType = authType
        self.privateKeyPath = privateKeyPath
        self.privateKeyBookmark = privateKeyBookmark
        self.lastConnectedAt = lastConnectedAt
    }

    var displayName: String {
        name.isEmpty ? "\(username)@\(host)" : name
    }

    var endpointLabel: String {
        "\(username)@\(host):\(port.portLabel)"
    }

    var isRootUser: Bool {
        username == "root"
    }

    var requiresPrivateKeyBookmark: Bool {
        authType == .privateKey
    }

    var hasPrivateKeyBookmark: Bool {
        privateKeyBookmark != nil
    }

    func toRecord(password: String?, passphrase: String?) -> ConnectionProfileRecord {
        let auth: AuthTypeRecord
        switch authType {
        case .password:
            auth = .password(password: password ?? "")
        case .privateKey:
            auth = .privateKey(
                keyPath: privateKeyPath ?? "",
                passphrase: passphrase
            )
        }

        return ConnectionProfileRecord(
            host: host,
            port: port,
            username: username,
            authType: auth
        )
    }
}

extension UInt16 {
    /// Port numbers must never use locale-specific grouping (e.g. 2222, not 2,222).
    var portLabel: String {
        formatted(.number.grouping(.never))
    }
}
