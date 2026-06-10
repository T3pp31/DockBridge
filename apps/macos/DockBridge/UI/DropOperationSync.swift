import Foundation

enum DropOperationSync {
    static func run<T: Sendable>(_ operation: @escaping @MainActor () async -> T) -> T {
        if Thread.isMainThread {
            var result: T!
            let semaphore = DispatchSemaphore(value: 0)
            Task { @MainActor in
                result = await operation()
                semaphore.signal()
            }
            while semaphore.wait(timeout: .now()) == .timedOut {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
            }
            return result!
        }

        return DispatchQueue.main.sync {
            run(operation)
        }
    }
}
