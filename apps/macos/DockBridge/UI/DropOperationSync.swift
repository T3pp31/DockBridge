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
                DispatchQueue.main.sync(execute: pumpMainRunLoop)
            }
        }

        guard let result else {
            preconditionFailure("DropOperationSync: semaphore signaled without a result")
        }
        return result
    }
}
