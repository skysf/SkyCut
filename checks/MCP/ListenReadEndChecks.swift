import Foundation

// 文件 listen 的有界读取怎么结束：还在排队时超时 / 取消直接回来，已经开读时撞上截止时间 / 被取消，等读取体这一次 copy 返回、
// 自己收尾再回；都不交半份统计，之后同一条队列马上能再读。真实生产入口（AIListenAudioWindow.read）+ 现造的一小时稀疏 WAV。
// 判的是「回来的是什么、reader 开没开读、收没收尾」，不判「几秒内回来」（2026-11-13，docs/bugfixes/2026-11-13-listen-range-checks-timed-out-under-load.md）。
//
// **要测哪个阶段，先用生产的阶段探针（AIListenAudioWindow.Event）证明走到了那个阶段，再触发停** —— 不 sleep 一小会儿去猜：
//   - 排队中：analysis 挂着，等到 queued（读取 operation 已经交给队列）才取消 / 才算截止时间打在排队上。没到 queued 就结束的那一轮
//     停在读元数据那一段，不算测到了排队：截止时间放长四倍再来，放到 listenCheckHangBound 还排不上才算红。
//   - 读到一半：等到 started，读取体停在 analysis 上，等 stopRequested（停的原因登记了）才往下读，下一次检查就该停。
//     不赌「一小时的音频读得比截止时间慢」，也不拿「墙上时钟过了截止时间」当「停的信号到了」。
// 等结局、等探针的时间只拦卡死（排队中没人恢复调用方就是这种卡死：等满 listenCheckHangBound 判红，不让整组挂到看门狗）。
// 不管什么：读得对不对（ListenRangeChecks）、reader 的收尾在哪个队列（ListenReaderLifecycleChecks）。

@MainActor
func checkListenReadEnds(_ url: URL) async {
    await checkExpiredListenDeadline(url)
    // 排队等待也计入截止时间；不能只取消 await、把无效解码留在后台。
    MediaReadQueue.analysis.isSuspended = true
    do {
        defer { MediaReadQueue.analysis.cancelAllOperations(); MediaReadQueue.analysis.isSuspended = false }
        await checkQueuedListenTimeout(url)
        await checkQueuedListenCancel(url)
    }
    await checkActiveListenTimeout(url)
    await checkActiveListenCancel(url)
    // 取消之后同一队列马上可再用，结束的是这一窗，不会停掉别的调用。
    do {
        let reading = try await AIListenAudioWindow.read(url, from: listenRangeStart, to: listenRangeStart + 0.1,
                                                       until: Date().addingTimeInterval(listenCheckHangBound))
        check(reading.peaks.isComplete, "a fresh bounded read succeeds after cancellation/timeout")
    } catch { check(false, "reader/queue did not recover: \(error)") }
}

/// 截止时间在调用那一刻就已经过了：停在读元数据之前，不往队列上排、不开读（排队之前的那个阶段，不用等任何东西）。
@MainActor
private func checkExpiredListenDeadline(_ url: URL) async {
    let run = await queuedListenRead(url, until: .distantPast, wait: listenCheckHangBound)
    check(run.timedOut, "a range whose deadline has already passed fails with an explicit timeout: \(String(describing: run.outcome))")
    check(!run.queued && run.starts == 0, "an already expired deadline stops before the decode queue: nothing queued, nothing read")
}

/// 排队中撞上截止时间：等到 queued 才算数。截止时间在排上队之前就到了（机器忙，还在读元数据）：这一轮没测到「排队中」，
/// 截止时间放长四倍再来。排上了队，挂着的队列永远轮不到它，回得来就说明超时没有等队列腾位置。
@MainActor
private func checkQueuedListenTimeout(_ url: URL) async {
    var allowance: TimeInterval = 0.25
    while true {
        let run = await queuedListenRead(url, until: Date().addingTimeInterval(allowance), wait: allowance + listenCheckHangBound)
        if !run.queued, run.timedOut, allowance < listenCheckHangBound {
            allowance = min(allowance * 4, listenCheckHangBound)
            continue
        }
        check(run.queued, "queued timeout regression sees the read handed to the suspended decode queue before its deadline")
        if run.outcome == nil {
            check(false, "a range that timed out while queued never returned: nothing resumed the caller waiting on the decode queue")
        } else {
            check(run.timedOut, "a queued range past its deadline fails with an explicit timeout, without a partial report: \(String(describing: run.outcome))")
        }
        check(MediaReadQueue.analysis.isSuspended && run.starts == 0,
              "a queued timeout returns while the decode queue is still suspended, without starting the read")
        return
    }
}

