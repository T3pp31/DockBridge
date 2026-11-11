import Foundation

enum DropOperationSync {
    /// Deadline for requesting cancellation. Long-running work should be made
    /// async instead of relying on this bridge.
    private static let timeout: TimeInterval = 30

    /// Runs an `@MainActor` async operation synchronously, pumping the main run
    /// loop so the main actor can make progress while the caller waits on a
    /// semaphore.
    ///
    /// The semaphore is signaled when the operation completes or throws. At
    /// the deadline, the bridge requests cancellation, then keeps pumping the
    /// run loop until the operation finishes, rather than abandoning it on return.
    /// Cancellation is cooperative: operations must eventually finish, including
    /// resuming any continuations on cancellation. The timeout is not a hard
    /// upper bound on the duration of this call, and already committed side
    /// effects cannot be rolled back by this bridge.
    ///
    /// - Throws: `DropOperationSyncError.timedOut` after the operation finishes
    ///   if cancellation was requested at the deadline; otherwise any error
    ///   thrown by `operation`.
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

        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))

        let pumpMainRunLoop = {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
        }

        var didTimeOut = false
        while semaphore.wait(timeout: .now()) == .timedOut {
            if !didTimeOut && ContinuousClock.now >= deadline {
                didTimeOut = true
                task.cancel()
            }

            if Thread.isMainThread {
                pumpMainRunLoop()
            } else {
                DispatchQueue.main.sync(execute: pumpMainRunLoop)
            }
        }

        if didTimeOut {
            throw DropOperationSyncError.timedOut
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
