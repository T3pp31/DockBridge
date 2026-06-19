import XCTest
@testable import DockBridge

final class TransferProgressFormatterTests: XCTestCase {
    func testProgressLabelFormatsTransferredAndTotalBytes() {
        // Given: known byte counts
        let transferred: UInt64 = 1_500_000
        let total: UInt64 = 10_000_000

        // When: progress label is generated
        let label = TransferProgressFormatter.progressLabel(
            transferred: transferred,
            total: total
        )

        // Then: both values appear in a slash-separated label
        XCTAssertNotNil(label)
        XCTAssertTrue(label?.contains("/") == true)
    }

    func testProgressLabelReturnsNilWhenTotalIsZero() {
        // Given: zero total bytes
        // When: progress label is generated
        let label = TransferProgressFormatter.progressLabel(transferred: 100, total: 0)

        // Then: no progress label is produced
        XCTAssertNil(label)
    }

    func testActiveTransferSummaryUsesFirstInProgressTask() {
        // Given: one in-progress task with known progress
        let tasks = [
            TransferTaskRecord(
                id: 1,
                direction: .download,
                localPath: "/tmp/file.bin",
                remotePath: "/remote/file.bin",
                status: .inProgress,
                bytesTransferred: 512,
                totalBytes: 1_024
            ),
        ]

        // When: summary is generated
        let summary = TransferProgressFormatter.activeTransferSummary(for: tasks)

        // Then: summary includes the progress prefix and slash label
        XCTAssertNotNil(summary)
        XCTAssertTrue(summary?.hasPrefix("転送中:") == true)
        XCTAssertTrue(summary?.contains("/") == true)
    }

    func testActiveTransferSummaryIncludesAdditionalInProgressCount() {
        // Given: multiple in-progress tasks
        let tasks = [
            TransferTaskRecord(
                id: 1,
                direction: .download,
                localPath: "/tmp/a.bin",
                remotePath: "/remote/a.bin",
                status: .inProgress,
                bytesTransferred: 100,
                totalBytes: 200
            ),
            TransferTaskRecord(
                id: 2,
                direction: .download,
                localPath: "/tmp/b.bin",
                remotePath: "/remote/b.bin",
                status: .inProgress,
                bytesTransferred: 50,
                totalBytes: 100
            ),
        ]

        // When: summary is generated
        let summary = TransferProgressFormatter.activeTransferSummary(for: tasks)

        // Then: additional in-progress count is appended
        XCTAssertEqual(summary?.contains("他1件"), true)
    }

    func testActiveTransferSummaryReturnsNilWithoutInProgressTasks() {
        // Given: only completed tasks
        let tasks = [
            TransferTaskRecord(
                id: 1,
                direction: .upload,
                localPath: "/tmp/file.txt",
                remotePath: "/remote/file.txt",
                status: .completed,
                bytesTransferred: 100,
                totalBytes: 100
            ),
        ]

        // When: summary is generated
        let summary = TransferProgressFormatter.activeTransferSummary(for: tasks)

        // Then: no summary is shown
        XCTAssertNil(summary)
    }
}
