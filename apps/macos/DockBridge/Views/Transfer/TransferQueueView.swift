import SwiftUI

struct TransferQueueView: View {
    @ObservedObject var viewModel: TransferQueueViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Transfer Queue")
                    .font(.headline)
                Spacer()
                Button("Refresh") {
                    Task { await viewModel.refresh() }
                }
            }

            if viewModel.tasks.isEmpty {
                ContentUnavailableView(
                    "No transfers",
                    systemImage: "arrow.up.arrow.down.circle",
                    description: Text("Upload or download files to see progress here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(viewModel.tasks) {
                    TableColumn("Direction") { task in
                        Text(task.direction == .upload ? "Upload" : "Download")
                    }
                    TableColumn("Local") { task in
                        Text((task.localPath as NSString).lastPathComponent)
                            .help(task.localPath)
                    }
                    TableColumn("Remote") { task in
                        Text((task.remotePath as NSString).lastPathComponent)
                            .help(task.remotePath)
                    }
                    TableColumn("Status") { task in
                        Text(statusLabel(for: task.status))
                    }
                    TableColumn("") { task in
                        if canCancel(task: task) {
                            Button("Cancel") {
                                Task { await viewModel.cancel(task: task) }
                            }
                        }
                    }
                    .width(80)
                }
            }
        }
        .padding(12)
        .errorAlert(message: $viewModel.errorMessage)
    }

    private func canCancel(task: TransferTaskRecord) -> Bool {
        switch task.status {
        case .pending, .inProgress:
            return true
        case .completed, .failed, .cancelled:
            return false
        }
    }

    private func statusLabel(for status: TransferStatusRecord) -> String {
        switch status {
        case .pending: "Pending"
        case .inProgress: "In Progress"
        case .completed: "Completed"
        case .failed(let message): "Failed: \(message)"
        case .cancelled: "Cancelled"
        }
    }
}
