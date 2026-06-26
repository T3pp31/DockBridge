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
            label += " · \(speedLabel)/s"
            let remainingBytes = Double(total) - Double(transferred)
            if remainingBytes > 0 {
                let seconds = remainingBytes / bytesPerSecond
                label += " · ETA \(formattedDuration(seconds))"
            }
        }

        return label
    }

    static func activeTransferSummary(
        for tasks: [TransferTaskRecord],
        prefix: String = "Transferring"
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
            return "\(prefix): \(label) +\(additionalCount) more"
        }
        return "\(prefix): \(label)"
    }

    private static func formattedDuration(_ seconds: Double) -> String {
        if seconds < 60 {
            return String(format: "%.0fs", seconds)
        }
        let minutes = Int(seconds) / 60
        let remainder = Int(seconds) % 60
        return "\(minutes)m \(remainder)s"
    }
}
