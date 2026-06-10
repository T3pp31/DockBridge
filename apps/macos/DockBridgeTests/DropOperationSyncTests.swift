import XCTest
@testable import DockBridge

final class DropOperationSyncTests: XCTestCase {
    @MainActor
    func testReturnsAsyncResultOnMainActor() {
        let result = DropOperationSync.run { @MainActor in
            await Task.yield()
            return true
        }

        XCTAssertTrue(result)
    }

    @MainActor
    func testReturnsFalseFromAsyncOperation() {
        let result = DropOperationSync.run { @MainActor in
            false
        }

        XCTAssertFalse(result)
    }
}