/// 排队中被取消：等到 queued 才取消（不是起了 Task 之后 sleep 一小会儿 —— 那可能还在读元数据）。
@MainActor
private func checkQueuedListenCancel(_ url: URL) async {
    let run = await queuedListenRead(url, until: Date().addingTimeInterval(listenCheckHangBound), wait: listenCheckHangBound,
                                     onQueued: { $0.cancel() })
    check(run.queued, "queued cancel regression sees the read handed to the suspended decode queue before cancelling it")
    switch run.outcome {
    case .success?: check(false, "cancelled source window must not succeed")
    case .failure(let error)?: check(error is CancellationError, "queued source-window cancellation propagates: \(error)")
    case nil: check(false, "a range cancelled while queued never returned: nothing resumed the caller waiting on the decode queue")
    }
    check(MediaReadQueue.analysis.isSuspended && run.starts == 0,
          "a queued cancellation returns while the decode queue is still suspended, without starting the read")
}

private struct QueuedListenRun {
    /// 看到了 queued 探针：读取 operation 交给了 analysis 队列。
    var queued = false
    /// started 探针响了几次（队列挂着，应该一次都没有）。
    var starts = 0
    /// nil = 等满了也没回来。
    var outcome: Result<AIListenAudioWindow.Reading, Error>?

    var timedOut: Bool {
        if case .failure(let error as AIToolError)? = outcome { return error.message.contains("timed out") }
        return false
    }
}

/// 读一窗（测排队的两项，调用方先把 analysis 挂起）：看到 queued 探针就做 `onQueued`，再等结局，最多等 `wait` 秒（只拦卡死）。
/// 没到 queued 调用就结束了（停在读元数据那一段）：`queued` 是 false，结局照报。
@MainActor
private func queuedListenRead(
    _ url: URL, until deadline: Date, wait: TimeInterval,
    onQueued: (Task<AIListenAudioWindow.Reading, Error>) -> Void = { _ in }
) async -> QueuedListenRun {
    let (handoffs, feed) = AsyncStream<Void>.makeStream()
    let starts = ListenEventCount()
    let task = Task {
        defer { feed.finish() }
        return try await AIListenAudioWindow.read(url, from: 3_200, to: 3_201, until: deadline, observe: { event in
            switch event {
            case .queued: feed.yield()
            case .started: starts.add()
            case .stopRequested, .finished: break
            }
        })
    }
    var run = QueuedListenRun()
    for await _ in handoffs {
        run.queued = true
        onQueued(task)
        break
    }
    run.outcome = await listenOutcome(of: task, within: wait)
    run.starts = starts.value
    return run
}

/// 一个 task 的结局，最多等 `seconds`（只拦卡死）；到时还没回来是 nil。那个 task 留在后台，不再等它。
private func listenOutcome<Value: Sendable>(of task: Task<Value, Error>, within seconds: TimeInterval) async -> Result<Value, Error>? {
    let (outcomes, feed) = AsyncStream<Result<Value, Error>?>.makeStream()
    Task { feed.yield(await task.result) }
    let giveUp = Task {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        feed.yield(nil)
    }
    defer { giveUp.cancel() }
    for await outcome in outcomes { return outcome }
    return nil
}

