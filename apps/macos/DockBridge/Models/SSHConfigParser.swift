import Foundation

/// A parsed `~/.ssh/config` Host block.
struct SSHConfigHost: Equatable, Sendable {
    let alias: String
    var hostName: String?
    var user: String?
    var port: UInt16?
    /// All IdentityFile values in order. OpenSSH applies IdentityFile
    /// cumulatively (unlike other parameters) (issue #771).
    var identityFiles: [String] = []

    /// Kept as the first value for the single-key profile model.
    var identityFile: String? { identityFiles.first }
}

/// Minimal parser for the subset of OpenSSH `~/.ssh/config` that DockBridge
/// imports (Host/HostName/User/Port/IdentityFile). Unknown directives are
/// ignored; wildcard and negated Host patterns are not importable profiles.
enum SSHConfigParser {
    static func parse(_ contents: String) -> [SSHConfigHost] {
        // Gather importable aliases, then evaluate applicable blocks in file
        // order for each alias, just as OpenSSH does for a selected host.
        struct Block {
            var aliases: [String]
            var appliesToAll: Bool
            var directives: [Directive] = []
        }
        var blocks = [Block(aliases: [], appliesToAll: true)]
        var aliases: [String] = []
        for rawLine in contents.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let directive = parseDirective(rawLine) else {
                if trimmed.hasPrefix("host") || trimmed.hasPrefix("match") {
                    blocks.append(Block(aliases: [], appliesToAll: false))
                }
                continue
            }
            switch directive.key {
            case "host":
                let exactAliases = directive.arguments.filter(isImportableAlias)
                for alias in exactAliases where !aliases.contains(where: {
                    normalizedAlias($0) == normalizedAlias(alias)
                }) {
                    aliases.append(alias)
                }
                // Only an unconditional Host * is supported as a default;
                // other patterns keep the parser's existing import policy.
                blocks.append(Block(aliases: exactAliases, appliesToAll: directive.arguments == ["*"]))
            case "match":
                blocks.append(Block(aliases: [], appliesToAll: false))
            default:
                blocks[blocks.count - 1].directives.append(directive)
            }
        }

