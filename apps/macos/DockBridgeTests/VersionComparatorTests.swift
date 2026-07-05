import XCTest
@testable import DockBridge

final class VersionComparatorTests: XCTestCase {
    func testNormalizeStripsVPrefix() {
        XCTAssertEqual(VersionComparator.normalize("v0.1.2"), "0.1.2")
        XCTAssertEqual(VersionComparator.normalize("0.1.2"), "0.1.2")
    }

    func testCompareOrdersVersionsAscending() {
        XCTAssertEqual(VersionComparator.compare("0.1.0", "0.1.2"), .orderedAscending)
        XCTAssertEqual(VersionComparator.compare("0.1.9", "0.2.0"), .orderedAscending)
    }

    func testCompareOrdersVersionsDescending() {
        XCTAssertEqual(VersionComparator.compare("0.2.0", "0.1.9"), .orderedDescending)
        XCTAssertEqual(VersionComparator.compare("v0.1.3", "0.1.2"), .orderedDescending)
    }

    func testCompareOrdersVersionsSame() {
        XCTAssertEqual(VersionComparator.compare("0.1.2", "0.1.2"), .orderedSame)
        XCTAssertEqual(VersionComparator.compare("v0.1.2", "0.1.2"), .orderedSame)
    }

    func testIsNewerDetectsLaterRelease() {
        XCTAssertTrue(VersionComparator.isNewer("0.1.2", than: "0.1.0"))
        XCTAssertFalse(VersionComparator.isNewer("0.1.0", than: "0.1.2"))
        XCTAssertFalse(VersionComparator.isNewer("0.1.2", than: "0.1.2"))
    }

    func testIsNewerStrictRejectsMalformedCandidate() {
        XCTAssertFalse(VersionComparator.isNewerStrict("v999.0.bad", than: "0.1.2"))
        XCTAssertFalse(VersionComparator.isNewerStrict("1.2.3-alpha", than: "0.1.2"))
        XCTAssertFalse(VersionComparator.isNewerStrict("", than: "0.1.2"))
    }

    func testIsNewerStrictAcceptsValidNewerVersion() {
        XCTAssertTrue(VersionComparator.isNewerStrict("0.1.3", than: "0.1.2"))
        XCTAssertTrue(VersionComparator.isNewerStrict("v0.2.0", than: "0.1.9"))
    }

    func testIsNewerStrictRejectsMalformedCurrent() {
        XCTAssertFalse(VersionComparator.isNewerStrict("0.1.3", than: "bad.version"))
    }

    func testCompareStrictThrowsOnInvalidVersion() {
        XCTAssertThrowsError(try VersionComparator.compareStrict("1.2.bad", "1.2.3"))
        XCTAssertThrowsError(try VersionComparator.compareStrict("1.2.3", "1.2.bad"))
    }
}
