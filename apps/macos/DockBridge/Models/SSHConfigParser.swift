import Foundation

/// A parsed `~/.ssh/config` Host block.
struct SSHConfigHost: Identifiable, Equatable {
    let id = UUID()
    let alias: String
    var hostName: String?
    var user: String?
    var port: UInt16?
    var identityFile: String?
}

/// Minimal parser for the subset of OpenSSH `~/.ssh/config` that DockBridge
/// imports (Host/HostName/User/Port/IdentityFile). Unknown directives are
/// ignored; `Host *`/patterns other than a single alias are skipped.
enum SSHConfigParser {
    static func parse(_ contents: String) -> [SSHConfigHost] {
        var hosts: [SSHConfigHost] = []
        var current: SSHConfigHost?

        for rawLine in contents.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let value = String(parts[1]).trimmingCharacters(in: .whitespaces)

            if key == "host" {
                if let current { hosts.append(current) }
                // Only a plain alias (no wildcards / patterns) is importable.
                if value.contains("*") || value.contains("?") {
                    current = nil
                } else {
                    current = SSHConfigHost(alias: value)
                }
                continue
            }

            guard var host = current else { continue }
            switch key {
            case "hostname":
                host.hostName = value
            case "user":
                host.user = value
            case "port":
                host.port = UInt16(value)
            case "identityfile":
                host.identityFile = value
            default:
                break
            }
            current = host
        }
        if let current { hosts.append(current) }

        return hosts.filter { $0.hostName != nil && !$0.alias.isEmpty }
    }

    static func toProfiles(_ hosts: [SSHConfigHost]) -> [ConnectionProfile] {
        hosts.map { host in
            ConnectionProfile(
                name: host.alias,
                host: host.hostName ?? host.alias,
                username: host.user ?? NSUserName(),
                port: host.port ?? 22,
                privateKeyPath: host.identityFile
            )
        }
    }
}
