import Foundation

// MARK: - 同时开着的 Sky Studio 任务：按池领槽（全 App 一份）
//
// 管什么（SkyCut 声音方案 8.2、8.3；Sky Studio 合同 docs/agents/skycut-api.md「Voice → Pools」，服务器的 `skycut_begin_job` 也这样按池数）：
// - **两个池，和服务器一样分**：声音池（`audioKinds`：读稿、克隆读稿、建 MiniMax 版、设计、变声、音效），槽数 = `/me` 的
//   `max_running_audio_jobs`（声音上线后 8）；共用池（其余：图片、视频、upscale、对口型、音乐、角色），槽数 = `max_running_jobs`（3）。
//   服务器还没报 `max_running_audio_jobs`（还没上声音池）：声音任务也进共用池，按它的 3 个排。
// - **交之前领槽，这一单结束就还**：`SkyStudioJobRun.run` 交之前领（一段旁白的各批由 SkyStudioVoiceBatchQueue 按原来的顺序先领好、
//   再交给它），做完、没做成、停了都还。同一个池里先来先得；在等的时候被取消就离队、不占槽。本机在飞的任何时候都不超过槽数。
// - **只管本机交的**：网页、别的电脑上开着的任务 SkyCut 看不见，服务器的 429 `too_many_jobs`（带 `pool`）照旧兜底 ——
//   SkyStudioJobRun 拿着槽等 15 秒、用同一个 idempotency_key 再交。恢复已知原单（只 GET）不领槽，它不是新交的活；
//   停不下来、交给后台接着查到底的那单也不再占着槽（真满了照样由 429 兜底）。
// 不管什么：交 / 等 / 停（SkyStudioJobRun）；槽数从哪来（SkyStudioAccount 每次存下 /me 都 `adopt` 一次）。

final class SkyStudioJobSlots: @unchecked Sendable {
    enum Pool: String, Sendable, CaseIterable {
        /// 声音池（服务器 429 的 `pool: "audio"`）。
        case audio
        /// 共用池（`pool: "default"`）。
        case shared = "default"
    }

    /// 两个池各几个槽。
    struct Limits: Equatable, Sendable {
        /// 服务器没报共用池的槽数时按 3（合同的缺省值）。
        static let defaultShared = 3
        /// 服务器管理后台能设的范围；读到范围外的数夹回来（不让本机一个都交不了，也不放开到离谱）。
        static let range = 1...50
        /// 还没问到过 /me：共用池 3 个，没有声音池。
        static let standard = Limits(shared: nil, audio: nil)

        /// `max_running_jobs`。
        let shared: Int
        /// `max_running_audio_jobs`；nil = 服务器还没有声音池，声音任务进共用池。
        let audio: Int?

        init(shared: Int?, audio: Int?) {
            self.shared = Self.clamped(shared ?? Self.defaultShared)
            self.audio = audio.map(Self.clamped)
        }

        private static func clamped(_ value: Int) -> Int { min(range.upperBound, max(range.lowerBound, value)) }
    }

    /// 本机此刻的样子：每个池几个在飞、几个在等。
    struct Snapshot: Equatable, Sendable {
        var limits: Limits
        var running: [Pool: Int]
        var waiting: [Pool: Int]
    }

    /// 领到的一个槽。`release()` 还（只还一次，再调什么都不做）；忘了还的，最后一个引用放掉时也还（兜底，别指望它）。
    final class Lease: @unchecked Sendable {
        let pool: Pool
        fileprivate let id: UInt64
        private let slots: SkyStudioJobSlots

        fileprivate init(pool: Pool, id: UInt64, slots: SkyStudioJobSlots) {
            self.pool = pool
            self.id = id
            self.slots = slots
        }

        func release() { slots.end(id) }
        deinit { slots.end(id) }
    }

    static let shared = SkyStudioJobSlots()

    /// 进声音池的活，和服务器 `skycut_begin_job` 同一份名单（Sky Studio docs/migrations/2026-11-10_voice_library.sql）。
    static let audioKinds: Set<String> = ["voice", "voice_clone", "voice_enroll", "voice_design", "voice_convert", "sound_effect"]

    /// 这种活进哪个池：声音的那几种在服务器有声音池时进声音池，别的都进共用池。
    static func pool(for kind: String, limits: Limits) -> Pool {
        audioKinds.contains(kind) && limits.audio != nil ? .audio : .shared
    }

    static func capacity(of pool: Pool, limits: Limits) -> Int {
        switch pool {
        case .audio: return limits.audio ?? 0
        case .shared: return limits.shared
        }
    }

    private struct Waiter {
        let id: UInt64
        let kind: String
        let continuation: CheckedContinuation<Lease, Error>
    }

    private typealias Grant = (continuation: CheckedContinuation<Lease, Error>, lease: Lease)

