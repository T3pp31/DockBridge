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
                // Split space-separated aliases; blocks containing wildcards
                // or patterns are skipped (not importable as a single host).
                let aliases = value.split(separator: " ").map(String.init)
                if aliases.contains(where: { $0.contains("*") || $0.contains("?") }) {
                    current = nil
                } else if aliases.count == 1 {
                    current = SSHConfigHost(alias: aliases[0])
                } else {
                    // Multiple aliases (`Host foo bar`) are uncommon for user
                    // configs; import only the first one to keep profiles clean.
                    current = SSHConfigHost(alias: aliases[0])
                }
                continue
            }

            guard var host = current else { continue }
            switch key {
            case "hostname":
                // `%h` / `%n` token expansion is unsupported for imports.
                if !value.contains("%") {
                    host.hostName = value
                }
            case "user":
                host.user = value
            case "port":
                host.port = UInt16(value)
            case "identityfile":
                host.identityFile = expandTilde(value)
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
                port: host.port ?? 22,
                username: host.user ?? NSUserName(),
                privateKeyPath: host.identityFile
            )
        }
    }

    /// Expands a leading `~` to the current user's home directory
    /// (`~user` and bare `~` without a path suffix are left untouched).
    private static func expandTilde(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return FileManager.default.homeDirectoryForCurrentUser.path + path.dropFirst()
    }
}
