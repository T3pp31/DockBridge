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
