import Foundation
import SrtFlowMCPKit

// 按池领槽（SkyStudioJobSlots，SkyCut 声音方案 8.2、9.1 第 4 项）：两个池（8 / 3）、读不到 max_running_audio_jobs 都进共用池、
// 先来先得、等的时候被停就离队、/me 变了照新的排；对着假 Sky Studio 数同时开着的单：本机在飞的不超过槽数、两个池互不挡；
// 429 看 `pool`、拿着槽等、同一个 key 再交；调用方先领好的槽 SkyStudioJobRun 不另领也不还；恢复原单不领槽。
// 还有一段旁白几批各在哪一步（SkyStudioVoiceBatchBoard）：只往前走、合出来的阶段、get_job 的几个数。

/// 服务器 `skycut_begin_job` 的声音池名单（Sky Studio docs/migrations/2026-11-10_voice_library.sql，原样抄来对账）。
private let serverAudioKinds: Set<String> = ["voice", "sound_effect", "voice_clone", "voice_enroll", "voice_design", "voice_convert"]

func runVoiceSlotChecks() async {
    poolChecks()
    await queueChecks()
    await inFlightChecks()
    await jobRunSlotChecks()
    boardChecks()
}

private func poolChecks() {
    typealias Limits = SkyStudioJobSlots.Limits
    let pooled = Limits(shared: 3, audio: 8)
    // SkyCut 自己的活名对上服务器的名单：读稿、克隆读稿、建 MiniMax 版、设计、变声、音效进声音池。
    let voiceKinds = [SkyStudioVoiceKind.narration, SkyStudioVoiceKind.clone, SkyStudioVoiceKind.enroll, SkyStudioVoiceKind.design,
                      SkyStudioVoiceKind.convert, SkyStudioGeneration.Kind.soundEffect.rawValue]
    checkEqual(Set(voiceKinds), serverAudioKinds, "SkyCut's voice and sound-effect kinds are exactly the server's audio pool")
    for kind in voiceKinds {
        checkEqual(SkyStudioJobSlots.pool(for: kind, limits: pooled), .audio, "\(kind) takes an audio slot")
    }
    let others = ["upscale"] + SkyStudioGeneration.Kind.allCases.filter { $0 != .soundEffect }.map(\.rawValue)
    for kind in others {
        checkEqual(SkyStudioJobSlots.pool(for: kind, limits: pooled), .shared, "\(kind) takes a shared slot")
    }
    checkEqual(SkyStudioJobSlots.capacity(of: .audio, limits: pooled), 8, "the audio pool has max_running_audio_jobs slots")
    checkEqual(SkyStudioJobSlots.capacity(of: .shared, limits: pooled), 3, "the shared pool has max_running_jobs slots")
    let older = Limits(shared: 3, audio: nil)
    for kind in voiceKinds + others {
        checkEqual(SkyStudioJobSlots.pool(for: kind, limits: older), .shared, "no audio pool on the server yet: \(kind) shares the 3")
    }
    checkEqual(Limits.standard, Limits(shared: 3, audio: nil), "never asked /me: 3 shared slots, no audio pool")
    checkEqual(Limits(shared: 0, audio: 99), Limits(shared: 1, audio: 50), "counts outside the server's 1–50 are clamped")
    checkEqual(Set(SkyStudioJobSlots.Pool.allCases.map(\.rawValue)), SkyStudioJobAdmission.slotPools, "the pools are the 429 pool names")
    let answer = sampleMe.replacingOccurrences(of: "\"max_running_jobs\": 3,", with: "\"max_running_jobs\": 3, \"max_running_audio_jobs\": 8,")
    let me = try? SkyStudioJSON.decoder().decode(SkyStudioMe.self, from: Data(answer.utf8))
    checkEqual(Limits(shared: me?.skycut.maxRunningJobs, audio: me?.skycut.maxRunningAudioJobs), pooled, "/me's two pools become the slot counts")
    check(SkyStudioJobRun(api: jobAPI(), key: jobKey).slots === SkyStudioJobSlots.shared, "every job takes its slot from the one App-wide pool")
}

