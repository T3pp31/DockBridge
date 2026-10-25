import Foundation

enum DropOperationSync {
    /// Upper bound for a synchronous drop operation. Long-running work should
    /// be made async instead of relying on this bridge.
    private static let timeout: TimeInterval = 30

    /// Runs an `@MainActor` async operation synchronously, pumping the main run
    /// loop so the main actor can make progress while the caller waits on a
    /// semaphore.
    ///
    /// The semaphore is signaled when the operation completes or throws. If
    /// the operation hangs, the bridge times out, cancels the unstructured
    /// Task, and lets the caller regain control.
    /// Errors thrown by `operation` are re-thrown to the caller.
    ///
    /// - Throws: `DropOperationSyncError.timedOut` when the operation does not
    ///   finish within [`timeout`], or any error thrown by `operation`.
    static func run<T: Sendable>(
        timeout: TimeInterval = DropOperationSync.timeout,
        _ operation: @escaping @MainActor () async throws -> T
    ) throws -> T {
        var completion: Result<T, Error>?
        let semaphore = DispatchSemaphore(value: 0)
        let task = Task { @MainActor in
            defer { semaphore.signal() }
            do {
                completion = .success(try await operation())
            } catch {
                completion = .failure(error)
            }
        }

        let deadline = Date.now.addingTimeInterval(timeout)

        let pumpMainRunLoop = {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
        }

        while semaphore.wait(timeout: .now()) == .timedOut {
            if Date.now.timeIntervalSince1970 >= deadline {
                task.cancel()
                throw DropOperationSyncError.timedOut
            }

            if Thread.isMainThread {
                pumpMainRunLoop()
            } else {
                DispatchQueue.main.sync(execute: pumpMainRunLoop)
            }
        }

        switch completion {
        case .success(let result):
            return result
        case .failure(let error):
            throw error
        case .none:
            preconditionFailure("DropOperationSync: semaphore signaled without a result or error")
        }
    }
}

enum DropOperationSyncError: Error {
    case timedOut
}
