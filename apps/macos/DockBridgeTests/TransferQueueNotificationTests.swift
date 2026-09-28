import XCTest
@testable import DockBridge

@MainActor
final class TransferQueueNotificationTests: XCTestCase {
    func testInitialSnapshotDoesNotProduceNotifications() {
        let queue = TransferQueueViewModel(bridge: FakeBridge())
        let completed = makeTask(id: 1, status: .completed)

        let finished = queue.finishedTransitions(from: nil, to: [completed])

        XCTAssertTrue(finished.isEmpty)
    }

    func testCompletedAndFailedActiveTasksProduceNotifications() {
        let queue = TransferQueueViewModel(bridge: FakeBridge())
        let previous = [
            makeTask(id: 1, status: .inProgress),
            makeTask(id: 2, status: .pending),
            makeTask(id: 3, status: .inProgress),
        ]
        let current = [
            makeTask(id: 1, status: .completed),
            makeTask(id: 2, status: .failed(message: "simulated failure")),
            makeTask(id: 3, status: .cancelled),
        ]

        let finished = queue.finishedTransitions(from: previous, to: current)

        XCTAssertEqual(finished.map { $0.id }, [UInt64(1), UInt64(2)])
    }

    func testFastCompletedTaskAppearingBetweenPollsProducesNotification() {
        let queue = TransferQueueViewModel(bridge: FakeBridge())
        let previous = [
            makeTask(id: 1, status: .completed),
            makeTask(id: 2, status: .inProgress),
        ]
        let current = [
            makeTask(id: 1, status: .completed),
            makeTask(id: 2, status: .inProgress),
            makeTask(id: 3, status: .completed),
        ]

        let finished = queue.finishedTransitions(from: previous, to: current)

        // Task 3 was created and finished between polls; it is new and
        // terminal, so it must notify exactly once.
        XCTAssertEqual(finished.map { $0.id }, [UInt64(3)])
    }

    func testTerminalTaskReappearingIsNotNotifiedTwice() {
        let queue = TransferQueueViewModel(bridge: FakeBridge())
        // A task progresses from in-progress to completed; it notifies once.
        let previous = [makeTask(id: 3, status: .inProgress)]
        let completed = [makeTask(id: 3, status: .completed)]
        let firstFinished = queue.finishedTransitions(from: previous, to: completed)
        XCTAssertEqual(firstFinished.map { $0.id }, [UInt64(3)])

        // Mark it notified like refresh() does, then simulate the task
        // disappearing and reappearing between polls.
        queue.markFinishedTasksNotified(firstFinished)
        let reappearedFromActive = [makeTask(id: 3, status: .completed)]
        let again = queue.finishedTransitions(from: previous, to: reappearedFromActive)
        XCTAssertTrue(again.isEmpty, "already-notified terminal task must not notify again")

        // A task that appeared and finished between polls also notifies once,
        // then stays silent on reappearance.
        let fastFinished = queue.finishedTransitions(from: [], to: [makeTask(id: 4, status: .completed)])
        XCTAssertEqual(fastFinished.map { $0.id }, [UInt64(4)])
        queue.markFinishedTasksNotified(fastFinished)
        let reappearedFast = queue.finishedTransitions(from: [], to: [makeTask(id: 4, status: .completed)])
        XCTAssertTrue(reappearedFast.isEmpty)
    }

    func testSessionChangeResetsNotifiedTaskIDs() {
        let queue = TransferQueueViewModel(bridge: FakeBridge())
        let previous = [makeTask(id: 1, status: .inProgress)]
        let completed = [makeTask(id: 1, status: .completed)]
        let firstFinished = queue.finishedTransitions(from: previous, to: completed)
        XCTAssertEqual(firstFinished.map { $0.id }, [UInt64(1)])
        queue.markFinishedTasksNotified(firstFinished)

        // Switching sessions must forget notified IDs so a reused ID in the
        // new session can notify again.
        queue.sessionId = 2
        let newPrevious = [makeTask(id: 1, status: .inProgress)]
        let newCompleted = [makeTask(id: 1, status: .completed)]
        let again = queue.finishedTransitions(from: newPrevious, to: newCompleted)
        XCTAssertEqual(again.map { $0.id }, [UInt64(1)], "new session must not inherit old notified IDs")
    }

    func testCancelledTaskDoesNotNotifyLater() {
        let queue = TransferQueueViewModel(bridge: FakeBridge())
        let previous = [makeTask(id: 1, status: .inProgress)]
        let cancelled = [makeTask(id: 1, status: .cancelled)]
        let finished = queue.finishedTransitions(from: previous, to: cancelled)
        XCTAssertTrue(finished.isEmpty, "cancelled transitions are not notifications")
    }

    private func makeTask(id: UInt64, status: TransferStatusRecord) -> TransferTaskRecord {
        TransferTaskRecord(
            id: id,
            sessionId: 1,
            direction: .upload,
            localPath: "/local/file-\(id).txt",
            remotePath: "/remote/file-\(id).txt",
            status: status,
            bytesTransferred: status == .completed ? 100 : 50,
            totalBytes: 100
        )
    }
}
