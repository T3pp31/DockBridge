import AppKit
import Combine
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

    func testUnchangedSnapshotsDoNotPublishButTaskChangesDo() async {
        let bridge = FakeBridge()
        bridge.connectionStatus = .connected(endpoint: "test:22")
        let queue = TransferQueueViewModel(bridge: bridge)
        var snapshots: [[TransferTaskRecord]] = []
        var changes = 0
        let taskSubscription = queue.$tasks.sink { snapshots.append($0) }
        let changeSubscription = queue.objectWillChange.sink { changes += 1 }
        defer {
            taskSubscription.cancel()
            changeSubscription.cancel()
        }

        await queue.refresh()
        XCTAssertEqual(snapshots.count, 1, "Only the initial @Published value should emit")
        XCTAssertEqual(changes, 0)

        let history = (1...1_000).map {
            makeTask(id: UInt64($0), sessionId: 10, name: "file-\($0)")
        }
        let pending = makeTask(id: 1_001, sessionId: 10, name: "active", status: .pending)
        var progressing = pending
        progressing.status = .inProgress
        progressing.bytesTransferred = 50
        var advanced = progressing
        advanced.bytesTransferred = 75
        var cancelled = advanced
        cancelled.status = .cancelled

        let updates = [
            history,
            history + [pending],
            history + [progressing],
            history + [advanced],
            history + [cancelled],
            [],
        ]
        for fetched in updates {
            bridge.transferTasks = fetched
            let previousEmissions = snapshots.count
            let previousChanges = changes
            await queue.refresh()
            XCTAssertEqual(snapshots.count, previousEmissions + 1)
            XCTAssertEqual(snapshots.last, fetched)
            XCTAssertEqual(changes, previousChanges + 1)

            await queue.refresh()
            XCTAssertEqual(snapshots.count, previousEmissions + 1, "An identical snapshot must not emit")
            XCTAssertEqual(changes, previousChanges + 1, "An identical snapshot must not invalidate the UI")
        }
    }

    func testOtherSessionChangesDoNotPublish() async {
        let bridge = FakeBridge()
        bridge.connectionStatus = .connected(endpoint: "test:22")
        let ownTask = makeTask(id: 1, sessionId: 10, name: "own")
        bridge.transferTasks = [ownTask]
        let queue = TransferQueueViewModel(bridge: bridge)
        queue.sessionId = 10
        await queue.refresh()
        var changes = 0
        let subscription = queue.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }

        bridge.transferTasks.append(makeTask(id: 2, sessionId: 20, name: "other", status: .pending))
        await queue.refresh()
        XCTAssertEqual(queue.tasks, [ownTask])
        XCTAssertEqual(changes, 0)
    }

    func testRepeatedFetchErrorDoesNotPublishAndRecoveryClearsItOnce() async {
        let bridge = FakeBridge()
        bridge.connectionStatus = .connected(endpoint: "test:22")
        bridge.transferTasks = [makeTask(id: 1, sessionId: 10, name: "finished")]
        let queue = TransferQueueViewModel(bridge: bridge)
        await queue.refresh()
        var changes = 0
        var taskEmissions = 0
        var messages: [String?] = []
        let changeSubscription = queue.objectWillChange.sink { changes += 1 }
        let taskSubscription = queue.$tasks.dropFirst().sink { _ in taskEmissions += 1 }
        let errorSubscription = queue.$errorMessage.dropFirst().sink { messages.append($0) }
        defer {
            changeSubscription.cancel()
            taskSubscription.cancel()
            errorSubscription.cancel()
        }

        let firstError = DockBridgeError.Other(message: "simulated queue failure")
        bridge.fetchTransferTasksError = firstError
        await queue.refresh()
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(queue.errorMessage, firstError.dockBridgeUserMessage)
        await queue.refresh()
        XCTAssertEqual(changes, 1, "Repeating the same error must not invalidate the UI")

        let nextError = DockBridgeError.Other(message: "another queue failure")
        bridge.fetchTransferTasksError = nextError
        await queue.refresh()
        XCTAssertEqual(changes, 2, "A changed error must still be displayed")
        XCTAssertEqual(queue.tasks, bridge.transferTasks, "Fetch failures must retain the last snapshot")

        bridge.fetchTransferTasksError = nil
        await queue.refresh()
        XCTAssertEqual(changes, 3, "Recovery must clear the error even when tasks are unchanged")
        XCTAssertNil(queue.errorMessage)
        await queue.refresh()
        XCTAssertEqual(changes, 3)
        XCTAssertEqual(taskEmissions, 0)
        XCTAssertEqual(messages, [firstError.dockBridgeUserMessage, nextError.dockBridgeUserMessage, nil])
    }

    func testPollingBacksOffWhenIdleAndUsesOneSecondForPendingAndInProgress() async {
        let bridge = FakeBridge()
        bridge.connectionStatus = .connected(endpoint: "test:22")
        let queue = TransferQueueViewModel(bridge: bridge)
        let fetched: [[TransferTaskRecord]] = [
            [],
            [makeTask(id: 1, sessionId: 10, name: "active", status: .pending)],
            [makeTask(id: 1, sessionId: 10, name: "active", status: .inProgress)],
            [makeTask(id: 1, sessionId: 10, name: "active", status: .cancelled)],
            [makeTask(id: 1, sessionId: 10, name: "active", status: .cancelled)],
        ]
        let polls = fetched.indices.map { expectation(description: "Poll \($0)") }
        var times: [ContinuousClock.Instant] = []
        bridge.onFetchTransferTasks = { [weak bridge] in
            guard let bridge else { return }
            let index = bridge.fetchTransferTasksCallCount - 1
            guard index < fetched.count else {
                XCTFail("Unexpected extra poll")
                return
            }
            bridge.transferTasks = fetched[index]
            times.append(ContinuousClock.now)
            polls[index].fulfill()
        }
        defer {
            queue.stopPolling()
            bridge.onFetchTransferTasks = nil
        }

        queue.startPolling()
        await fulfillment(of: [polls[0]], timeout: 2)
        await fulfillment(of: [polls[1]], timeout: 8)
        await fulfillment(of: [polls[2]], timeout: 4)
        await fulfillment(of: [polls[3]], timeout: 4)
        await fulfillment(of: [polls[4]], timeout: 8)
        guard times.count == 5 else {
            return XCTFail("Expected five polls, got \(times.count)")
        }
        XCTAssertGreaterThanOrEqual(times[0].duration(to: times[1]), .seconds(5))
        XCTAssertGreaterThanOrEqual(times[1].duration(to: times[2]), .seconds(1))
        XCTAssertGreaterThanOrEqual(times[2].duration(to: times[3]), .seconds(1))
        XCTAssertGreaterThanOrEqual(times[3].duration(to: times[4]), .seconds(5))
    }

    func testDisconnectedRefreshDoesNotFetchTransferTasks() async {
        let bridge = FakeBridge()
        let queue = TransferQueueViewModel(bridge: bridge)
        await queue.refresh()
        await queue.refresh()
        XCTAssertEqual(bridge.fetchTransferTasksCallCount, 0)
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