/// 先来先得、等的时候被停就离队、还两次只算一次、放掉的槽自动还、/me 变了照新的排。
private func queueChecks() async {
    let slots = SkyStudioJobSlots(limits: .init(shared: 3, audio: 1))
    guard let holder = slots.tryAcquire(kind: "voice") else { return check(false, "an empty audio pool gives a slot at once") }
    check(slots.tryAcquire(kind: "voice_clone") == nil, "a full pool gives no slot without waiting")
    let shared = slots.tryAcquire(kind: "image")
    checkEqual(shared?.pool, .shared, "a full audio pool does not block a shared job")
    shared?.release()
    let order = NameLog()
    func waiter(_ name: String) -> Task<SkyStudioJobSlots.Lease?, Never> {
        Task {
            do {
                let lease = try await slots.acquire(kind: "voice")
                order.add(name)
                return lease
            } catch {
                order.add(name + " left")
                return nil
            }
        }
    }
    let first = waiter("a")
    await waitUntil { slots.snapshot.waiting[.audio] == 1 }
    let second = waiter("b")
    await waitUntil { slots.snapshot.waiting[.audio] == 2 }
    let third = waiter("c")
    await waitUntil { slots.snapshot.waiting[.audio] == 3 }
    second.cancel()
    check(await second.value == nil, "a waiter stopped while waiting leaves without a slot")
    checkEqual(slots.snapshot.waiting[.audio], 2, "and leaves the queue")
    holder.release()
    let a = await settle(first) { order.items.contains("a") }
    checkEqual(order.items, ["b left", "a"], "first come, first served (the one that left is skipped)")
    checkEqual(slots.snapshot.running[.audio], 1, "one audio slot: one in flight")
    a?.release()
    a?.release()
    let c = await settle(third) { order.items.contains("c") }
    checkEqual(order.items.last, "c", "the next in line gets the slot back")
    checkEqual(slots.snapshot.running[.audio], 1, "releasing twice gives back only one slot")
    c?.release()
    _ = slots.tryAcquire(kind: "image")
    checkEqual(slots.snapshot.running[.shared] ?? 0, 0, "a slot nobody holds any more goes back by itself")

    // /me 后来才报声音池：在等的声音任务马上领到声音池的槽；先前领的照原来的池还。
    let growing = SkyStudioJobSlots(limits: .init(shared: 1, audio: nil))
    let early = growing.tryAcquire(kind: "voice")
    checkEqual(early?.pool, .shared, "no audio pool yet: a voice job takes a shared slot")
    let blocked = Task { try? await growing.acquire(kind: "voice_convert") }
    await waitUntil { growing.snapshot.waiting[.shared] == 1 }
    growing.adopt(.init(shared: 1, audio: 8))
    let moved = await settle(blocked) { growing.snapshot.running[.audio] == 1 }
    checkEqual(moved?.pool, .audio, "once /me reports the audio pool, the waiting voice job gets an audio slot")
    early?.release()
    checkEqual(growing.snapshot.running[.shared] ?? 0, 0, "the earlier slot goes back to the pool it came from")
    moved?.release()
}

