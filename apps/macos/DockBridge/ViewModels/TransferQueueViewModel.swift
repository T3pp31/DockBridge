import Foundation

@MainActor
final class TransferQueueViewModel: ObservableObject {
    @Published private(set) var tasks: [TransferTaskRecord] = []
    @Published var errorMessage: String?

    var activeTransferSummary: String? {
        let totalSpeed = transferSpeeds.values.reduce(0, +)
        return TransferProgressFormatter.activeTransferSummary(
            for: tasks,
            totalBytesPerSecond: totalSpeed > 0 ? totalSpeed : nil
        )
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

    private let bridge: any RemoteBridging
    /// Rust-side session ID whose transfer tasks this queue shows.
    ///
    /// When set, only tasks belonging to that session are surfaced (the
    /// transfer queue is global in the Rust engine, so each window/tab filters
    /// to its own session). `nil` shows all sessions (legacy behavior).
    var sessionId: UInt64? {
        didSet {
            guard sessionId != oldValue else { return }
            // Never leave tasks from the previously selected session visible
            // while waiting for the next poll.
            tasks = []
            progressSamples.removeAll()
            transferSpeeds.removeAll()
        }
    }
    private var refreshTask: Task<Void, Never>?
    private var progressSamples: [UInt64: (bytes: UInt64, date: Date)] = [:]
    private var transferSpeeds: [UInt64: Double] = [:]

    init(bridge: any RemoteBridging) {
        self.bridge = bridge
    }

    /// Returns tasks filtered to this queue's session (or all when nil).
    /// Internal so the session-scoping behavior can be unit-tested.
    func filteredTasks(from fetched: [TransferTaskRecord]) -> [TransferTaskRecord] {
        guard let sessionId else { return fetched }
        return fetched.filter { $0.sessionId == sessionId }
    }

    func startPolling() {
        refreshTask?.cancel()
        refreshTask = Task {
            while !Task.isCancelled {
                await refresh()
                // Poll every second while a transfer is active; back off to
                // 5 seconds when idle to avoid unneeded FFI + redraws.
                let hasActive = tasks.contains { task in
                    switch task.status {
                    case .pending, .inProgress: return true
                    case .completed, .failed, .cancelled: return false
                    }
                }
                let delay: Duration = hasActive ? .seconds(1) : .seconds(5)
                try? await Task.sleep(for: delay)
            }
        }
    }

    func stopPolling() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh() async {
        // Do NOT clear tasks on disconnect: the user must be able to inspect
        // and retry failed transfers after reconnecting. Progress speeds are
        // stale once disconnected and are reset.
        guard bridge.isConnected else {
            progressSamples.removeAll()
            transferSpeeds.removeAll()
            return
        }

        do {
            let fetched = try await bridge.fetchTransferTasks()
            guard bridge.isConnected else {
                progressSamples.removeAll()
                transferSpeeds.removeAll()
                return
            }
            let sessionTasks = filteredTasks(from: fetched)
            updateProgressSamples(for: sessionTasks)
            if sessionTasks != tasks {
                tasks = sessionTasks
            }
            if errorMessage != nil {
                errorMessage = nil
            }
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
