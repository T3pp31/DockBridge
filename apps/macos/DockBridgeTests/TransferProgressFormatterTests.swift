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

    func testProgressLabelHandlesSpeedsAtAndAboveInt64Limit() {
        for speed in [Double(Int64.max).nextDown, Double(Int64.max), Double.greatestFiniteMagnitude] {
            let label = TransferProgressFormatter.progressLabel(
                transferred: 1, total: 2, bytesPerSecond: speed
            )
            XCTAssertNotNil(label)
        }
    }

    func testProgressLabelFormatsRoundedETA() throws {
        let cases: [(total: UInt64, speed: Double, seconds: Int64)] = [
            (1, 4, 0),       // 0.25 seconds rounds to zero.
            (3, 2, 2),       // 1.5 seconds rounds up.
            (125, 2, 63),    // 62.5 seconds spans minutes and seconds.
        ]
        for testCase in cases {
            let label = TransferProgressFormatter.progressLabel(
                transferred: 0, total: testCase.total, bytesPerSecond: testCase.speed
            )
            XCTAssertEqual(label, try expectedProgressLabel(
                total: testCase.total, speed: testCase.speed, etaSeconds: testCase.seconds
            ))
        }
    }

    func testProgressLabelOmitsUnrepresentableETAWithoutLosingProgressOrSpeed() throws {
        let cases: [(total: UInt64, speed: Double)] = [
            (1, Double.leastNonzeroMagnitude),     // Division overflows to infinity.
            (1, Double.leastNormalMagnitude),      // Finite, but far above Int64.max.
            (1, 1 / Double(Int64.max)),            // ETA is exactly 2^63 seconds.
            (UInt64(1) << 63, 1),                 // Large byte count at the boundary.
            (UInt64.max, 1),                      // ETA exceeds the boundary.
        ]
        for testCase in cases {
            let label = TransferProgressFormatter.progressLabel(
                transferred: 0, total: testCase.total, bytesPerSecond: testCase.speed
            )
            XCTAssertEqual(label, try expectedProgressLabel(
                total: testCase.total, speed: testCase.speed
            ), "total=\(testCase.total), speed=\(testCase.speed)")
        }
    }

    func testProgressLabelKeepsETAImmediatelyBelowInt64Limit() throws {
        // The largest Double below 2^63 is 2^63 - 1024, not Double(Int64.max).
        let seconds = Int64.max - 1_023
        let total = UInt64(seconds)
        XCTAssertEqual(Double(total), Double(Int64.max).nextDown)

        let label = TransferProgressFormatter.progressLabel(
            transferred: 0, total: total, bytesPerSecond: 1
        )
        XCTAssertEqual(label, try expectedProgressLabel(
            total: total, speed: 1, etaSeconds: seconds
        ))
    }

    func testProgressLabelOmitsSpeedAndETAForInvalidSpeeds() {
        let expected = TransferProgressFormatter.progressLabel(transferred: 0, total: 100)
        for speed in [Double.nan, .infinity, -.infinity, 0, -1] {
            XCTAssertEqual(
                TransferProgressFormatter.progressLabel(
                    transferred: 0, total: 100, bytesPerSecond: speed
                ),
                expected
            )
        }
    }

    func testProgressLabelOmitsETAWhenNoBytesRemain() throws {
        for transferred in [UInt64(100), 101] {
            let label = TransferProgressFormatter.progressLabel(
                transferred: transferred, total: 100, bytesPerSecond: 1
            )
            XCTAssertEqual(label, try expectedProgressLabel(
                transferred: transferred, total: 100, speed: 1
            ))
        }
    }

    private func expectedProgressLabel(
        transferred: UInt64 = 0,
        total: UInt64,
        speed: Double,
        etaSeconds: Int64? = nil
    ) throws -> String {
        var label = try XCTUnwrap(TransferProgressFormatter.progressLabel(
            transferred: transferred, total: total
        ))
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        // These test speeds are finite, nonnegative, and small enough for Int64.
        label += String(
            format: String(localized: " · %@/s"),
            formatter.string(fromByteCount: Int64(speed))
        )
        if let etaSeconds {
            let duration = Duration.seconds(etaSeconds).formatted(
                .units(allowed: [.minutes, .seconds], width: .narrow)
            )
            label += String(format: String(localized: " · ETA %@"), duration)
        }
        return label
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
                sessionId: 1,
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

        // Then: summary includes a progress label with the slash separator
        XCTAssertNotNil(summary)
        XCTAssertTrue(summary?.contains("/") == true)
    }

    func testActiveTransferSummaryIncludesAdditionalInProgressCount() {
        // Given: multiple in-progress tasks
        let tasks = [
            TransferTaskRecord(
                id: 1,
                sessionId: 1,
                direction: .download,
                localPath: "/tmp/a.bin",
                remotePath: "/remote/a.bin",
                status: .inProgress,
                bytesTransferred: 100,
                totalBytes: 200
            ),
            TransferTaskRecord(
                id: 2,
                sessionId: 1,
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
        // +1 additional task must be reflected; wording is localized.
        if summary == nil {
            XCTFail("expected an active summary")
        } else {
            XCTAssertTrue(
                summary?.contains("+1 more") == true || summary?.contains("ほか 1 件") == true,
                "additional count should appear in the summary"
            )
        }
    }

    func testActiveTransferSummaryReturnsNilWithoutInProgressTasks() {
        // Given: only completed tasks
        let tasks = [
            TransferTaskRecord(
                id: 1,
                sessionId: 1,
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
