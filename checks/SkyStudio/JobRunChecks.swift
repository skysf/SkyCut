import Foundation
import SrtFlowMCPKit

// SkyStudioJobRun：交一件活、等它做完。满了在本机等着、用同一个 idempotency_key 再交；照 poll_after_seconds 问（夹在 2–60 秒）；
// 问的时候断网几次不算失败；停的时候排着队的退钱、开始了的取消不了、取消没送到说不准；服务器说没做成 / 回的不像话 / 等太久各是哪一种。
// 「睡」换成只记下睡多久、不真睡的（SleepLog），要停时让它在第几次睡的时候抛出 —— 就像 Task 在等的时候被取消了。

func runJobRunChecks() async {
    let api = jobAPI()
    let request = SkyStudioJobRequest(kind: "upscale", model: "topaz-starlight", params: ["target": "4K"], maxCredits: 455, idempotencyKey: "idem-run")
    func status(_ state: String, _ extra: String = "") -> String {
        #"{"job_id": "job-1", "status": "\#(state)", "poll_after_seconds": 15\#(extra)}"#
    }

    // 1. 一路做完：交上（排队）→ 排第 2 → 处理中 → 存进作品库 → 做完；每一份都报上来；照服务器说的间隔问（夹过）。
    var answers = [
        status("queued", #", "queue_position": 2"#), status("running", #", "phase": "processing""#),
        #"{"job_id": "job-1", "status": "running", "phase": "saving", "poll_after_seconds": 0.5}"#, sampleDoneJob
    ]
    SkyStudioStub.reset { seen in
        if seen.method == "POST" { return .http(202, status("queued", #", "credits_reserved": 455"#)) }
        return .http(200, answers.isEmpty ? sampleDoneJob : answers.removeFirst())
    }
    let sleeps = SleepLog()
    let updates = UpdateLog()
    var run = SkyStudioJobRun(api: api, key: jobKey)
    run.sleep = sleeps.sleep
    let done = try? await run.run(request) { updates.add($0) }
    checkEqual(done?.state, .done, "it ends done")
    checkEqual(done?.result?.url.absoluteString, "https://cdn.skystudioai.com/generations/abc.mp4", "with the result")
    checkEqual(updates.phases, ["queued", "queued", "running/processing", "running/saving", "done"], "every answer is reported, in order")
    checkEqual(sleeps.all, [15, 15, 15, 2], "asks again when the server says, clamped to at least 2 s")
    checkEqual(SkyStudioStub.log.filter { $0.method == "POST" }.count, 1, "submitted once")

    // 2. 满了：等着、用同一个 idempotency_key 再交；第二次交上了照常等完。
    var full = true
    SkyStudioStub.reset { seen in
        guard seen.method == "POST" else { return .http(200, sampleDoneJob) }
        if full {
            full = false
            return .http(429, #"{"error": {"code": "too_many_jobs", "message": "3 jobs are already open.", "limit": 3, "running": 3}}"#)
        }
        return .http(202, status("queued"))
    }
    let slotSleeps = SleepLog()
    let slotUpdates = UpdateLog()
    run.sleep = slotSleeps.sleep
    let afterWait = try? await run.run(request) { slotUpdates.add($0) }
    checkEqual(afterWait?.state, .done, "a full account waits, then finishes")
    checkEqual(slotUpdates.items.first, .waitingForSlot(running: 3, limit: 3), "waiting for a free slot is reported")
    checkEqual(slotSleeps.all.first, SkyStudioJobRun.slotRetrySeconds, "waits 15 s before trying again")
    let keys = SkyStudioStub.log.filter { $0.method == "POST" }.compactMap { $0.body.flatMap { try? JSONValue.decode($0) }?["idempotency_key"]?.stringValue }
    checkEqual(keys, ["idem-run", "idem-run"], "the second try carries the same idempotency key (charged once)")

    // 3. 交的时候断网：再交（同一个 key）；一直断就说没连上。
    var drops = 1
    SkyStudioStub.reset { seen in
        guard seen.method == "POST" else { return .http(200, sampleDoneJob) }
        if drops > 0 { drops -= 1; return .failure(.timedOut) }
        return .http(202, status("queued"))
    }
    run.sleep = SleepLog().sleep
    checkEqual(try? await run.run(request).state, .done, "a dropped submission is sent again")
    SkyStudioStub.reset { _ in .failure(.notConnectedToInternet) }
    if case .request(.network)? = await jobFailure({ _ = try await run.run(request) }) {
        checkEqual(SkyStudioStub.log.count, 1 + SkyStudioJobRun.submitRetries, "tries three times in all")
    } else {
        check(false, "no connection at all is a network failure")
    }

    // 4. 问的时候断网几次不算失败；连着问不到才算。
    var blips = 3
    SkyStudioStub.reset { seen in
        if seen.method == "POST" { return .http(202, status("queued")) }
        if blips > 0 { blips -= 1; return .failure(.networkConnectionLost) }
        return .http(200, sampleDoneJob)
    }
    checkEqual(try? await run.run(request).state, .done, "a few dropped polls do not fail the job")
    SkyStudioStub.reset { seen in seen.method == "POST" ? .http(202, status("queued")) : .failure(.networkConnectionLost) }
    if case .request(.network)? = await jobFailure({ _ = try await run.run(request) }) {
        checkEqual(SkyStudioStub.log.filter { $0.method == "GET" }.count, SkyStudioJobRun.networkMisses, "gives up after ten polls in a row fail")
    } else {
        check(false, "polls that keep failing are a network failure")
    }

    // 5. 服务器说没做成；做完却没有成品；认不出的状态；交的时候被拒（余额不够：服务器的话原样）。
    SkyStudioStub.reset { seen in
        seen.method == "POST" ? .http(202, status("queued")) : .http(200, status("failed", #", "error": "The provider failed.""#))
    }
    checkEqual(await jobFailure({ _ = try await run.run(request) }), .failed("The provider failed."), "a failed job says why")
    SkyStudioStub.reset { seen in seen.method == "POST" ? .http(202, status("queued")) : .http(200, status("done")) }
    if case .badAnswer? = await jobFailure({ _ = try await run.run(request) }) {} else { check(false, "done without a result is not an answer") }
    SkyStudioStub.reset { seen in seen.method == "POST" ? .http(202, status("queued")) : .http(200, status("paused")) }
    if case .badAnswer? = await jobFailure({ _ = try await run.run(request) }) {} else { check(false, "an unknown status is not an answer") }
    SkyStudioStub.reset { _ in
        .http(402, #"{"error": {"code": "insufficient_credits", "message": "You need 455 credits; you have 30.", "balance": 30, "needed": 455, "recharge_url": "https://skystudioai.com/app?credits=1"}}"#)
    }
    let poor = await jobFailure({ _ = try await run.run(request) })
    if case .request(.server(let error))? = poor {
        checkEqual(error.code, "insufficient_credits", "insufficient credits")
        checkEqual(error.fields["needed"]?.doubleValue, 455, "how much is needed")
        checkEqual(poor?.message, "You need 455 credits; you have 30.", "the server's own words go to the AI")
    } else {
        check(false, "a refused submission throws the server's error")
    }

    // 6. 停：在第 2 次等的时候被取消。排着队的退钱；开始了的取消不了；取消没送到说不准；服务器那边已经取消了也算没花钱。
    func stopping(cancelReply: SkyStudioStub.Reply) async -> SkyStudioJobError? {
        SkyStudioStub.reset { seen in
            if seen.url.hasSuffix("/cancel") { return cancelReply }
            return seen.method == "POST" ? .http(202, status("queued")) : .http(200, status("queued", #", "queue_position": 1"#))
        }
        var stopped = SkyStudioJobRun(api: api, key: jobKey)
        stopped.sleep = SleepLog(throwOnCall: 2).sleep
        return await jobFailure({ _ = try await stopped.run(request) })
    }
    checkEqual(await stopping(cancelReply: .http(200, #"{"status": "cancelled", "credits_refunded": 455}"#)), .stopped(.nothingCharged), "stopped while queued: refunded")
    checkEqual(SkyStudioStub.log.filter { $0.url.hasSuffix("/jobs/job-1/cancel") }.count, 1, "Sky Studio is asked to cancel it")
    checkEqual(
        await stopping(cancelReply: .http(409, #"{"error": {"code": "not_cancellable", "message": "Started.", "status": "running"}}"#)),
        .stopped(.alreadyStarted), "stopped after it started: the credits are spent"
    )
    checkEqual(await stopping(cancelReply: .failure(.notConnectedToInternet)), .stopped(.unknown), "the cancel did not get through: unknown")
    SkyStudioStub.reset { seen in seen.method == "POST" ? .http(202, status("queued")) : .http(200, status("cancelled")) }
    checkEqual(await jobFailure({ _ = try await run.run(request) }), .stopped(.nothingCharged), "cancelled on Sky Studio's side")

    // 7. 等太久：说清楚活还在服务器上。等多久：服务器没说按 15 秒，夹在 2–60 秒。
    var impatient = SkyStudioJobRun(api: api, key: jobKey)
    impatient.sleep = SleepLog().sleep
    impatient.maxWait = 0
    SkyStudioStub.reset { seen in seen.method == "POST" ? .http(202, status("queued")) : .http(200, sampleDoneJob) }
    checkEqual(await jobFailure({ _ = try await impatient.run(request) }), .timedOut, "waiting too long")
    checkEqual(SkyStudioJobRun.pollSeconds(nil), 15, "no hint: 15 s")
    checkEqual(SkyStudioJobRun.pollSeconds(0.5), 2, "at least 2 s")
    checkEqual(SkyStudioJobRun.pollSeconds(600), 60, "at most 60 s")

    // 8. 给 AI 的话：停下来的三种说清楚钱和作品库。
    check(SkyStudioJobError.stopped(.alreadyStarted).message.contains("could not be cancelled"), "already started: says it could not be cancelled")
    check(SkyStudioJobError.stopped(.alreadyStarted).message.contains("library"), "already started: says where the result goes")
    check(SkyStudioJobError.stopped(.nothingCharged).message.contains("no credits"), "stopped early: no credits spent")
    check(SkyStudioJobError.timedOut.message.contains("library"), "timed out: the result may still come")
}

/// 跑一件活，抓它抛出来的 SkyStudioJobError（没抛就记一次失败）。
func jobFailure(file: String = #fileID, line: Int = #line, _ body: () async throws -> Void) async -> SkyStudioJobError? {
    checks += 1
    do {
        try await body()
        failures += 1
        print("FAIL [\(file):\(line)] expected a SkyStudioJobError, got none")
    } catch let error as SkyStudioJobError {
        return error
    } catch {
        failures += 1
        print("FAIL [\(file):\(line)] expected a SkyStudioJobError, got \(error)")
    }
    return nil
}

/// 「睡」的替身：记下睡多久、不真睡；`throwOnCall` 次时抛出（就像 Task 在等的时候被取消了）。
final class SleepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Double] = []
    private let throwOnCall: Int?

    init(throwOnCall: Int? = nil) { self.throwOnCall = throwOnCall }

    var all: [Double] { lock.lock(); defer { lock.unlock() }; return items }

    var sleep: @Sendable (Double) async throws -> Void {
        { [self] seconds in
            let count = record(seconds)
            if let throwOnCall, count >= throwOnCall { throw CancellationError() }
        }
    }

    /// 记下一次、回这是第几次（锁只在同步的地方拿）。
    private func record(_ seconds: Double) -> Int {
        lock.lock()
        defer { lock.unlock() }
        items.append(seconds)
        return items.count
    }
}

/// 报上来的每一份（回调可能在别的线程上）。
final class UpdateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [SkyStudioJobRun.Update] = []
    func add(_ update: SkyStudioJobRun.Update) { lock.lock(); list.append(update); lock.unlock() }
    var items: [SkyStudioJobRun.Update] { lock.lock(); defer { lock.unlock() }; return list }
    /// 「状态/阶段」，没有阶段就只有状态。
    var phases: [String] {
        items.compactMap { update in
            guard case .status(let status) = update else { return nil }
            let state = status.state?.rawValue ?? "?"
            return status.phase.map { state == "running" ? "\(state)/\($0)" : state } ?? state
        }
    }
}
