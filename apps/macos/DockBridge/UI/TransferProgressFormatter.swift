import Foundation

enum TransferProgressFormatter {
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static func progressLabel(
        transferred: UInt64,
        total: UInt64,
        bytesPerSecond: Double? = nil
    ) -> String? {
        guard total > 0 else { return nil }
        let transferredLabel = byteFormatter.string(fromByteCount: Int64(transferred))
        let totalLabel = byteFormatter.string(fromByteCount: Int64(total))
        var label = "\(transferredLabel) / \(totalLabel)"

        if let bytesPerSecond, bytesPerSecond > 0 {
            let speedLabel = byteFormatter.string(fromByteCount: Int64(bytesPerSecond))
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
            if let totalBytesPerSecond, totalBytesPerSecond > 0 {
                let speed = byteFormatter.string(fromByteCount: Int64(totalBytesPerSecond))
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
