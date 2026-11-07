import Foundation

// 钥匙串唯一的串行执行器：原生 Security 调用可等系统框，不能占 Swift 协作线程或主线程。
// 同一进程的交互开关也在这里串行使用，静默读、交互读、写入、删除不会互相改变开关。
enum KeychainSecretExecutor {
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.srtflow.keychain"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.addOperation { continuation.resume(returning: work()) }
        }
    }

    static func preconditionIsolated() {
        precondition(OperationQueue.current === queue, "Keychain operations require their serial executor")
    }
}
