import Foundation

enum DropOperationSync {
    static func run<T: Sendable>(_ operation: @escaping @MainActor () async -> T) -> T {
        var result: T?
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in
            result = await operation()
            semaphore.signal()
        }

        let pumpMainRunLoop = {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
        }

        while semaphore.wait(timeout: .now()) == .timedOut {
            if Thread.isMainThread {
                pumpMainRunLoop()
            } else {
                // Use async instead of sync to avoid deadlocking when the
                // main thread is occupied by another synchronous call.
                DispatchQueue.main.async(execute: pumpMainRunLoop)
            }
        }

        // The semaphore is only signaled after `result` is assigned, so this
        // force-unwrap is safe. Use guard for a clearer crash message.
        guard let result else {
            preconditionFailure("DropOperationSync: semaphore signaled without a result")
        }
        return result
    }
}
