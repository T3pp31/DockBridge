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
/// ignored. Wildcard and negated Host patterns are not importable profiles,
/// but their directives apply to matching exact aliases as defaults
/// (issue #688).
enum SSHConfigParser {
    static func parse(_ contents: String) -> [SSHConfigHost] {
        // Gather importable aliases, then evaluate applicable blocks in file
        // order for each alias, just as OpenSSH does for a selected host.
        struct Block {
            var directives: [Directive] = []
            /// Host header patterns. `nil` marks the implicit global block that
            /// precedes the first Host/Match line and applies to every alias.
            var patterns: [HostPattern]?
        }
        var blocks = [Block(patterns: nil)]
        var exactBlockIndicesByAlias: [String: [Int]] = [:]
        // Index 0 is the implicit global block, which applies to every alias.
        let defaultBlockIndices = [0]
        var wildcardBlockIndices: [Int] = []
        var aliases: [(original: String, normalized: String)] = []
        var seenAliases = Set<String>()
        for rawLine in contents.components(separatedBy: .newlines) {
            guard let directive = parseDirective(rawLine) else {
                // A malformed or argument-less Host/Match header still ends the
                // current block; its directives must not leak into the previous
                // alias. Match the keyword exactly so directives such as
                // HostName or HostKeyAlgorithms that fail to parse do not start
                // an orphan block and drop their block's later values
                // (issue #1371).
                switch leadingKeyword(rawLine) {
                case "host", "match":
                    blocks.append(Block(patterns: []))
                default:
                    break
                }
                continue
            }
            switch directive.key {
            case "host":
                let blockIndex = blocks.count
                let patterns = directive.arguments.map(HostPattern.init(argument:))
                // Wildcard and negated headers cannot become profiles, but their
                // directives still apply to matching aliases as defaults.
                if patterns.contains(where: \.isWildcard) {
                    wildcardBlockIndices.append(blockIndex)
                }
                var blockAliases = Set<String>()
                for alias in directive.arguments where isImportableAlias(alias) {
                    let normalized = normalizedAlias(alias)
                    // A negated pattern on the same Host line excludes this alias
                    // from the block (issue #1370). Do not register the alias or
                    // block index when the header itself does not apply to it.
                    guard blockApplies(patterns, to: normalized) else { continue }
                    if seenAliases.insert(normalized).inserted {
                        aliases.append((original: alias, normalized: normalized))
                    }
                    // A block applies once even when its header repeats an alias.
                    if blockAliases.insert(normalized).inserted {
                        exactBlockIndicesByAlias[normalized, default: []].append(blockIndex)
                    }
                }
                blocks.append(Block(patterns: patterns))
            case "match":
                // Match blocks are conditionally applied and are never treated
                // as defaults for other aliases.
                blocks.append(Block(patterns: []))
            default:
                blocks[blocks.count - 1].directives.append(directive)
            }
        }

        return aliases.compactMap { alias in
            var candidates = [SSHConfigHost(alias: alias.original)]
            // Candidate blocks are the global block, blocks whose header names
            // the alias exactly, and wildcard/negated blocks that may match it.
            let candidateIndices = mergedBlockIndices(
                defaultBlockIndices,
                exactBlockIndicesByAlias[alias.normalized, default: []],
                wildcardBlockIndices
            )
            for blockIndex in candidateIndices {
                guard blockApplies(blocks[blockIndex].patterns, to: alias.normalized) else { continue }
                var valid = true
                for directive in blocks[blockIndex].directives {
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

    /// Merges block index lists into file order, applying each block once.
    ///
    /// A header such as `Host web prod-*` is registered as both an exact and a
    /// wildcard block; deduplicating keeps its directives from applying twice.
    private static func mergedBlockIndices(_ lists: [Int]...) -> [Int] {
        var seen = Set<Int>()
        var indices: [Int] = []
        for list in lists {
            for index in list where seen.insert(index).inserted {
                indices.append(index)
            }
        }
        return indices.sorted()
    }

    private struct HostPattern {
        let negated: Bool
        let pattern: String

        /// OpenSSH lowercases the target host name but compares Host patterns
        /// case-sensitively. Plain positive aliases keep the existing
        /// case-insensitive exact-alias handling; wildcard and negated
        /// patterns preserve their case so `Host PROD-*` does not match
        /// `prod-web`.
        init(argument: String) {
            let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
            negated = trimmed.hasPrefix("!")
            let raw = negated ? String(trimmed.dropFirst()) : trimmed
            if negated || HostPattern.containsWildcard(raw) {
                pattern = raw
            } else {
                pattern = raw.lowercased()
            }
        }

        var isWildcard: Bool { HostPattern.containsWildcard(pattern) }

        static func containsWildcard(_ value: String) -> Bool {
            value.contains("*") || value.contains("?")
        }

        func matches(_ alias: String) -> Bool {
            wildcardMatches(pattern: pattern, alias: alias)
        }
    }

    /// Evaluates a block header against an alias using OpenSSH semantics: the
    /// global block always applies, and a Host block applies when one positive
    /// pattern matches and no negated pattern matches. Blocks with no positive
    /// pattern (Match) never apply.
    private static func blockApplies(_ patterns: [HostPattern]?, to alias: String) -> Bool {
        guard let patterns else { return true }
        var matchedPositive = false
        for pattern in patterns {
            if pattern.negated {
                if pattern.matches(alias) { return false }
            } else if pattern.matches(alias) {
                matchedPositive = true
            }
        }
        return matchedPositive
    }

    /// Matches an OpenSSH host pattern (`*` and `?` wildcards) against an alias.
    /// Like OpenSSH, matching is done on UTF-8 bytes, so `?` matches one byte.
    private static func wildcardMatches(pattern: String, alias: String) -> Bool {
        let pattern = Array(pattern.utf8)
        let alias = Array(alias.utf8)
        let star = UInt8(ascii: "*")
        let question = UInt8(ascii: "?")
        var patternIndex = 0
        var aliasIndex = 0
        var starIndex: Int?
        var starAliasIndex = 0
        while aliasIndex < alias.count {
            if patternIndex < pattern.count {
                let byte = pattern[patternIndex]
                if byte == star {
                    starIndex = patternIndex
                    starAliasIndex = aliasIndex
                    patternIndex += 1
                    continue
                }
                if byte == question || byte == alias[aliasIndex] {
                    patternIndex += 1
                    aliasIndex += 1
                    continue
                }
            }
            guard let starIndex else { return false }
            patternIndex = starIndex + 1
            starAliasIndex += 1
            aliasIndex = starAliasIndex
        }
        while patternIndex < pattern.count, pattern[patternIndex] == star {
            patternIndex += 1
        }
        return patternIndex == pattern.count
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
            if directive.arguments.count == 1,
               directive.arguments[0].trimmingCharacters(in: .whitespaces).isEmpty { return }
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

    /// Returns the lowercased keyword before the first whitespace or `=`.
    ///
    /// Used only to recognize block headers on lines that
    /// [`parseDirective`] rejected, so it must match the keyword exactly:
    /// a prefix test would also match `HostName`, `HostKeyAlgorithms`, and
    /// similar directives (issue #1371).
    private static func leadingKeyword(_ rawLine: String) -> String {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return "" }
        let end = trimmed.firstIndex(where: { $0 == "=" || $0.isWhitespace }) ?? trimmed.endIndex
        return trimmed[..<end].lowercased()
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
