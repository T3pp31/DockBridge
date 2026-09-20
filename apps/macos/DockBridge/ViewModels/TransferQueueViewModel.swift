import AppKit
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
            previousTasks = nil
            progressSamples.removeAll()
            transferSpeeds.removeAll()
            refreshGeneration &+= 1
            updateDockBadge(tasks: [])
        }
    }
    private let settings: AppSettingsService
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration: UInt64 = 0
    private var progressSamples: [UInt64: (bytes: UInt64, date: Date)] = [:]
    private var transferSpeeds: [UInt64: Double] = [:]
    /// Previous snapshot used to detect active -> completed/failed transitions.
    /// `nil` until the first fetch so already-finished tasks are not re-notified.
    private var previousTasks: [TransferTaskRecord]?

    init(
        bridge: any RemoteBridging,
        settings: AppSettingsService = .shared
    ) {
        self.bridge = bridge
        self.settings = settings
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
            updateDockBadge(tasks: [])
            return
        }
        refreshGeneration &+= 1
        let generation = refreshGeneration

        do {
            let fetched = try await bridge.fetchTransferTasks()
            guard generation == refreshGeneration, bridge.isConnected else {
                progressSamples.removeAll()
                transferSpeeds.removeAll()
                updateDockBadge(tasks: [])
                return
            }
            let sessionTasks = filteredTasks(from: fetched)
            updateProgressSamples(for: sessionTasks)
            let finished = finishedTransitions(from: previousTasks, to: sessionTasks)
            // Advance the snapshot before posting notifications. Together
            // with the generation check, this prevents overlapping refreshes
            // from reporting the same transition or applying stale results.
            previousTasks = sessionTasks
            if sessionTasks != tasks {
                tasks = sessionTasks
            }
            notifyFinishedTransitions(finished)
            updateDockBadge(tasks: sessionTasks)
            if errorMessage != nil {
                errorMessage = nil
            }
        } catch {
            guard generation == refreshGeneration else { return }
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
    /// pending/in-progress to completed/failed, but only while the app is in the
    /// background (otherwise the queue UI is the feedback). The first fetch
    /// has no previous snapshot and never notifies (no spurious notifications
    /// for tasks that finished before the app looked at them).
    func finishedTransitions(
        from old: [TransferTaskRecord]?,
        to new: [TransferTaskRecord]
    ) -> [TransferTaskRecord] {
        guard let old else { return [] }
        let oldMap = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })

        return new.filter { task in
            guard let previous = oldMap[task.id] else { return false }
            let wasActive = previous.status == .inProgress || previous.status == .pending
            switch task.status {
            case .completed, .failed:
                return wasActive
            case .cancelled, .pending, .inProgress:
                return false
            }
        }
    }

    private func notifyFinishedTransitions(_ finished: [TransferTaskRecord]) {
        let config = settings.loadConfig()
        guard config.notifyWhenTransfersFinish, !NSApp.isActive else { return }

        for task in finished {
            let direction = task.direction == .upload
                ? String(localized: "Upload")
                : String(localized: "Download")
            let title: String
            switch task.status {
            case .completed:
                title = String(
                    format: String(localized: "%@ finished"),
                    direction
                )
            case .failed:
                title = String(
                    format: String(localized: "%@ failed"),
                    direction
                )
            case .cancelled, .pending, .inProgress:
                continue
            }

            let statusKey: String
            switch task.status {
            case .completed: statusKey = "completed"
            case .failed: statusKey = "failed"
            case .cancelled, .pending, .inProgress: continue
            }
            TransferNotificationService.post(
                identifier: "transfer-\(task.id)-\(statusKey)",
                title: title,
                body: URL(fileURLWithPath: task.localPath).lastPathComponent,
                playSound: config.playTransferNotificationSound
            )
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