/// 对着假 Sky Studio 数同时开着的单：12 个声音任务 + 5 个别的同时起，声音池 8、共用池 3。
private func inFlightChecks() async {
    let server = OpenJobs()
    SkyStudioStub.reset { server.reply($0) }
    let slots = SkyStudioJobSlots(limits: .init(shared: 3, audio: 8))
    let kinds = (0..<12).map { $0.isMultiple(of: 3) ? "voice_convert" : "voice" } + Array(repeating: "image", count: 5)
    let finished = await bounded(seconds: 10) { await runTogether(kinds, slots: slots) }
    checkEqual(finished, 17, "every job finishes")
    checkEqual(server.peak["audio"], 8, "never more than 8 voice jobs open at once, and all 8 slots are used")
    checkEqual(server.peak["default"], 3, "never more than 3 other jobs open at once")
    check(server.peakTogether > 8, "the two pools run side by side: a voiceover does not hold up an upscale (peak \(server.peakTogether))")
    checkEqual(slots.snapshot.running.values.reduce(0, +), 0, "every slot is given back")

    // 服务器还没有声音池（/me 没报）：声音任务和别的共用 3 个。
    server.clear()
    let older = SkyStudioJobSlots(limits: .standard)
    let olderFinished = await bounded(seconds: 10) { await runTogether(Array(repeating: "voice", count: 4) + ["image", "image"], slots: older) }
    checkEqual(olderFinished, 6, "on an older server every job still finishes")
    check(server.peakTogether <= 3 && server.peakTogether >= 2, "an older server: voice and other jobs share 3 slots (peak \(server.peakTogether))")
}

