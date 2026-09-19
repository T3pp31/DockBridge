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
        XCTAssertEqual(hosts[0].alias, "myserver")
        XCTAssertEqual(hosts[0].hostName, "192.168.1.10")
        XCTAssertEqual(hosts[0].user, "alice")
        XCTAssertEqual(hosts[0].port, 2222)
        XCTAssertEqual(hosts[0].identityFile, NSHomeDirectory() + "/.ssh/id_ed25519")
    }

    func testSkipsCommentsAndEmptyLines() {
        let hosts = SSHConfigParser.parse("""
        # comment
        # comment

        Host server
            HostName server.example.com
        """)
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].alias, "server")
    }

    func testSkipsWildcardPatterns() {
        let hosts = SSHConfigParser.parse("""
        Host *
            HostName any

        Host web-??
            HostName wildcard

        Host exact
            HostName server.example.com
        """)
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].alias, "exact")
    }

    func testMultipleAliasesImportsFirstOnly() {
        let hosts = SSHConfigParser.parse("""
        Host alias-one alias-two
            HostName server.example.com
        """)
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].alias, "alias-one")
        XCTAssertEqual(hosts[0].hostName, "server.example.com")
    }

    func testSkipsHostNameWithTokenExpansion() {
        let hosts = SSHConfigParser.parse("""
        Host token-host
            HostName %h.example.com
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
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].alias, "with-hostname")
    }

    func testDirectiveKeysAreCaseInsensitive() {
        let hosts = SSHConfigParser.parse("""
        Host CaseHost
            HOSTNAME case.example.com
            User alice
        """)
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].hostName, "case.example.com")
    }

    func testTabSeparatedDirectives() {
        let hosts = SSHConfigParser.parse("""
        Host\tTabHost
        \tHostName\ttab.example.com
        """)
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].alias, "TabHost")
    }

    func testToProfilesMapsDefaults() {
        let hosts = SSHConfigParser.parse("""
        Host simple
            HostName simple.example.com
        """)
        let profiles = SSHConfigParser.toProfiles(hosts)
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].name, "simple")
        XCTAssertEqual(profiles[0].host, "simple.example.com")
        XCTAssertEqual(profiles[0].port, 22)
    }
}
