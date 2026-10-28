import AppKit
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

    func testDockBadgeCountsDistinctTasksAcrossQueues() async {
        let bridge = FakeBridge()
        bridge.connectionStatus = .connected(endpoint: "test:22")
        bridge.transferTasks = [
            makeTask(id: 101, sessionId: 10, name: "a", status: .inProgress),
            makeTask(id: 102, sessionId: 20, name: "b", status: .pending),
        ]
        let first = TransferQueueViewModel(bridge: bridge)
        first.sessionId = 10
        let second = TransferQueueViewModel(bridge: bridge)
        second.sessionId = 20
        let all = TransferQueueViewModel(bridge: bridge)

        await first.refresh()
        XCTAssertEqual(NSApp.dockTile.badgeLabel, "1")
        await second.refresh()
        XCTAssertEqual(NSApp.dockTile.badgeLabel, "2")
        await all.refresh()
        XCTAssertEqual(NSApp.dockTile.badgeLabel, "2", "The same task must not be counted twice")

        bridge.transferTasks = []
        await first.refresh()
        await second.refresh()
        await all.refresh()
        XCTAssertNil(NSApp.dockTile.badgeLabel)
    }

    func testDockBadgeRemovesReleasedQueueContribution() async throws {
        let bridge = FakeBridge()
        bridge.connectionStatus = .connected(endpoint: "test:22")
        bridge.transferTasks = [makeTask(id: 103, sessionId: 10, name: "a", status: .pending)]
        var queue: TransferQueueViewModel? = TransferQueueViewModel(bridge: bridge)
        await queue?.refresh()
        XCTAssertEqual(NSApp.dockTile.badgeLabel, "1")
        weak var releasedQueue = queue
        queue = nil
        XCTAssertNil(releasedQueue)

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while NSApp.dockTile.badgeLabel != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(NSApp.dockTile.badgeLabel)
    }

    private func makeTask(
        id: UInt64,
        sessionId: UInt64,
        name: String,
        status: TransferStatusRecord = .completed
    ) -> TransferTaskRecord {
        TransferTaskRecord(
            id: id,
            sessionId: sessionId,
            direction: .upload,
            localPath: "/local/\(name)",
            remotePath: "/remote/\(name)",
            status: status,
            bytesTransferred: 100,
            totalBytes: 100
        )
    }
}
