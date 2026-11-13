import Foundation

// 文件 listen 的有界读取怎么结束：还在排队时超时 / 取消直接回来，已经开读时撞上截止时间 / 被取消，等读取体这一次 copy 返回、
// 自己收尾再回；都不交半份统计，之后同一条队列马上能再读。真实生产入口（AIListenAudioWindow.read）+ 现造的一小时稀疏 WAV。
// 判的是「回来的是什么、reader 开没开读、收没收尾」，不判「几秒内回来」（2026-11-13，docs/bugfixes/2026-11-13-listen-range-checks-timed-out-under-load.md）：
// 排队那一组让 analysis 挂着，回得来就说明没等队列；读到一半那一组让 reader 开读之后停在 started 探针上，等停的原因有了再往下读，
// 不赌「一小时的音频读得比截止时间慢」。不管什么：读得对不对（ListenRangeChecks）、reader 的收尾在哪个队列（ListenReaderLifecycleChecks）。

@MainActor
func checkListenReadEnds(_ url: URL) async {
    // 排队等待也计入截止时间；不能只取消 await、把无效解码留在后台。
    MediaReadQueue.analysis.isSuspended = true
    do {
        defer { MediaReadQueue.analysis.cancelAllOperations(); MediaReadQueue.analysis.isSuspended = false }
        let starts = ListenEventCount()
        do {
            _ = try await AIListenAudioWindow.read(url, from: 3_200, to: 3_201, until: Date().addingTimeInterval(0.05),
                                                   observe: { if case .started = $0 { starts.add() } })
            check(false, "a queued range past its deadline must fail, without a partial report")
        } catch let error as AIToolError {
            check(error.message.contains("timed out"), "queued timeout has an explicit failure message")
        } catch { check(false, "wrong queued timeout: \(error)") }
        // analysis 一直挂着，排进去的那一窗永远轮不到：回得来本身就说明超时没有等队列腾位置（以前量「1 秒内回来」，满载时会误报）。
        check(MediaReadQueue.analysis.isSuspended && starts.value == 0,
              "a queued timeout returns while the decode queue is still suspended, without starting the read")
        let task = Task {
            try await AIListenAudioWindow.read(url, from: 3_200, to: 3_201, until: Date().addingTimeInterval(listenCheckHangBound))
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do { _ = try await task.value; check(false, "cancelled source window must not succeed") }
        catch is CancellationError { check(true, "queued source-window cancellation propagates") }
        catch { check(false, "wrong cancellation error: \(error)") }
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

/// 读到一半撞上截止时间：开读那一刻 reader 停在读取队列上，睡到截止时间过了再往下读，下一次检查就该停 —— 快机器上一小时也许
/// 一秒就读完，慢机器上开读之前截止时间就到了，两头都不赌。截止时间在开读之前就到了（机器忙，还在读元数据 / 排队）：这一轮没测到
///「读到一半」，截止时间放长四倍再来，放到 listenCheckHangBound 还开不了读才算红（那已经是卡死的量级）。
@MainActor
private func checkActiveListenTimeout(_ url: URL) async {
    var allowance: TimeInterval = 0.25
    while true {
        let deadline = Date().addingTimeInterval(allowance)
        let run = await activeListenRead(url, until: deadline, hold: { Thread.sleep(until: deadline.addingTimeInterval(0.25)) })
        var timedOut = false
        if case .failure(let error as AIToolError) = run.outcome { timedOut = error.message.contains("timed out") }
        if !run.began, timedOut, allowance < listenCheckHangBound {
            allowance = min(allowance * 4, listenCheckHangBound)
            continue
        }
        check(run.began, "active timeout regression observes actual native startReading before its deadline")
        check(timedOut, "an active native read past its deadline fails with an explicit timeout, never partial statistics: \(run.outcome)")
        check(run.ended, "native reader has finished before the timed-out call returns")
        return
    }
}

/// 读到一半被取消：开读那一刻 reader 停住，等调用方真的取消了才往下读（不赌取消赶在一小时读完、或者截止时间之前）。
@MainActor
private func checkActiveListenCancel(_ url: URL) async {
    let gate = DispatchSemaphore(value: 0)
    let run = await activeListenRead(url, until: Date().addingTimeInterval(listenCheckHangBound),
                                     hold: { _ = gate.wait(timeout: .now() + listenCheckHangBound) },
                                     onStart: { task in task.cancel(); gate.signal() })
    check(run.began, "active cancel regression observes actual native startReading on its owner queue")
    switch run.outcome {
    case .success: check(false, "an actively cancelled read must not return partial statistics")
    case .failure(let error): check(error is CancellationError, "active native cancellation propagates: \(error)")
    }
    check(run.ended, "native reader has cancelled/finished before the cancelled call returns")
}

private struct ActiveListenRun {
    var began = false
    var ended = false
    var outcome: Result<AIListenAudioWindow.Reading, Error> = .failure(CancellationError())
}

/// 读整小时（读不完就会撞上停）：开读（started 探针）那一刻读取体停在 analysis 上跑 `hold`，调用方看到开读再做 `onStart`。
/// 回来时报开没开读、收没收尾（finished 探针在读取体的 defer 里，早于结果回来）和结局。
@MainActor
private func activeListenRead(_ url: URL, until deadline: Date, hold: @escaping @Sendable () -> Void,
                              onStart: (Task<AIListenAudioWindow.Reading, Error>) -> Void = { _ in }) async -> ActiveListenRun {
    let (events, feed) = AsyncStream<AIListenAudioWindow.Event>.makeStream()
    let task = Task {
        defer { feed.finish() }
        return try await AIListenAudioWindow.read(url, from: 0, to: 3_600, until: deadline, observe: { event in
            feed.yield(event)
            if case .started = event { hold() }
        })
    }
    var run = ActiveListenRun()
    for await event in events {
        switch event {
        case .started: run.began = true; onStart(task)
        case .finished: run.ended = true
        }
    }
    run.outcome = await task.result
    return run
}

private final class ListenEventCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}
