import XCTest
@testable import DockBridge

final class DropOperationSyncTests: XCTestCase {
    @MainActor
    func testReturnsAsyncResultOnMainActor() throws {
        let result = try DropOperationSync.run { @MainActor in
            await Task.yield()
            return true
        }

        XCTAssertTrue(result)
    }

    @MainActor
    func testReturnsFalseFromAsyncOperation() throws {
        let result = try DropOperationSync.run { @MainActor in
            false
        }

        XCTAssertFalse(result)
    }

    @MainActor
    func testPropagatesThrownError() {
        struct TestError: Error, Equatable {}

        XCTAssertThrowsError(try DropOperationSync.run { @MainActor in
            throw TestError()
        }) { error in
            XCTAssertEqual(error as? TestError, TestError())
        }
    }

    @MainActor
    func testSignalsSemaphoreEvenWhenOperationThrows() throws {
        // Regression test for issue #181: a throwing operation must not leave
        // the caller hanging. We verify the call returns promptly (instead of
        // deadlocking) by asserting it completes within a generous deadline.
        struct TestError: Error {}

        let start = ContinuousClock.now
        XCTAssertThrowsError(try DropOperationSync.run { @MainActor in
            await Task.yield()
            throw TestError()
        })
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(5))
    }
}
