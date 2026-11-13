import AVFoundation
import Foundation

// 管什么：一次 listen 文件短窗读取的取消与截止时间；排队时直接结束，读取时只发出停止信号。
// 不管什么：波形总览的共享任务、音频统计、工程或界面。只属于这一通调用，不取消别的消费者。

final class AIListenReadControl: @unchecked Sendable {
    private let lock = NSLock()
    private let asset: AVURLAsset
    /// 阶段探针（自检用，平时 nil）：排上队、停的原因登记了，各报一声。
    private let observe: (@Sendable (AIListenAudioWindow.Event) -> Void)?
    private var failure: Error?
    private var operation: BlockOperation?
    private var continuation: CheckedContinuation<Result<AIListenAudioWindow.Reading, Error>, Never>?
    private var running = false
    private var loading = true
    private var finished = false
    private var timer: DispatchSourceTimer?

    init(asset: AVURLAsset, observe: (@Sendable (AIListenAudioWindow.Event) -> Void)? = nil) {
        self.asset = asset
        self.observe = observe
    }

    func start(until deadline: Date) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + max(0, deadline.timeIntervalSinceNow))
        timer.setEventHandler { [weak self] in
            self?.stop(AIToolError("Listening to this source range timed out; no partial audio report was returned. Try a shorter range."))
        }
        lock.withLock { self.timer = timer }
        timer.resume()
        if deadline <= Date() {
            stop(AIToolError("Listening to this source range timed out; no partial audio report was returned. Try a shorter range."))
        }
    }

    func cancel() { stop(CancellationError()) }

    func check() throws {
        if let error = lock.withLock({ failure }) { throw error }
    }

    /// 排队时取消不等队列腾位置；已开读等当前 native copy 返回，由读取体单点收尾后再回结果。
    func run(_ work: @escaping @Sendable () throws -> AIListenAudioWindow.Reading) async throws -> AIListenAudioWindow.Reading {
        let result: Result<AIListenAudioWindow.Reading, Error> = await withCheckedContinuation { continuation in
            let operation = BlockOperation { [self] in
                guard begin() else { return }
                // 原生 reader/output 的最后释放也留在读取队列，先收尾再恢复调用方。
                let result = autoreleasepool { Result { try check(); return try work() } }
                complete(result)
            }
            let error = lock.withLock { () -> Error? in
                if let failure { return failure }
                // stop 先拿锁会留下 failure，永不开读；这里先拿锁后 stop 不再 cancelLoading。
                loading = false
                self.continuation = continuation
                self.operation = operation
                return nil
            }
            if let error { continuation.resume(returning: .failure(error)) }
            else {
                MediaReadQueue.analysis.addOperation(operation)
                observe?(.queued)
            }
        }
        try check()
        return try result.get()
    }

    func finish() {
        let timer = lock.withLock { () -> DispatchSourceTimer? in
            finished = true
            let timer = self.timer
            self.timer = nil
            operation = nil
            return timer
        }
        timer?.cancel()
    }

    private func begin() -> Bool {
        lock.withLock {
            guard failure == nil else { return false }
            running = true
            return true
        }
    }

    private func complete(_ result: Result<AIListenAudioWindow.Reading, Error>) {
        let pending = lock.withLock { () -> CheckedContinuation<Result<AIListenAudioWindow.Reading, Error>, Never>? in
            let pending = continuation
            continuation = nil
            running = false
            return pending
        }
        pending?.resume(returning: result)
    }

    private func stop(_ error: Error) {
        let resources = lock.withLock { () -> (AVURLAsset?, BlockOperation?, CheckedContinuation<Result<AIListenAudioWindow.Reading, Error>, Never>?)? in
            guard !finished, failure == nil else { return nil }
            failure = error
            let pending = running ? nil : continuation
            if !running { continuation = nil }
            return (loading ? asset : nil, operation, pending)
        }
        // 已经收尾、或者早有别的原因在先：这一次不算数，也不报探针。
        guard let resources else { return }
        // AVAssetReader.cancelReading 不许与 copyNextSampleBuffer 并发；读取阶段只让 check() 停循环。
        resources.0?.cancelLoading()
        resources.1?.cancel()
        resources.2?.resume(returning: .failure(error))
        observe?(.stopRequested)
    }
}
