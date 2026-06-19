import Foundation

enum TransferProgressFormatter {
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static func progressLabel(transferred: UInt64, total: UInt64) -> String? {
        guard total > 0 else { return nil }
        let transferredLabel = byteFormatter.string(fromByteCount: Int64(transferred))
        let totalLabel = byteFormatter.string(fromByteCount: Int64(total))
        return "\(transferredLabel) / \(totalLabel)"
    }

    static func activeTransferSummary(
        for tasks: [TransferTaskRecord],
        prefix: String = "転送中"
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
            return "\(prefix): \(label) 他\(additionalCount)件"
        }
        return "\(prefix): \(label)"
    }
}
