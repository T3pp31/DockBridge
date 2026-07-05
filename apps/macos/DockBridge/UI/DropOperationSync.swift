import Foundation

enum DropOperationSync {
    /// Runs an `@MainActor` async operation synchronously, pumping the main run
    /// loop so the main actor can make progress while the caller waits on a
    /// semaphore.
    ///
    /// The semaphore is always signaled via `defer`, so the caller can never
    /// hang even if `operation` throws or the underlying Task is cancelled.
    /// Errors thrown by `operation` are re-thrown to the caller.
    static func run<T: Sendable>(_ operation: @escaping @MainActor () async throws -> T) throws -> T {
        var result: T?
        var thrownError: Error?
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in
            defer { semaphore.signal() }
            do {
                result = try await operation()
            } catch {
                thrownError = error
            }
        }

        let pumpMainRunLoop = {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
        }

        while semaphore.wait(timeout: .now()) == .timedOut {
            if Thread.isMainThread {
                pumpMainRunLoop()
            } else {
                DispatchQueue.main.sync(execute: pumpMainRunLoop)
            }
        }

        if let thrownError {
            throw thrownError
        }
        guard let result else {
            preconditionFailure("DropOperationSync: semaphore signaled without a result or error")
        }
        return result
    }
}
