import Foundation

enum TransferProgressFormatter {
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    /// Converts a byte count to `Int64` without trapping on values above
    /// `Int64.max` (issue #777).
    private static func safeByteCount(_ value: UInt64) -> Int64 {
        Int64(min(value, UInt64(Int64.max)))
    }

    /// Converts a speed to `Int64` without trapping on non-finite or
    /// out-of-range values (issue #777).
    private static func safeSpeed(_ value: Double) -> Int64 {
        guard value.isFinite, value > 0 else { return 0 }
        // Int64.max rounds up to 2^63 when represented as Double.
        guard value < Double(Int64.max) else { return Int64.max }
        return Int64(value)
    }

    static func progressLabel(
        transferred: UInt64,
        total: UInt64,
        bytesPerSecond: Double? = nil
    ) -> String? {
        guard total > 0 else { return nil }
        let transferredLabel = byteFormatter.string(fromByteCount: safeByteCount(transferred))
        let totalLabel = byteFormatter.string(fromByteCount: safeByteCount(total))
        var label = "\(transferredLabel) / \(totalLabel)"

        if let bytesPerSecond, bytesPerSecond.isFinite, bytesPerSecond > 0 {
            let speedLabel = byteFormatter.string(fromByteCount: safeSpeed(bytesPerSecond))
            label += String(
                format: String(localized: " · %@/s"),
                speedLabel
            )
            let remainingBytes = Double(total) - Double(transferred)
            if remainingBytes > 0 {
                let seconds = remainingBytes / bytesPerSecond
                label += String(
                    format: String(localized: " · ETA %@"),
                    formattedDuration(seconds)
                )
            }
        }

        return label
    }

    static func activeTransferSummary(
        for tasks: [TransferTaskRecord],
        totalBytesPerSecond: Double? = nil,
        prefix: String = String(localized: "Transferring")
    ) -> String? {
        let inProgressTasks = tasks.filter { $0.status == .inProgress }
        guard let primary = inProgressTasks.first,
              let label = progressLabel(
                transferred: primary.bytesTransferred,
                total: primary.totalBytes
              )
        else {
            return nil
        }

        let additionalCount = inProgressTasks.count - 1
        if additionalCount > 0 {
            if let totalBytesPerSecond, totalBytesPerSecond.isFinite, totalBytesPerSecond > 0 {
                let speed = byteFormatter.string(fromByteCount: safeSpeed(totalBytesPerSecond))
                let format = String(localized: "%@: %@ +%lld more · %@/s total")
                return String(format: format, prefix, label, Int64(additionalCount), speed)
            }
            let format = String(localized: "%@: %@ +%lld more")
            return String(format: format, prefix, label, Int64(additionalCount))
        }
        let format = String(localized: "%@: %@")
        return String(format: format, prefix, label)
    }

    private static func formattedDuration(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let duration = Duration.seconds(clamped.rounded())
        return duration.formatted(
            .units(allowed: [.minutes, .seconds], width: .narrow)
        )
    }
}
