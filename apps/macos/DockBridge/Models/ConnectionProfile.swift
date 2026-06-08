import Foundation

struct ConnectionProfile: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var host: String
    var port: UInt16
    var username: String
    var authType: AuthType
    var privateKeyPath: String?
    var lastConnectedAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: UInt16 = 22,
        username: String,
        authType: AuthType = .password,
        privateKeyPath: String? = nil,
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authType = authType
        self.privateKeyPath = privateKeyPath
        self.lastConnectedAt = lastConnectedAt
    }

    var displayName: String {
        name.isEmpty ? "\(username)@\(host)" : name
    }

    var isRootUser: Bool {
        username == "root"
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