        return aliases.compactMap { alias in
            var candidates = [SSHConfigHost(alias: alias)]
            for block in blocks where block.appliesToAll || block.aliases.contains(where: {
                normalizedAlias($0) == normalizedAlias(alias)
            }) {
                var valid = true
                for directive in block.directives {
                    apply(directive: directive, to: &candidates, currentBlockIsValid: &valid)
                    if !valid { return nil }
                }
            }
            guard let host = candidates.first,
                  host.hostName != nil || host.user != nil || host.port != nil || host.identityFile != nil
            else { return nil }
            return host
        }
    }

    static func toProfiles(_ hosts: [SSHConfigHost]) -> [ConnectionProfile] {
        hosts.map { host in
            ConnectionProfile(
                name: host.alias,
                host: host.hostName ?? host.alias,
                port: host.port ?? 22,
                username: host.user ?? NSUserName(),
                authType: host.identityFile == nil ? .password : .privateKey,
                privateKeyPath: host.identityFile
            )
        }
    }

    private struct Directive {
        let key: String
        let arguments: [String]
    }

    private static func apply(
        directive: Directive,
        to hosts: inout [SSHConfigHost],
        currentBlockIsValid: inout Bool
    ) {
        switch directive.key {
        case "hostname":
            if directive.arguments == [""] { return }
            guard directive.arguments.count == 1,
                  let value = directive.arguments.first,
                  !containsUnsupportedExpansion(value) else {
                if hosts.contains(where: { $0.hostName == nil }) {
                    currentBlockIsValid = false
                }
                return
            }
            for index in hosts.indices where hosts[index].hostName == nil {
                hosts[index].hostName = value
            }

        case "user":
            guard directive.arguments.count == 1,
                  let value = directive.arguments.first,
                  !value.trimmingCharacters(in: .whitespaces).isEmpty,
                  !containsUnsupportedExpansion(value) else { return }
            for index in hosts.indices where hosts[index].user == nil {
                hosts[index].user = value
            }

        case "port":
            guard directive.arguments.count == 1,
                  let rawPort = directive.arguments.first,
                  let port = UInt16(rawPort),
                  port > 0 else {
                if hosts.contains(where: { $0.port == nil }) {
                    currentBlockIsValid = false
                }
                return
            }
            for index in hosts.indices where hosts[index].port == nil {
                hosts[index].port = port
            }

        case "identityfile":
            guard directive.arguments.count == 1,
                  let rawPath = directive.arguments.first,
                  !rawPath.trimmingCharacters(in: .whitespaces).isEmpty,
                  rawPath.lowercased() != "none",
                  !containsUnsupportedExpansion(rawPath),
                  let expandedPath = expandTilde(rawPath) else { return }
            for index in hosts.indices {
                hosts[index].identityFiles.append(expandedPath)
            }

        default:
            break
        }
    }

    private static func parseDirective(_ rawLine: String) -> Directive? {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }

        guard let separator = trimmed.firstIndex(where: {
            $0 == "=" || $0.isWhitespace
        }) else { return nil }

        let key = trimmed[..<separator].lowercased()
        var remainder = trimmed[separator...].trimmingCharacters(in: .whitespaces)
        if remainder.hasPrefix("=") {
            remainder.removeFirst()
            remainder = remainder.trimmingCharacters(in: .whitespaces)
        }

        guard !key.isEmpty, let arguments = tokenize(remainder), !arguments.isEmpty else {
            return nil
        }
        return Directive(key: key, arguments: arguments)
    }

    /// Tokenizes the small OpenSSH subset used above, preserving quoted or
    /// backslash-escaped spaces and removing unquoted trailing comments.
    private static func tokenize(_ value: String) -> [String]? {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var isEscaping = false
        var tokenStarted = false

        func finishToken() {
            guard tokenStarted else { return }
            tokens.append(current)
            current.removeAll(keepingCapacity: true)
            tokenStarted = false
        }

        for character in value {
            if isEscaping {
                current.append(character)
                tokenStarted = true
                isEscaping = false
                continue
            }

            if character == "\\" {
                isEscaping = true
                tokenStarted = true
                continue
            }

            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                tokenStarted = true
                continue
            }

            if character == "\"" || character == "'" {
                quote = character
                tokenStarted = true
            } else if character == "#" {
                break
            } else if character.isWhitespace {
                finishToken()
            } else {
                current.append(character)
                tokenStarted = true
            }
        }

        guard quote == nil, !isEscaping else { return nil }
        finishToken()
        return tokens
    }

    private static func isImportableAlias(_ alias: String) -> Bool {
        !alias.isEmpty
            && !alias.hasPrefix("!")
            && !alias.contains("*")
            && !alias.contains("?")
    }

    private static func normalizedAlias(_ alias: String) -> String {
        alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func containsUnsupportedExpansion(_ value: String) -> Bool {
        value.contains("%") || value.contains("${")
    }

    /// Expands `~`, `~/…`, and `~user/…`. Unknown users are not retained as
    /// unresolved paths because they cannot be opened reliably by DockBridge.
    private static func expandTilde(_ path: String) -> String? {
        guard path.hasPrefix("~") else { return path }

        let suffixStart = path.firstIndex(of: "/")
        let userEnd = suffixStart ?? path.endIndex
        let username = String(path[path.index(after: path.startIndex)..<userEnd])
        let homePath: String
        if username.isEmpty {
            homePath = FileManager.default.homeDirectoryForCurrentUser.path
        } else {
            guard let homeURL = FileManager.default.homeDirectory(forUser: username) else {
                return nil
            }
            homePath = homeURL.path
        }

        guard let suffixStart else { return homePath }
        return homePath + String(path[suffixStart...])
    }
}
