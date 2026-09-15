import XCTest
@testable import DockBridge

@MainActor
final class TransferQueueSessionFilterTests: XCTestCase {
    func testFilteredTasksReturnsAllSessionsWhenSessionIdNil() throws {
        let bridge = RustBridgeService()
        let queue = TransferQueueViewModel(bridge: bridge)
        let tasks = [
            makeTask(id: 1, sessionId: 10, name: "a.txt"),
            makeTask(id: 2, sessionId: 20, name: "b.txt"),
        ]
        XCTAssertEqual(queue.filteredTasks(from: tasks).map(\.id), [1, 2])
    }

    func testFilteredTasksRestrictsToOwnSession() throws {
        let bridge = RustBridgeService()
        let queue = TransferQueueViewModel(bridge: bridge)
        queue.sessionId = 20
        let tasks = [
            makeTask(id: 1, sessionId: 10, name: "a.txt"),
            makeTask(id: 2, sessionId: 20, name: "b.txt"),
            makeTask(id: 3, sessionId: 20, name: "c.txt"),
        ]
        XCTAssertEqual(queue.filteredTasks(from: tasks).map(\.id), [2, 3])
    }

    func testFilteredTasksReturnsEmptyForUnmatchedSession() throws {
        let bridge = RustBridgeService()
        let queue = TransferQueueViewModel(bridge: bridge)
        queue.sessionId = 99
        let tasks = [
            makeTask(id: 1, sessionId: 10, name: "a.txt"),
        ]
        XCTAssertTrue(queue.filteredTasks(from: tasks).isEmpty)
    }

    private func makeTask(id: UInt64, sessionId: UInt64, name: String) -> TransferTaskRecord {
        TransferTaskRecord(
            id: id,
            sessionId: sessionId,
            direction: .upload,
            localPath: "/local/\(name)",
            remotePath: "/remote/\(name)",
            status: .completed,
            bytesTransferred: 100,
            totalBytes: 100
        )
    }
}
