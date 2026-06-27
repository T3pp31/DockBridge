import SwiftUI

struct TransferQueueView: View {
    @ObservedObject var viewModel: TransferQueueViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: WindowLayout.paneSpacing) {
            HStack(spacing: 8) {
                Text("Transfer Queue")
                    .font(.headline)
                Spacer()
                if viewModel.hasFinishedTasks {
                    Menu {
                        Button("Clear Completed") {
                            Task { await viewModel.clearCompleted() }
                        }
                        Button("Clear All", role: .destructive) {
                            Task { await viewModel.clearAll() }
                        }
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .fixedSize()
                }
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .fixedSize()
                .help("Refresh")
            }

            if viewModel.tasks.isEmpty {
                ContentUnavailableView(
                    "No transfers",
                    systemImage: "arrow.up.arrow.down.circle",
                    description: Text("Upload or download files to see progress here.")
                )
                .frame(maxWidth: .infinity, minHeight: WindowLayout.transferQueueMinHeight)
            } else {
                ExpandingFrame { size in
                    transferTable
                        .frame(width: size.width, height: size.height)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(WindowLayout.panePadding)
        .errorAlert(message: $viewModel.errorMessage)
    }

    private var transferTable: some View {
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
                statusView(for: task)
            }
            TableColumn("") { task in
                HStack(spacing: 8) {
                    if canRetry(task: task) {
                        Button("Retry") {
                            Task { await viewModel.retry(task: task) }
                        }
                    }
                    if canCancel(task: task) {
                        Button("Cancel") {
                            Task { await viewModel.cancel(task: task) }
                        }
                    }
                }
            }
            .width(120)
        }
    }

    @ViewBuilder
    private func statusView(for task: TransferTaskRecord) -> some View {
        if case .inProgress = task.status,
           let progressLabel = TransferProgressFormatter.progressLabel(
               transferred: task.bytesTransferred,
               total: task.totalBytes,
               bytesPerSecond: viewModel.bytesPerSecond(for: task)
           ) {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(
                    value: Double(task.bytesTransferred),
                    total: Double(task.totalBytes)
                )
                .monospacedDigit()
                Text(progressLabel)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        } else if case .failed(let message) = task.status {
            Text("Failed")
                .foregroundStyle(.red)
                .help(message)
        } else {
            Text(statusLabel(for: task.status))
        }
    }

    private func canCancel(task: TransferTaskRecord) -> Bool {
        switch task.status {
        case .pending, .inProgress:
            return true
        case .completed, .failed, .cancelled:
            return false
        }
    }

    private func canRetry(task: TransferTaskRecord) -> Bool {
        switch task.status {
        case .failed, .cancelled:
            return true
        case .pending, .inProgress, .completed:
            return false
        }
    }

    private func statusLabel(for status: TransferStatusRecord) -> String {
        switch status {
        case .pending: "Pending"
        case .inProgress: "In Progress"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}
