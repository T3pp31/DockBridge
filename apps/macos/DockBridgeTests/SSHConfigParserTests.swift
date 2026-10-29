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

    func testIncludesOnlyHostsWithHostName() {
        let hosts = SSHConfigParser.parse("""
        Host no-hostname
            User bob

        Host with-hostname
            HostName real.example.com
        """)

        XCTAssertEqual(hosts.map(\.alias), ["with-hostname"])
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
}