private func jobRunSlotChecks() async {
    let request = SkyStudioJobRequest(kind: "voice", model: "auto", prompt: "Hello.", maxCredits: 2.5, idempotencyKey: "idem-voice")
    let queued = #"{"job_id": "job-1", "status": "queued", "poll_after_seconds": 15}"#

    // 1. 服务器说声音池满了（网页上开着的本机看不见）：拿着本机的槽等 15 秒、同一个 key 再交。
    let slots = SkyStudioJobSlots(limits: .init(shared: 3, audio: 8))
    let refusals = Countdown(1)
    SkyStudioStub.reset { seen in
        guard seen.method == "POST" else { return .http(200, sampleDoneJobFor("job-1")) }
        if refusals.take() {
            return .http(429, #"{"error": {"code": "too_many_jobs", "message": "8 audio jobs are open.", "limit": 8, "running": 8, "pool": "audio"}}"#)
        }
        return .http(202, queued)
    }
    let held = NameLog()
    let updates = UpdateLog()
    var run = SkyStudioJobRun(api: jobAPI(), key: jobKey)
    run.slots = slots
    run.sleep = { seconds in held.add("\(seconds):\(slots.snapshot.running[.audio] ?? 0)") }
    checkEqual(try? await run.run(request) { updates.add($0) }.state, .done, "a full audio pool on Sky Studio: waits, then finishes")
    checkEqual(updates.items.first, .waitingForSlot(running: 8, limit: 8), "the 429's counts are reported as waiting for a slot")
    checkEqual(held.items.first, "\(SkyStudioJobRun.slotRetrySeconds):1", "it waits 15 s holding its local slot")
    let keys = SkyStudioStub.log.filter { $0.method == "POST" }.compactMap { $0.body.flatMap { try? JSONValue.decode($0) }?["idempotency_key"]?.stringValue }
    checkEqual(keys, ["idem-voice", "idem-voice"], "the second try carries the same idempotency key")
    checkEqual(slots.snapshot.running[.audio] ?? 0, 0, "the slot goes back when the job ends")
    SkyStudioStub.reset { _ in .http(429, #"{"error": {"code": "too_many_jobs", "message": "Full.", "limit": 8, "running": 8, "pool": "gpu"}}"#) }
    if case .request(.server)? = await jobFailure({ _ = try await run.run(request) }) {
        checkEqual(SkyStudioStub.log.count, 1, "a 429 with an unknown pool is not a slot refusal: no retry")
    } else { check(false, "a 429 with an unknown pool is reported as Sky Studio's refusal") }
    checkEqual(slots.snapshot.running[.audio] ?? 0, 0, "a refused job gives its slot back")

    // 2. 本机的槽满了：在本机等、报一次等空位；等的时候被停 = 什么都没交、一分没花，离队。
    let tight = SkyStudioJobSlots(limits: .init(shared: 3, audio: 1))
    let blocker = tight.tryAcquire(kind: "voice")
    SkyStudioStub.reset { _ in .http(202, queued) }
    for guarded in [false, true] {
        let waits = UpdateLog()
        let task = Task { () -> SkyStudioJobError? in
            var waiting = SkyStudioJobRun(api: jobAPI(), key: jobKey)
            waiting.slots = tight
            if guarded { waiting.beforeSubmit = {} }
            do { _ = try await waiting.run(request) { waits.add($0) }; return nil }
            catch { return error as? SkyStudioJobError }
        }
        await waitUntil { tight.snapshot.waiting[.audio] == 1 }
        checkEqual(waits.items, [.waitingForSlot(running: 1, limit: 1)], "a full local pool is reported like a full server")
        task.cancel()
        let stopped = await task.value
        if guarded {
            if case .notSubmitted? = stopped {} else { check(false, "with a pre-submit check, stopping while waiting is not-submitted (got \(String(describing: stopped)))") }
        } else {
            checkEqual(stopped, .stopped(.nothingCharged), "stopped while waiting for a slot: nothing was sent, nothing charged")
        }
        checkEqual(SkyStudioStub.log.count, 0, "no request reached Sky Studio")
        checkEqual(tight.snapshot.waiting[.audio] ?? 0, 0, "and it left the queue")
    }

    // 3. 调用方按顺序领好的槽（一段旁白的各批）：不另领，也不替它还；恢复原单只 GET、不领槽。
    SkyStudioStub.reset { seen in seen.method == "POST" ? .http(202, queued) : .http(200, sampleDoneJobFor("job-1")) }
    var given = SkyStudioJobRun(api: jobAPI(), key: jobKey)
    given.slots = tight
    given.lease = blocker
    given.sleep = SleepLog().sleep
    let leased = given
    checkEqual(await bounded(seconds: 2) { try? await leased.run(request).state }, .done, "a batch with a slot taken in order runs without taking another")
    checkEqual(tight.snapshot.running[.audio], 1, "the caller's slot stays held until the caller has recorded the batch")
    given.lease = nil
    let resuming = given
    checkEqual(await bounded(seconds: 2) { try? await resuming.resume("job-1").state }, .done,
               "resuming an original job (GET only) needs no slot even when the pool is full")
    blocker?.release()
    checkEqual(tight.snapshot.running[.audio] ?? 0, 0, "the caller gives it back")
}

private func boardChecks() {
    var board = SkyStudioVoiceBatchBoard(count: 4)
    checkEqual([board.total, board.done, board.running, board.waiting], [4, 0, 0, 4], "four batches, all waiting for a slot")
    board.advance(0, to: .queued(position: 2))
    board.advance(1, to: .processing)
    checkEqual(board.phase, .processing, "two batches in flight: the row says processing")
    board.advance(1, to: .queued(position: 1))
    checkEqual(board.states[1], .processing, "a late older update never moves a batch back")
    board.advance(1, to: .done)
    board.advance(1, to: .processing)
    checkEqual(board.states[1], .done, "a finished batch stays finished")
    board.advance(2, to: .stopped)
    checkEqual([board.done, board.running, board.waiting], [1, 1, 1], "1 done, 1 running, 1 waiting for a slot (one stopped)")
    checkEqual(board.json["batches_done"], 1, "get_job: batches_done")
    checkEqual(board.json["batches_running"], 1, "get_job: batches_running")
    checkEqual(board.json["batches_waiting"], 1, "get_job: batches_waiting")
    checkEqual(board.first, 0, "the first batch not yet done")
    board.advance(3, to: .done)
    board.advance(0, to: .queued(position: 1))
    checkEqual(board.phase, .queued(position: 1), "only one batch left: the row shows its own queue position")
    board.advance(0, to: .downloading(fraction: 0.4))
    checkEqual(board.phase, .downloading(fraction: 0.4), "and its download fraction")
    board.advance(0, to: .done)
    checkEqual(board.phase, .finishing, "all batches here: local splitting is next")
    checkEqual(board.first, nil, "nothing left to wait for")
}

// MARK: - 小件

/// 一起跑这几件活（每件一个 SkyStudioJobRun），回做完了几件。
private func runTogether(_ kinds: [String], slots: SkyStudioJobSlots) async -> Int {
    await withTaskGroup(of: Bool.self) { group in
        for kind in kinds {
            group.addTask {
                var run = SkyStudioJobRun(api: jobAPI(), key: jobKey)
                run.slots = slots
                run.sleep = { _ in try await Task.sleep(nanoseconds: 1_000_000) }
                let request = SkyStudioJobRequest(kind: kind, model: "m", prompt: "p", maxCredits: 1)
                return (try? await run.run(request))?.state == .done
            }
        }
        var done = 0
        for await finished in group where finished { done += 1 }
        return done
    }
}

/// 等到条件成立（最多约 2 秒）：等另一个 Task 排进队。
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<2000 where !condition() { try? await Task.sleep(nanoseconds: 1_000_000) }
}

/// 跑一件可能卡在领槽上的活，最多 `seconds` 秒；还没完就叫停（在等槽的会离队、抛出来）：卡住就是一条红，不把整个自检挂住。
private func bounded<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async -> T?) async -> T? {
    let done = NameLog()
    let task = Task { () -> T? in
        let value = await work()
        done.add("done")
        return value
    }
    for _ in 0..<Int(seconds * 1000) where done.items.isEmpty { try? await Task.sleep(nanoseconds: 1_000_000) }
    if done.items.isEmpty { task.cancel() }
    return await task.value
}

/// 等一个在领槽的 Task 领到（`granted` 成立，最多约 2 秒）；一直没领到就叫停它（它会离队、回 nil）：
/// 放行坏了就是一条红，而不是把整个自检挂住。
private func settle(_ task: Task<SkyStudioJobSlots.Lease?, Never>, granted: () -> Bool) async -> SkyStudioJobSlots.Lease? {
    await waitUntil(granted)
    if !granted() { task.cancel() }
    return await task.value
}

/// 只给前几次（回调在 URLProtocol 的线程上）。
private final class Countdown: @unchecked Sendable {
    private let lock = NSLock()
    private var left: Int
    init(_ count: Int) { left = count }
    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard left > 0 else { return false }
        left -= 1
        return true
    }
}

