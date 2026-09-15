import SwiftUI

struct TransferQueueView: View {
    @ObservedObject var viewModel: TransferQueueViewModel
    @Binding var isExpanded: Bool

    private var activeTransferCount: Int {
        viewModel.tasks.filter { task in
            switch task.status {
            case .pending, .inProgress: return true
            default: return false
            }
        }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WindowLayout.paneSpacing) {
            HStack(spacing: 8) {
                Text(String(localized: "Transfer Queue"))
                    .font(.headline)

                if activeTransferCount > 0 {
                    Text("\(activeTransferCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(DesignTokens.Status.connecting.opacity(0.2)))
                        .accessibilityLabel(String(format: String(localized: "%lld active transfers"), activeTransferCount))
                }

                Spacer()

                if viewModel.hasFinishedTasks {
                    Menu {
                        Button(String(localized: "Clear Completed")) {
                            Task { await viewModel.clearCompleted() }
                        }
                        Button(String(localized: "Clear All"), role: .destructive) {
                            Task { await viewModel.clearAll() }
                        }
                    } label: {
                        Label(String(localized: "Clear"), systemImage: "trash")
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
                .help(String(localized: "Refresh"))

                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                }
                .buttonStyle(.borderless)
                .fixedSize()
                .help(isExpanded ? String(localized: "Collapse transfer queue") : String(localized: "Expand transfer queue"))
            }

            if isExpanded {
                expandedContent
            }
        }
        .frame(maxWidth: .infinity)
        .padding(WindowLayout.panePadding)
        .errorAlert(message: $viewModel.errorMessage)
    }

    @ViewBuilder
    private var expandedContent: some View {
        if viewModel.tasks.isEmpty {
            ContentUnavailableView(
                String(localized: "No transfers"),
                systemImage: "arrow.up.arrow.down.circle",
                description: Text(String(localized: "Upload or download files to see progress here."))
            )
            .frame(maxWidth: .infinity, minHeight: WindowLayout.transferQueueMinHeight)
        } else {
            ExpandingFrame { size in
                transferTable
                    .frame(width: size.width, height: size.height)
            }
        }
    }

    private var transferTable: some View {
        Table(viewModel.tasks) {
            TableColumn(String(localized: "Direction")) { task in
                Image(systemName: task.direction == .upload ? "arrow.up" : "arrow.down")
                    .help(task.direction == .upload ? String(localized: "Upload") : String(localized: "Download"))
                    .accessibilityLabel(task.direction == .upload ? String(localized: "Upload") : String(localized: "Download"))
            }
            TableColumn(String(localized: "Local")) { task in
                Text((task.localPath as NSString).lastPathComponent)
                    .help(task.localPath)
            }
            TableColumn(String(localized: "Remote")) { task in
                Text((task.remotePath as NSString).lastPathComponent)
                    .help(task.remotePath)
            }
            TableColumn(String(localized: "Status")) { task in
                statusView(for: task)
            }
            TableColumn("") { task in
                HStack(spacing: 6) {
                    if canRetry(task: task) {
                        Button {
                            Task { await viewModel.retry(task: task) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help(String(localized: "Retry"))
                        .accessibilityLabel(String(localized: "Retry"))
                    }
                    if canCancel(task: task) {
                        Button {
                            Task { await viewModel.cancel(task: task) }
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .help(String(localized: "Cancel"))
                        .accessibilityLabel(String(localized: "Cancel"))
                    }
                }
            }
            .width(72)
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
            HStack(spacing: 8) {
                ProgressView(
                    value: Double(task.bytesTransferred),
                    total: Double(task.totalBytes)
                )
                .controlSize(.small)
                .frame(minWidth: 80)
                Text(progressLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(String(format: String(localized: "In progress, %@"), progressLabel))
        } else if case .failed(let message) = task.status {
            let summary = DockBridgeError.friendlyMessage(for: message)
            VStack(alignment: .leading, spacing: 2) {
                Label(String(localized: "Failed"), systemImage: "xmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DesignTokens.Status.error)
                    .accessibilityHidden(true)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(String(format: String(localized: "Failed: %@. %@"), summary, message))
            .help(message)
        } else {
            statusLabelView(for: task.status)
        }
    }

    @ViewBuilder
    private func statusLabelView(for status: TransferStatusRecord) -> some View {
        switch status {
        case .pending:
            Label(String(localized: "Pending"), systemImage: "clock")
                .accessibilityLabel(String(localized: "Pending"))
        case .inProgress:
            Label(String(localized: "In Progress"), systemImage: "arrow.up.arrow.down.circle")
                .accessibilityLabel(String(localized: "In progress"))
        case .completed:
            Label(String(localized: "Completed"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(DesignTokens.Status.success)
                .accessibilityLabel(String(localized: "Completed"))
        case .failed:
            EmptyView()
        case .cancelled:
            Label(String(localized: "Cancelled"), systemImage: "minus.circle")
                .foregroundStyle(DesignTokens.Status.disconnected)
                .accessibilityLabel(String(localized: "Cancelled"))
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
}
