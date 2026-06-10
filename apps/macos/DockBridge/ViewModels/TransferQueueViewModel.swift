import Foundation

@MainActor
final class TransferQueueViewModel: ObservableObject {
    @Published private(set) var tasks: [TransferTaskRecord] = []
    @Published var errorMessage: String?

    private let bridge: RustBridgeService
    private var refreshTask: Task<Void, Never>?

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
            return
        }

        do {
            let fetched = try await bridge.fetchTransferTasks()
            guard bridge.isConnected else {
                tasks = []
                return
            }
            tasks = fetched
            errorMessage = nil
        } catch {
            tasks = []
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
}
