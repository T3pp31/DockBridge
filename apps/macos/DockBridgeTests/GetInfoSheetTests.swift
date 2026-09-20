import XCTest
@testable import DockBridge

final class GetInfoSheetTests: XCTestCase {
    func testPermissionFormatterFormatsCommonModes() {
        XCTAssertEqual(PermissionFormatter.string(from: 0o000), "---------")
        XCTAssertEqual(PermissionFormatter.string(from: 0o644), "rw-r--r--")
        XCTAssertEqual(PermissionFormatter.string(from: 0o755), "rwxr-xr-x")
        XCTAssertEqual(PermissionFormatter.string(from: 0o777), "rwxrwxrwx")
    }

    func testPermissionFormatterIgnoresFileTypeBits() {
        XCTAssertEqual(PermissionFormatter.string(from: 0o100755), "rwxr-xr-x")
    }
}
