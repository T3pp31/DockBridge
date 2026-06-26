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
            progressSamples.removeAll()
            return
        }

        do {
            let fetched = try await bridge.fetchTransferTasks()
            guard bridge.isConnected else {
                tasks = []
                progressSamples.removeAll()
                return
            }
            updateProgressSamples(for: fetched)
            tasks = fetched
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
        guard let sample = progressSamples[task.id] else { return nil }
        let elapsed = Date().timeIntervalSince(sample.date)
        guard elapsed > 0 else { return nil }
        let delta = Double(task.bytesTransferred) - Double(sample.bytes)
        guard delta >= 0 else { return nil }
        return delta / elapsed
    }

    private func updateProgressSamples(for fetched: [TransferTaskRecord]) {
        let now = Date()
        let activeIDs = Set(
            fetched
                .filter { $0.status == .inProgress }
                .map(\.id)
        )
        progressSamples = progressSamples.filter { activeIDs.contains($0.key) }

        for task in fetched where task.status == .inProgress {
            if let existing = progressSamples[task.id] {
                if now.timeIntervalSince(existing.date) >= 1.0 {
                    progressSamples[task.id] = (task.bytesTransferred, now)
                }
            } else {
                progressSamples[task.id] = (task.bytesTransferred, now)
            }
        }
    }
}
