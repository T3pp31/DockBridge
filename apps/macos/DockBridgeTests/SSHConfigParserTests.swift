import XCTest
@testable import DockBridge

final class SSHConfigParserTests: XCTestCase {
    func testParsesBasicHost() {
        let hosts = SSHConfigParser.parse("""
        Host myserver
            HostName 192.168.1.10
            User alice
            Port 2222
            IdentityFile ~/.ssh/id_ed25519
        """)

        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts.first?.alias, "myserver")
        XCTAssertEqual(hosts.first?.hostName, "192.168.1.10")
        XCTAssertEqual(hosts.first?.user, "alice")
        XCTAssertEqual(hosts.first?.port, 2222)
        XCTAssertEqual(hosts.first?.identityFile, NSHomeDirectory() + "/.ssh/id_ed25519")
    }

    func testSkipsCommentsAndParsesQuotedValues() {
        let hosts = SSHConfigParser.parse("""
        # comment

        Host quoted # trailing comment
            HostName "server.example.com"
            IdentityFile "~/.ssh/My Key" # another comment
        """)

        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts.first?.alias, "quoted")
        XCTAssertEqual(hosts.first?.hostName, "server.example.com")
        XCTAssertEqual(hosts.first?.identityFile, NSHomeDirectory() + "/.ssh/My Key")
    }

    func testSkipsWildcardAndNegatedPatternsButKeepsFollowingExactHost() {
        let hosts = SSHConfigParser.parse("""
        Host first
            HostName first.example.com

        Host * web-?? !excluded
            HostName wildcard.example.com

        Host exact
            HostName exact.example.com
        """)

        XCTAssertEqual(hosts.map(\.alias), ["first", "exact"])
    }

    func testMultipleExactAliasesCreateSeparateHosts() {
        let hosts = SSHConfigParser.parse("""
        Host alias-one alias-two
            HostName server.example.com
            User alice
        """)

        XCTAssertEqual(hosts.map(\.alias), ["alias-one", "alias-two"])
        XCTAssertTrue(hosts.allSatisfy { $0.hostName == "server.example.com" })
        XCTAssertTrue(hosts.allSatisfy { $0.user == "alice" })
    }

    func testSkipsHostNameWithUnsupportedExpansion() {
        let hosts = SSHConfigParser.parse("""
        Host percent-token
            HostName %h.example.com

        Host environment-token
            HostName ${SSH_HOST}
        """)

        XCTAssertTrue(hosts.isEmpty)
    }

    func testIncludesHostsWithoutHostNameWhenDirectivesPresent() {
        let hosts = SSHConfigParser.parse("""
        Host no-hostname
            User bob

        Host with-hostname
            HostName real.example.com
        """)

        XCTAssertEqual(hosts.map(\.alias), ["no-hostname", "with-hostname"])

        let profiles = SSHConfigParser.toProfiles(hosts)
        XCTAssertEqual(profiles[0].host, "no-hostname")
    }

    func testHostNameFallbackAppliesUniversalDefaultsToExactAliases() {
        let hosts = SSHConfigParser.parse("""
        Host *
            User deploy
            IdentityFile ~/.ssh/id_ed25519

        Host *.example.com
            User deploy

        Host !*.secret.example.com
            Port 2222

        Host empty

        Host web01
            User deploy
        """)

        // Both exact aliases inherit the unconditional defaults. Patterns do
        // not become profiles; an empty exact block is usable via defaults.
        XCTAssertEqual(hosts.map(\.alias), ["empty", "web01"])
        XCTAssertTrue(hosts.allSatisfy { $0.hostName == nil && $0.user == "deploy" })
        XCTAssertEqual(SSHConfigParser.toProfiles(hosts).map(\.host), ["empty", "web01"])
    }

    func testHostNameFallbackImportsEachSupportedDirectiveAndExactAlias() {
        let hosts = SSHConfigParser.parse("""
        Host user-only
            User deploy

        Host port-only
            Port 2222

        Host key-only
            IdentityFile ~/.ssh/id_ed25519

        Host alias-one alias-two
            User deploy
        """)

        XCTAssertEqual(hosts.map(\.alias), ["user-only", "port-only", "key-only", "alias-one", "alias-two"])
        XCTAssertTrue(hosts.allSatisfy { $0.hostName == nil })
        let profiles = SSHConfigParser.toProfiles(hosts)
        XCTAssertEqual(profiles.map(\.host), hosts.map(\.alias))
        XCTAssertEqual(profiles[0].username, "deploy")
        XCTAssertEqual(profiles[1].port, 2222)
        XCTAssertEqual(profiles[2].authType, .privateKey)
        XCTAssertEqual(profiles[2].privateKeyPath, NSHomeDirectory() + "/.ssh/id_ed25519")
    }

    func testDirectiveKeysAreCaseInsensitiveAndSupportEqualsSyntax() {
        let hosts = SSHConfigParser.parse("""
        hOsT=CaseHost
            HOSTNAME = case.example.com
            USER=alice
        """)

        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts.first?.hostName, "case.example.com")
        XCTAssertEqual(hosts.first?.user, "alice")
    }

    func testTabSeparatedDirectives() {
        let hosts = SSHConfigParser.parse("""
        Host\tTabHost
        \tHostName\ttab.example.com
        """)

        XCTAssertEqual(hosts.map(\.alias), ["TabHost"])
    }

    func testInvalidExplicitPortsSkipTheirHostBlocks() {
        let hosts = SSHConfigParser.parse("""
        Host zero
            HostName zero.example.com
            Port 0

        Host text
            HostName text.example.com
            Port abc

        Host overflow
            HostName overflow.example.com
            Port 65536

        Host valid
            HostName valid.example.com
            Port 65535
        """)

        XCTAssertEqual(hosts.map(\.alias), ["valid"])
        XCTAssertEqual(hosts.first?.port, 65535)
    }

    func testMatchSectionCannotMutatePrecedingHost() {
        let hosts = SSHConfigParser.parse("""
        Host first
            HostName first.example.com
            User alice

        Match host first
            HostName attacker.example.com
            User attacker

        Host second
            HostName second.example.com
        """)

        XCTAssertEqual(hosts.map(\.alias), ["first", "second"])
        XCTAssertEqual(hosts.first?.hostName, "first.example.com")
        XCTAssertEqual(hosts.first?.user, "alice")
    }

    func testRepeatedAliasMergesMissingValuesAndKeepsFirstValues() {
        let hosts = SSHConfigParser.parse("""
        Host duplicate
            User alice

        Host DUPLICATE
            HostName first.example.com
            User ignored
            Port 2200

        Host duplicate
            HostName ignored.example.com
            Port 2201
        """)

        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts.first?.alias, "duplicate")
        XCTAssertEqual(hosts.first?.hostName, "first.example.com")
        XCTAssertEqual(hosts.first?.user, "alice")
        XCTAssertEqual(hosts.first?.port, 2200)
    }

    func testNormalizedAliasesApplyEachBlockOnceAndMergeDefaultsInFileOrder() {
        let hosts = SSHConfigParser.parse("""
        IdentityFile /keys/global
        Host "  Beta  " beta BETA alpha
            HostName first.example.com
            User specific
            IdentityFile /keys/shared
        Host *
            User default
            Port 2200
            IdentityFile /keys/middle
        Host ALPHA " beta "
            HostName ignored.example.com
            Port 2222
            IdentityFile /keys/repeated
        Host *
            IdentityFile /keys/final
        """)

        XCTAssertEqual(hosts, ["  Beta  ", "alpha"].map { alias in
            SSHConfigHost(
                alias: alias,
                hostName: "first.example.com",
                user: "specific",
                port: 2200,
                identityFiles: ["/keys/global", "/keys/shared", "/keys/middle", "/keys/repeated", "/keys/final"]
            )
        })
    }

    func testInvalidBlocksOnlyRejectMatchingAliasesBeforeLaterDefaults() {
        let hosts = SSHConfigParser.parse("""
        Host valid
            HostName valid.example.com
        Host broken SHARED
            Port invalid
        Host shared
            User cannot-rescue
        Host *.example.com !valid
            Port invalid
        Match host valid
            Port invalid
        Host "unterminated
            Port invalid
        Host recovered
            User recovered-user
        Host *
            Port 2200
        """)

        XCTAssertEqual(hosts, [
            SSHConfigHost(alias: "valid", hostName: "valid.example.com", port: 2200),
            SSHConfigHost(alias: "recovered", user: "recovered-user", port: 2200),
        ])
    }

    func testLargeConfigPreservesAliasAndDirectiveOrder() {
        let hostCount = 1_000
        var sections = ["IdentityFile /keys/global", "Host *\n    User default-user"]
        for index in 0..<hostCount {
            sections.append("""
            Host Node-\(index) NODE-\(index)
                HostName node-\(index).example.com
                IdentityFile /keys/node-\(index)
            Match host Node-\(index)
                User ignored
            """)
        }
        sections.append("""
        Host *
            Port 2200
            IdentityFile /keys/middle
        """)
        for index in (0..<hostCount).reversed() {
            sections.append("""
            Host node-\(index)
                Port 2222
                IdentityFile /keys/repeated-\(index)
            """)
        }
        let contents = sections.joined(separator: "\n")
        var hosts: [SSHConfigHost] = []

        // Record parsing cost without a machine-dependent wall-clock limit.
        measure {
            hosts = SSHConfigParser.parse(contents)
        }

        XCTAssertEqual(hosts, (0..<hostCount).map { index in
            SSHConfigHost(
                alias: "Node-\(index)",
                hostName: "node-\(index).example.com",
                user: "default-user",
                port: 2200,
                identityFiles: ["/keys/global", "/keys/node-\(index)", "/keys/middle", "/keys/repeated-\(index)"]
            )
        })
    }

    func testQuotedEmptyValuesDoNotBlockLaterValidValues() {
        let hosts = SSHConfigParser.parse("""
        Host empty
            HostName ""
            User ""
            IdentityFile ""
            HostName valid.example.com
            User alice
            IdentityFile ~/.ssh/id_ed25519
        """)

        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].hostName, "valid.example.com")
        XCTAssertEqual(hosts[0].user, "alice")
        XCTAssertEqual(hosts[0].identityFile, NSHomeDirectory() + "/.ssh/id_ed25519")
    }

    func testExpandsCurrentUserAndNamedUserIdentityPaths() throws {
        let currentUser = NSUserName()
        let namedHome = try XCTUnwrap(FileManager.default.homeDirectory(forUser: currentUser))
        let hosts = SSHConfigParser.parse("""
        Host current
            HostName current.example.com
            IdentityFile ~/.ssh/current

        Host named
            HostName named.example.com
            IdentityFile ~\(currentUser)/.ssh/named
        """)

        XCTAssertEqual(hosts.first?.identityFile, NSHomeDirectory() + "/.ssh/current")
        XCTAssertEqual(hosts.dropFirst().first?.identityFile, namedHome.path + "/.ssh/named")
    }

    func testUnknownTildeUserDoesNotProduceUnresolvedKeyPath() {
        let hosts = SSHConfigParser.parse("""
        Host unknown-user
            HostName server.example.com
            IdentityFile ~dockbridge-user-that-does-not-exist/.ssh/key
        """)

        XCTAssertEqual(hosts.count, 1)
        XCTAssertNil(hosts.first?.identityFile)
    }

    func testEmptyConfigReturnsNoHosts() {
        XCTAssertTrue(SSHConfigParser.parse("").isEmpty)
        XCTAssertTrue(SSHConfigParser.parse("# comment only").isEmpty)
    }

    func testToProfilesMapsDefaultsAndPrivateKeyAuthentication() {
        let profiles = SSHConfigParser.toProfiles(SSHConfigParser.parse("""
        Host password
            HostName password.example.com

        Host key
            HostName key.example.com
            IdentityFile ~/.ssh/id_ed25519
        """))

        XCTAssertEqual(profiles.count, 2)
        XCTAssertEqual(profiles.first?.port, 22)
        XCTAssertEqual(profiles.first?.authType, .password)
        XCTAssertEqual(profiles.dropFirst().first?.authType, .privateKey)
        XCTAssertNotNil(profiles.dropFirst().first?.privateKeyPath)
        XCTAssertNil(profiles.dropFirst().first?.privateKeyBookmark)
    }
    func testTrailingUniversalHostProvidesDefaultsWithoutCreatingProfile() throws {
        let hosts = SSHConfigParser.parse("""
        Host server
            HostName server.example.com
            User specific
            IdentityFile ~/.ssh/specific
        Host *
            User default
            Port 2200
            IdentityFile ~/.ssh/default
        """)
        XCTAssertEqual(hosts.count, 1)
        let host = try XCTUnwrap(hosts.first)
        XCTAssertEqual(host.alias, "server")
        XCTAssertEqual(host.user, "specific")
        XCTAssertEqual(host.port, 2200)
        XCTAssertEqual(host.identityFiles, [NSHomeDirectory() + "/.ssh/specific", NSHomeDirectory() + "/.ssh/default"])
    }

    func testLeadingDefaultsKeepFirstObtainedValues() throws {
        let hosts = SSHConfigParser.parse("""
        User global
        Host *
            Port 2200
        Host server
            HostName server.example.com
            User specific
            Port 2222
        """)
        let host = try XCTUnwrap(hosts.first)
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(host.user, "global")
        XCTAssertEqual(host.port, 2200)
    }

    func testWildcardHostBlockProvidesDefaultsForMatchingAliases() throws {
        let hosts = SSHConfigParser.parse("""
        Host prod-*
            User deploy
            Port 2222
            IdentityFile ~/.ssh/id_prod
        Host prod-web
            HostName prod-web.example.com
        Host prod-db
            HostName prod-db.example.com
        """)

        XCTAssertEqual(hosts.map(\.alias), ["prod-web", "prod-db"])
        XCTAssertTrue(hosts.allSatisfy { $0.user == "deploy" })
        XCTAssertTrue(hosts.allSatisfy { $0.port == 2222 })
        XCTAssertTrue(hosts.allSatisfy { $0.identityFile == NSHomeDirectory() + "/.ssh/id_prod" })
    }

    func testNegatedWildcardHostBlockDoesNotApplyToMatchingAlias() throws {
        let hosts = SSHConfigParser.parse("""
        Host prod-* !prod-web
            User deploy
            Port 2222
        Host prod-web
            HostName prod-web.example.com
        Host prod-db
            HostName prod-db.example.com
        """)

        let web = try XCTUnwrap(hosts.first { $0.alias == "prod-web" })
        XCTAssertNil(web.user)
        XCTAssertNil(web.port)
        let db = try XCTUnwrap(hosts.first { $0.alias == "prod-db" })
        XCTAssertEqual(db.user, "deploy")
        XCTAssertEqual(db.port, 2222)
    }

    func testNegatedPatternOnTheSameHeaderSuppressesExactAlias() throws {
        // Given: a header naming an exact alias and a negated pattern that
        // matches it (OpenSSH excludes the block for that alias)
        let hosts = SSHConfigParser.parse("""
        Host foo !f*
            HostName attacker.example.com
            User attacker
            Port 2222
        Host foo
            HostName real.example.com
        """)

        // Then: only the later exact block applies, not the negated one
        let host = try XCTUnwrap(hosts.first)
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(host.alias, "foo")
        XCTAssertEqual(host.hostName, "real.example.com")
        XCTAssertNil(host.user)
        XCTAssertNil(host.port)
    }

    func testNegatedPatternOnTheSameHeaderSuppressesMatchingWildcardAlias() throws {
        let hosts = SSHConfigParser.parse("""
        Host foo* !foo
            HostName attacker.example.com
        Host foo
            HostName real.example.com
        """)

        let host = try XCTUnwrap(hosts.first)
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(host.alias, "foo")
        XCTAssertEqual(host.hostName, "real.example.com")
    }

    func testNonMatchingNegatedPatternOnTheSameHeaderStillApplies() throws {
        let hosts = SSHConfigParser.parse("""
        Host foo !bar
            User deploy
            Port 2222
        """)

        let host = try XCTUnwrap(hosts.first)
        XCTAssertEqual(host.alias, "foo")
        XCTAssertEqual(host.user, "deploy")
        XCTAssertEqual(host.port, 2222)
    }

    func testNegatedOnlyHeaderNeverApplies() throws {
        // Given: a header with only a negated pattern
        let hosts = SSHConfigParser.parse("""
        Host !f*
            User nobody
        Host foo
            HostName foo.example.com
        Host bar
            HostName bar.example.com
        """)

        // Then: it is not treated as a default for any alias, including
        // aliases that the negated pattern does not match
        XCTAssertEqual(hosts.map(\.alias), ["foo", "bar"])
        XCTAssertEqual(hosts.map(\.hostName), ["foo.example.com", "bar.example.com"])
        XCTAssertEqual(hosts.map(\.user), [nil, nil])
    }

    func testQuestionMarkPatternMatchesSingleCharacterAliases() throws {
        let hosts = SSHConfigParser.parse("""
        Host web-?
            User web
        Host web-1
            HostName web1.example.com
        Host web-12
            HostName web12.example.com
        """)

        let single = try XCTUnwrap(hosts.first { $0.alias == "web-1" })
        XCTAssertEqual(single.user, "web")
        let longer = try XCTUnwrap(hosts.first { $0.alias == "web-12" })
        XCTAssertNil(longer.user)
    }

    func testWildcardDefaultsUseFirstObtainedValueAcrossFileOrder() throws {
        let hosts = SSHConfigParser.parse("""
        Host *
            User any
        Host prod-*
            User prod
        Host prod-web
            HostName web.example.com
            User exact
        """)

        let host = try XCTUnwrap(hosts.first)
        XCTAssertEqual(host.user, "any")
    }

    func testWildcardAndExactPatternsOnOneHeaderApplyOnce() throws {
        let hosts = SSHConfigParser.parse("""
        Host prod-web prod-*
            User deploy
            IdentityFile ~/.ssh/id_deploy
        Host prod-web
            HostName web.example.com
        """)

        let host = try XCTUnwrap(hosts.first)
        XCTAssertEqual(host.user, "deploy")
        XCTAssertEqual(host.identityFiles, [NSHomeDirectory() + "/.ssh/id_deploy"])
    }

    func testWildcardAndNegatedPatternsAreCaseSensitive() throws {
        let hosts = SSHConfigParser.parse("""
        Host PROD-*
            User deploy
        Host * !PROD-WEB
            Port 2222
        Host prod-web
            HostName web.example.com
        """)

        let host = try XCTUnwrap(hosts.first)
        XCTAssertNil(host.user)
        XCTAssertEqual(host.port, 2222)
    }

    func testQuestionMarkMatchesOneUTF8Byte() throws {
        let hosts = SSHConfigParser.parse("""
        Host srv-?
            Port 2222
        Host srv-??
            User twobytes
        Host srv-\u{00E9}
            HostName example.com
        """)

        let host = try XCTUnwrap(hosts.first)
        XCTAssertNil(host.port)
        XCTAssertEqual(host.user, "twobytes")
    }

    func testMatchValuesDoNotBecomeGlobalDefaults() throws {
        let hosts = SSHConfigParser.parse("""
        Match user unrelated
            User ignored
            Port 2200
        Host server
            HostName server.example.com
        """)
        let host = try XCTUnwrap(hosts.first)
        XCTAssertNil(host.user)
        XCTAssertNil(host.port)
    }

    func testLaterInvalidValuesDoNotOverrideEarlierExactOrGlobalValues() throws {
        let hosts = SSHConfigParser.parse("""
        Host *
            Port 2200
        Host server
            HostName server.example.com
            HostName %h.unsupported
            Port invalid
        Host server
            HostName ${UNSUPPORTED}
            Port 0
        """)
        let host = try XCTUnwrap(hosts.first)
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(host.hostName, "server.example.com")
        XCTAssertEqual(host.port, 2200)
    }

    func testWhitespaceHostNameDoesNotPreventLaterValidValue() throws {
        let hosts = SSHConfigParser.parse("""
        Host server
            HostName "   "
            HostName server.example.com
        """)
        XCTAssertEqual(try XCTUnwrap(hosts.first).hostName, "server.example.com")
    }

    func testMalformedHostHeaderDoesNotApplyFollowingValuesToPreviousAlias() throws {
        let hosts = SSHConfigParser.parse("""
        Host server
            HostName server.example.com
        Host "unterminated
            User ignored
        """)
        XCTAssertEqual(hosts.count, 1)
        XCTAssertNil(try XCTUnwrap(hosts.first).user)
    }

    func testHostNameWithoutArgumentsDoesNotStartAnOrphanBlock() throws {
        // Given: a Host block whose HostName has no value
        let hosts = SSHConfigParser.parse("""
        Host server
            HostName
            User alice
            Port 2222
        """)

        // Then: the following directives stay in the same block
        let host = try XCTUnwrap(hosts.first)
        XCTAssertEqual(hosts.count, 1)
        XCTAssertNil(host.hostName)
        XCTAssertEqual(host.user, "alice")
        XCTAssertEqual(host.port, 2222)
    }

    func testHostNameWithCommentOnlyDoesNotStartAnOrphanBlock() throws {
        let hosts = SSHConfigParser.parse("""
        Host server
            HostName # placeholder
            User alice
        """)

        let host = try XCTUnwrap(hosts.first)
        XCTAssertNil(host.hostName)
        XCTAssertEqual(host.user, "alice")
    }

    func testHostNameWithUnterminatedQuoteDoesNotStartAnOrphanBlock() throws {
        let hosts = SSHConfigParser.parse("""
        Host server
            HostName "example.com
            User alice
        """)

        let host = try XCTUnwrap(hosts.first)
        XCTAssertNil(host.hostName)
        XCTAssertEqual(host.user, "alice")
    }

    func testHostKeyAlgorithmsWithoutArgumentsDoesNotStartAnOrphanBlock() throws {
        let hosts = SSHConfigParser.parse("""
        Host server
            HostKeyAlgorithms
            HostName server.example.com
        """)

        XCTAssertEqual(try XCTUnwrap(hosts.first).hostName, "server.example.com")
    }

    func testMalformedHostNameInUniversalBlockKeepsDefaults() throws {
        // Given: a `Host *` block whose HostName fails to parse
        let hosts = SSHConfigParser.parse("""
        Host *
            HostName # placeholder
            User default-user
        Host server
            HostName server.example.com
        """)

        // Then: later directives in the universal block still apply
        XCTAssertEqual(try XCTUnwrap(hosts.first).user, "default-user")
    }

}
