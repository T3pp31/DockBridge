import Foundation

@MainActor
final class TransferQueueViewModel: ObservableObject {
    @Published private(set) var tasks: [TransferTaskRecord] = []
    @Published var errorMessage: String?

    var activeTransferSummary: String? {
        TransferProgressFormatter.activeTransferSummary(for: tasks)
    }

    var hasFinishedTasks: Bool {
        tasks.contains { task in
            switch task.status {
            case .completed, .failed, .cancelled:
                return true
            case .pending, .inProgress:
                return false
            }
        }
    }

    private let bridge: RustBridgeService
    private var refreshTask: Task<Void, Never>?
    private var progressSamples: [UInt64: (bytes: UInt64, date: Date)] = [:]
    private var transferSpeeds: [UInt64: Double] = [:]
    /// Previous snapshot used to detect inProgress -> completed/failed transitions.
    private var previousTasks: [TransferTaskRecord] = []

    init(bridge: RustBridgeService) {
        self.bridge = bridge
    }

    func startPolling() {
        refreshTask?.cancel()
        refreshTask = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopPolling() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh() async {
        guard bridge.isConnected else {
            tasks = []
            errorMessage = nil
            progressSamples.removeAll()
            transferSpeeds.removeAll()
            return
        }

        do {
            let fetched = try await bridge.fetchTransferTasks()
            guard bridge.isConnected else {
                tasks = []
                errorMessage = nil
                progressSamples.removeAll()
                transferSpeeds.removeAll()
                return
            }
            updateProgressSamples(for: fetched)
            notifyFinishedTransitions(from: previousTasks, to: fetched)
            tasks = fetched
            updateDockBadge(tasks: fetched)
            previousTasks = fetched
            errorMessage = nil
        } catch {
            errorMessage = error.dockBridgeUserMessage
        }
    }

    func cancel(task: TransferTaskRecord) async {
        do {
            try await bridge.cancelTransfer(taskId: task.id)
            await refresh()
        } catch {
            errorMessage = error.dockBridgeUserMessage
        }
    }

    func clearCompleted() async {
        do {
            try await bridge.clearCompletedTransfers()
            await refresh()
        } catch {
            errorMessage = error.dockBridgeUserMessage
        }
    }

    func clearAll() async {
        do {
            try await bridge.clearAllTransfers()
            await refresh()
        } catch {
            errorMessage = error.dockBridgeUserMessage
        }
    }

    func retry(task: TransferTaskRecord) async {
        do {
            try await bridge.retryTransfer(taskId: task.id)
            await refresh()
        } catch {
            errorMessage = error.dockBridgeUserMessage
        }
    }

    func bytesPerSecond(for task: TransferTaskRecord) -> Double? {
        guard let speed = transferSpeeds[task.id], speed > 0 else { return nil }
        return speed
    }

    /// Posts a user notification when a transfer transitions from
    /// in-progress to completed/failed, but only while the app is in the
    /// background (otherwise the queue UI is the feedback).
    private func notifyFinishedTransitions(from old: [TransferTaskRecord], to new: [TransferTaskRecord]) {
        guard !NSApp.isActive else { return }
        let oldMap = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })

        for task in new {
            guard let previous = oldMap[task.id] else { continue }
            let wasActive = previous.status == .inProgress || previous.status == .pending
            let isFinished = task.status == .completed || task.status == .failed || task.status == .cancelled
            guard wasActive, isFinished else { continue }

            let direction = task.direction == .upload ? "Upload" : "Download"
            let title: String
            switch task.status {
            case .completed:
                title = "\(direction) finished"
            case .failed:
                title = "\(direction) failed"
            case .cancelled, .pending, .inProgress:
                continue
            }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = task.localPath
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "transfer-\(task.id)-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }

    /// Shows the number of active transfers on the Dock tile; clears it at zero.
    private func updateDockBadge(tasks: [TransferTaskRecord]) {
        let active = tasks.filter {
            $0.status == .inProgress || $0.status == .pending
        }.count
        NSApp.dockTile.badgeLabel = active > 0 ? "\(active)" : nil
    }

    private func updateProgressSamples(for fetched: [TransferTaskRecord]) {
        let now = Date()
        let activeIDs = Set(
            fetched
                .filter { $0.status == .inProgress }
                .map(\.id)
        )
        progressSamples = progressSamples.filter { activeIDs.contains($0.key) }
        transferSpeeds = transferSpeeds.filter { activeIDs.contains($0.key) }

        for task in fetched where task.status == .inProgress {
            guard let existing = progressSamples[task.id] else {
                progressSamples[task.id] = (task.bytesTransferred, now)
                continue
            }

            let elapsed = now.timeIntervalSince(existing.date)
            guard elapsed >= 1.0 else { continue }

            let delta = Double(task.bytesTransferred) - Double(existing.bytes)
            if delta >= 0 {
                transferSpeeds[task.id] = delta / elapsed
            }
            progressSamples[task.id] = (task.bytesTransferred, now)
        }
    }
}
