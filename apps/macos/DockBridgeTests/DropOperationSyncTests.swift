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

    func testSignalsSemaphoreEvenWhenOperationThrows() throws {
        // Regression test for issue #181: a throwing operation must not leave
        // the caller hanging. Run off the main thread and wait with an XCTest
        // expectation so a hang fails at the deadline instead of blocking CI
        // (issue #697).
        struct TestError: Error {}

        let completion = expectation(description: "DropOperationSync.run returned")
        DispatchQueue.global().async {
            do {
                try DropOperationSync.run { @MainActor in
                    await Task.yield()
                    throw TestError()
                }
                XCTFail("Expected run to throw")
            } catch {
                completion.fulfill()
            }
        }
        wait(for: [completion], timeout: 5)
    }
}