/// 假 Sky Studio 这一头「同时开着几单」：POST 开一单（排队），问第二次做完、关掉；按服务器的名单分池，记下每个池、两个池加起来最多同时开了几单。
private final class OpenJobs: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 0
    private var open: [String: (pool: String, polls: Int)] = [:]
    private(set) var peak: [String: Int] = [:]
    private(set) var peakTogether = 0

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        open = [:]; peak = [:]; peakTogether = 0
    }

    func reply(_ seen: StubSeen) -> SkyStudioStub.Reply {
        lock.lock()
        defer { lock.unlock() }
        if seen.method == "POST" {
            let kind = seen.body.flatMap { try? JSONValue.decode($0) }?["kind"]?.stringValue ?? ""
            next += 1
            let id = "job-\(next)"
            let pool = serverAudioKinds.contains(kind) ? "audio" : "default"
            open[id] = (pool, 0)
            let count = open.values.filter { $0.pool == pool }.count
            peak[pool] = max(peak[pool] ?? 0, count)
            peakTogether = max(peakTogether, open.count)
            return .http(202, #"{"job_id": "\#(id)", "status": "queued", "poll_after_seconds": 2}"#)
        }
        let id = String(seen.url.split(separator: "/").last ?? "")
        guard var job = open[id] else { return .http(200, sampleDoneJobFor(id)) }
        job.polls += 1
        if job.polls >= 2 {
            open[id] = nil
            return .http(200, sampleDoneJobFor(id))
        }
        open[id] = job
        return .http(200, #"{"job_id": "\#(id)", "status": "running", "phase": "processing", "poll_after_seconds": 2}"#)
    }
}
