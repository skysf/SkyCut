import AVFoundation
import Foundation

// 在真实 reader 的 started 探针处暂停读取队列，尚未调用 copy；外部取消因此能安全、确定地复现旧跨线程收尾。
// 子类只记录取消/释放的队列，仍由原生 AVAssetReader 建立和收尾；不伪造音频统计，也不赌原生崩溃概率。
// 截止时间和闸门的等待只拦卡死（listenCheckHangBound）：闸门总会被放开，等多久不是要证明的事（2026-11-13 之前 2 秒，满载时会误报）。
@MainActor
func runListenReaderLifecycleChecks(_ url: URL) async {
    await checkListenLoadingCancellation(url)
    let trace = ListenReaderLifecycleTrace()
    let release = DispatchSemaphore(value: 0)
    let (events, feed) = AsyncStream<AIListenAudioWindow.Event>.makeStream()
    let task = Task {
        defer { feed.finish() }
        return try await AIListenAudioWindow.read(url, from: 0, to: 1, until: Date().addingTimeInterval(listenCheckHangBound),
            observe: { event in
                switch event {
                case .started:
                    feed.yield(event)
                    trace.noteWait(release.wait(timeout: .now() + listenCheckHangBound) == .success)
                case .finished:
                    trace.noteFinished()
                }
            }, readerFactory: { try ListenReaderLifecycleProbe(asset: $0, trace: trace) })
    }
    var began = false
    for await event in events {
        if case .started = event { began = true; break }
    }
    check(began, "lifecycle guard pauses an actual started reader before its first native copy")
    task.cancel()
    let beforeRelease = trace.snapshot
    check(beforeRelease.cancelQueues.isEmpty, "external cancellation never tears down a reader owned by the blocked analysis operation")
    release.signal()
    do { _ = try await task.value; check(false, "cancelled lifecycle read cannot publish statistics") }
    catch is CancellationError { check(true, "lifecycle cancellation is propagated after native cleanup") }
    catch { check(false, "wrong lifecycle cancellation: \(error)") }
    let result = trace.snapshot
    checkEqual(result.cancelQueues.count, 1, "native reader has exactly one cancellation owner")
    check(result.cancelQueues.allSatisfy { $0 }, "native cancellation stays on the same analysis operation as copying")
    checkEqual(result.releaseQueues, [true], "reader is released on analysis before the caller resumes")
    check(result.finished && result.waitReleased, "read returns only after its native owner finished, without a timing sleep")
}

@MainActor
private func checkListenLoadingCancellation(_ url: URL) async {
    let loadingAsset = ListenLoadingCancellationProbe(url: url)
    let loading = AIListenReadControl(asset: loadingAsset)
    loading.cancel()
    loading.finish()
    checkEqual(loadingAsset.cancelCount, 1, "metadata cancellation still immediately stops pending asset loading")

    let activeAsset = ListenLoadingCancellationProbe(url: url)
    let active = AIListenReadControl(asset: activeAsset)
    let release = DispatchSemaphore(value: 0)
    let (events, feed) = AsyncStream<Bool>.makeStream()
    let task = Task {
        defer { active.finish(); feed.finish() }
        return try await withTaskCancellationHandler {
            try await active.run {
                feed.yield(true)
                guard release.wait(timeout: .now() + listenCheckHangBound) == .success else { throw AIToolError("Lifecycle gate timed out.") }
                try active.check()
                throw AIToolError("Cancelled work must stop at its next check.")
            }
        } onCancel: { active.cancel() }
    }
    for await _ in events { break }
    task.cancel()
    checkEqual(activeAsset.cancelCount, 0, "after the operation handoff, cancellation never cancels its asset loading")
    release.signal()
    do { _ = try await task.value; check(false, "active phase cancellation must fail") }
    catch is CancellationError { check(true, "active phase retains its failure until the owner unwinds") }
    catch { check(false, "wrong active phase cancellation: \(error)") }
}

private final class ListenReaderLifecycleProbe: AVAssetReader, @unchecked Sendable {
    private let trace: ListenReaderLifecycleTrace

    init(asset: AVAsset, trace: ListenReaderLifecycleTrace) throws {
        self.trace = trace
        try super.init(asset: asset)
    }

    override func cancelReading() {
        trace.noteCancel()
        super.cancelReading()
    }

    deinit { trace.noteRelease() }
}

private final class ListenReaderLifecycleTrace: @unchecked Sendable {
    struct Snapshot {
        var cancelQueues: [Bool] = []
        var releaseQueues: [Bool] = []
        var finished = false
        var waitReleased = false
    }
    private let lock = NSLock()
    private var value = Snapshot()
    var snapshot: Snapshot { lock.withLock { value } }
    func noteCancel() { lock.withLock { value.cancelQueues.append(OperationQueue.current === MediaReadQueue.analysis) } }
    func noteRelease() { lock.withLock { value.releaseQueues.append(OperationQueue.current === MediaReadQueue.analysis) } }
    func noteFinished() { lock.withLock { value.finished = true } }
    func noteWait(_ released: Bool) { lock.withLock { value.waitReleased = released } }
}

private final class ListenLoadingCancellationProbe: AVURLAsset, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var cancelCount: Int { lock.withLock { calls } }
    override func cancelLoading() { lock.withLock { calls += 1 } }
}
