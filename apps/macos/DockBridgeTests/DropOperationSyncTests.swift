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

    @MainActor
    func testTimesOutWhenOperationDoesNotComplete() {
        var operationFinished = false
        XCTAssertThrowsError(
            try DropOperationSync.run(timeout: 0.01) {
                defer { operationFinished = true }
                try await Task.sleep(for: .seconds(1))
                return 1
            }
        ) { error in
            XCTAssertEqual(error as? DropOperationSyncError, .timedOut)
        }
        XCTAssertTrue(operationFinished, "Cancellation cleanup must finish before run throws")
    }

    func testTimeoutWaitsForLateSuccess() {
        assertTimeoutWaitsForOperation(throwsAfterCancellation: false)
    }

    func testTimeoutWaitsForLateError() {
        assertTimeoutWaitsForOperation(throwsAfterCancellation: true)
    }

    private func assertTimeoutWaitsForOperation(throwsAfterCancellation: Bool) {
        struct TestError: Error {}
        let operationFinished = expectation(description: "Operation finished after cancellation")
        let bridgeReturned = expectation(description: "Bridge reported timeout")

        // Keep the wait bounded even if the bridge regresses and hangs (#697).
        DispatchQueue.global().async {
            XCTAssertThrowsError(try DropOperationSync.run(timeout: 0.1) {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    XCTAssertTrue(error is CancellationError)
                }

                // Model callback-backed work that cannot be interrupted by
                // cancellation and finishes after the cancellation request.
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                        continuation.resume()
                    }
                }
                XCTAssertTrue(Task.isCancelled)
                operationFinished.fulfill()
                if throwsAfterCancellation { throw TestError() }
                return 42
            }) { error in
                XCTAssertEqual(error as? DropOperationSyncError, .timedOut)
            }
            bridgeReturned.fulfill()
        }
        wait(for: [operationFinished, bridgeReturned], timeout: 5, enforceOrder: true)
    }
}