    private let lock = NSLock()
    private var limits: Limits
    private var running: [Pool: Int] = [:]
    /// 领出去还没还的：号 → 池（还的时候按领的那个池还，/me 中途变了也不会还错池）。
    private var active: [UInt64: Pool] = [:]
    /// 排着队的，先来的在前。
    private var waiters: [Waiter] = []
    /// 说了要等、还没进队的（取消可能比进队先到）。
    private var arriving: Set<UInt64> = []
    /// 进队之前就被取消的：进队时直接抛。
    private var abandoned: Set<UInt64> = []
    private var lastID: UInt64 = 0

    init(limits: Limits = .standard) { self.limits = limits }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        var waiting: [Pool: Int] = [:]
        for waiter in waiters { waiting[Self.pool(for: waiter.kind, limits: limits), default: 0] += 1 }
        return Snapshot(limits: limits, running: running, waiting: waiting)
    }

    /// /me 问到了新的槽数（SkyStudioAccount 每次存下回答时调）：照它排，变多了马上放排着的人进来。
    func adopt(_ limits: Limits) {
        lock.lock()
        self.limits = limits
        let granted = grantLocked()
        lock.unlock()
        resume(granted)
    }

    /// 有空就马上领到，没有就是 nil（不排队；同一个池里有人在等也不插队）。
    func tryAcquire(kind: String) -> Lease? {
        lock.lock()
        defer { lock.unlock() }
        return takeLocked(kind: kind)
    }

    /// 领一个槽：有空马上给；没有就排队（同一个池里先来的先给）。要等的时候先 `onWait(在飞几个, 几个槽)` 说一声。
    /// 等的时候被取消：离队、抛 CancellationError，不占槽。
    func acquire(kind: String, onWait: ((_ running: Int, _ limit: Int) -> Void)? = nil) async throws -> Lease {
        try Task.checkCancellation()
        switch arrive(kind: kind) {
        case .granted(let lease):
            return lease
        case .waiting(let id, let running, let limit):
            onWait?(running, limit)
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Lease, Error>) in
                    enqueue(Waiter(id: id, kind: kind, continuation: continuation))
                }
            } onCancel: {
                abandon(id)
            }
        }
    }

    // MARK: 锁里的几步（锁只在同步的函数里拿）

    private enum Arrival {
        case granted(Lease)
        case waiting(id: UInt64, running: Int, limit: Int)
    }

    /// 有空就领走；没有就记下「要等」（取消可能比进队先到），回在飞几个、几个槽。
    private func arrive(kind: String) -> Arrival {
        lock.lock()
        defer { lock.unlock() }
        if let lease = takeLocked(kind: kind) { return .granted(lease) }
        lastID += 1
        arriving.insert(lastID)
        let pool = Self.pool(for: kind, limits: limits)
        return .waiting(id: lastID, running: running[pool] ?? 0, limit: Self.capacity(of: pool, limits: limits))
    }

    private func enqueue(_ waiter: Waiter) {
        lock.lock()
        arriving.remove(waiter.id)
        if abandoned.remove(waiter.id) != nil {
            lock.unlock()
            waiter.continuation.resume(throwing: CancellationError())
            return
        }
        waiters.append(waiter)
        // 说要等到进队之间可能刚好空出一个：照顺序再放一遍。
        let granted = grantLocked()
        lock.unlock()
        resume(granted)
    }

    private func abandon(_ id: UInt64) {
        lock.lock()
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            lock.unlock()
            waiter.continuation.resume(throwing: CancellationError())
            return
        }
        // 还没进队：记下，进队时直接抛。已经领到了的（不在队里也不在路上）什么都不做：领到的人自己还。
        if arriving.contains(id) { abandoned.insert(id) }
        lock.unlock()
    }

    fileprivate func end(_ id: UInt64) {
        lock.lock()
        guard let pool = active.removeValue(forKey: id) else {
            lock.unlock()
            return
        }
        running[pool] = max(0, (running[pool] ?? 0) - 1)
        let granted = grantLocked()
        lock.unlock()
        resume(granted)
    }

    private func takeLocked(kind: String) -> Lease? {
        let pool = Self.pool(for: kind, limits: limits)
        guard (running[pool] ?? 0) < Self.capacity(of: pool, limits: limits),
              !waiters.contains(where: { Self.pool(for: $0.kind, limits: limits) == pool }) else { return nil }
        return openLocked(pool)
    }

    /// 按排队的顺序放人：每个人看自己那个池还有没有空；一个池满了，排在后面的同池的人也进不来（先来先得）。
    private func grantLocked() -> [Grant] {
        var granted: [Grant] = []
        var index = 0
        while index < waiters.count {
            let pool = Self.pool(for: waiters[index].kind, limits: limits)
            if (running[pool] ?? 0) < Self.capacity(of: pool, limits: limits) {
                let waiter = waiters.remove(at: index)
                granted.append((waiter.continuation, openLocked(pool)))
            } else {
                index += 1
            }
        }
        return granted
    }

    private func openLocked(_ pool: Pool) -> Lease {
        lastID += 1
        running[pool, default: 0] += 1
        active[lastID] = pool
        return Lease(pool: pool, id: lastID, slots: self)
    }

    private func resume(_ granted: [Grant]) {
        for grant in granted { grant.continuation.resume(returning: grant.lease) }
    }
}