/// 读到一半撞上截止时间：开读那一刻 reader 停在读取队列上，等截止时间的停登记了（stopRequested）再往下读，下一次检查就该停 ——
/// 快机器上一小时也许一秒就读完，慢机器上开读之前截止时间就到了，两头都不赌。截止时间在开读之前就到了（机器忙，还在读元数据 / 排队）：
/// 这一轮没测到「读到一半」，截止时间放长四倍再来，放到 listenCheckHangBound 还开不了读才算红（那已经是卡死的量级）。
@MainActor
private func checkActiveListenTimeout(_ url: URL) async {
    var allowance: TimeInterval = 0.25
    while true {
        let run = await activeListenRead(url, until: Date().addingTimeInterval(allowance))
        var timedOut = false
        if case .failure(let error as AIToolError) = run.outcome { timedOut = error.message.contains("timed out") }
        if !run.began, timedOut, allowance < listenCheckHangBound {
            allowance = min(allowance * 4, listenCheckHangBound)
            continue
        }
        check(run.began, "active timeout regression observes actual native startReading before its deadline")
        check(run.stoppedMidRead, "the deadline's stop is recorded while the started reader is parked before its first copy")
        check(timedOut, "an active native read past its deadline fails with an explicit timeout, never partial statistics: \(run.outcome)")
        check(run.ended, "native reader has finished before the timed-out call returns")
        return
    }
}

/// 读到一半被取消：开读那一刻 reader 停住，等取消登记了（stopRequested）才往下读（不赌取消赶在一小时读完、或者截止时间之前）。
@MainActor
private func checkActiveListenCancel(_ url: URL) async {
    let run = await activeListenRead(url, until: Date().addingTimeInterval(listenCheckHangBound), onStart: { $0.cancel() })
    check(run.began, "active cancel regression observes actual native startReading on its owner queue")
    check(run.stoppedMidRead, "the cancellation is recorded while the started reader is parked before its first copy")
    switch run.outcome {
    case .success: check(false, "an actively cancelled read must not return partial statistics")
    case .failure(let error): check(error is CancellationError, "active native cancellation propagates: \(error)")
    }
    check(run.ended, "native reader has cancelled/finished before the cancelled call returns")
}

private struct ActiveListenRun {
    var began = false
    var ended = false
    /// reader 停在开读那一刻时，停的原因登记了（stopRequested 探针）—— 之后才放它往下读。
    var stoppedMidRead = false
    var outcome: Result<AIListenAudioWindow.Reading, Error> = .failure(CancellationError())
}

/// 读整小时（读不完就会撞上停）：开读（started 探针）那一刻读取体停在 analysis 上，等 stopRequested 探针（截止时间的 timer 或
/// 调用方的取消把停的原因登记了）再往下读；调用方看到开读再做 `onStart`。等探针最多两个 listenCheckHangBound（截止时间最长一个），只拦卡死。
/// 回来时报开没开读、停是不是在读取体停着的时候登记的、收没收尾（finished 探针在读取体的 defer 里，早于结果回来）和结局。
@MainActor
private func activeListenRead(
    _ url: URL, until deadline: Date, onStart: (Task<AIListenAudioWindow.Reading, Error>) -> Void = { _ in }
) async -> ActiveListenRun {
    let (events, feed) = AsyncStream<AIListenAudioWindow.Event>.makeStream()
    let stopRecorded = DispatchSemaphore(value: 0)
    let parkedUntilStop = ListenEventCount()
    let task = Task {
        defer { feed.finish() }
        return try await AIListenAudioWindow.read(url, from: 0, to: 3_600, until: deadline, observe: { event in
            feed.yield(event)
            switch event {
            case .stopRequested: stopRecorded.signal()
            case .started:
                if stopRecorded.wait(timeout: .now() + 2 * listenCheckHangBound) == .success { parkedUntilStop.add() }
            case .queued, .finished: break
            }
        })
    }
    var run = ActiveListenRun()
    for await event in events {
        switch event {
        case .started: run.began = true; onStart(task)
        case .finished: run.ended = true
        case .queued, .stopRequested: break
        }
    }
    run.outcome = await task.result
    run.stoppedMidRead = parkedUntilStop.value == 1
    return run
}

private final class ListenEventCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}
