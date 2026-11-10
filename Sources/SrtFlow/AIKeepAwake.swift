import Foundation

// MARK: - AI 在干活时别让 App Nap 把 SkyCut 降速
//
// 管什么（docs/bugfixes/2026-11-10-ai-work-throttled-by-app-nap.md）：SkyCut 不在前台、窗口被别的 App 挡住时（用户在别处干活、AI 用后台模式剪），
// macOS 的 App Nap 把它降到最低的调度优先级（`ps` 里是 4）；机器一忙，本机转写、本机读稿、等 Sky Studio 这些 AI 的活就慢到超时。
// AI 的一次工具调用（从收到到回答，含排队：AIToolRouter.handle）和 AI 起的每个长任务（AIJobs：从 start 到 finish）各领一份 `Lease`；
// 还有没还的就持有**一个** `ProcessInfo.beginActivity`（`.userInitiatedAllowingIdleSystemSleep`：不降速、不合并计时器，但不拦系统空闲睡眠 ——
// 什么时候睡是用户的事），最后一份还掉就 `endActivity`。领和还成对：一份是一个对象，`release()` 只算第一次；忘了还的，最后一个引用放掉时还
// （兜底，别指望它：AIJobs 把任务一直留着，结局不写就一直不还）。
// `beginActivity` / `endActivity` 只在这里和录屏那里（录屏另有一份，还要拦系统睡眠、要低延迟）；谁领、在哪还由 checks/ai-keep-awake.sh 钉着，
// 计数、只开一次只关一次、重复还不多还、兜底还、真的工具调用和任务都还回来在 scripts/check-voice-recovery.sh 的 KeepAwakeChecks 里真跑。
// 不管什么：哪些算 AI 的活（调用方：AIToolRouter.handle、AIJobs.start / finish）。

final class AIKeepAwake: @unchecked Sendable {
    static let shared = AIKeepAwake()
    static let reason = "SkyCut is working for an AI assistant"

    /// 领到的一份。
    final class Lease: @unchecked Sendable {
        private let owner: AIKeepAwake
        private let lock = NSLock()
        private var returned = false

        fileprivate init(owner: AIKeepAwake) { self.owner = owner }

        /// 还（只算第一次，再调什么都不做）。
        func release() {
            lock.lock()
            let first = !returned
            returned = true
            lock.unlock()
            if first { owner.giveBack() }
        }

        deinit { release() }
    }

    private let lock = NSLock()
    private var count = 0
    private var activity: NSObjectProtocol?
    private var periods = 0
    private let begin: () -> NSObjectProtocol
    private let end: (NSObjectProtocol) -> Void

    /// `begin` / `end`：自检换成记数的；生产照 ProcessInfo。
    init(
        begin: @escaping () -> NSObjectProtocol = {
            ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: AIKeepAwake.reason)
        },
        end: @escaping (NSObjectProtocol) -> Void = { ProcessInfo.processInfo.endActivity($0) }
    ) {
        self.begin = begin
        self.end = end
    }

    /// 领一份：第一份开断言。
    func hold() -> Lease {
        lock.lock()
        count += 1
        if count == 1 {
            activity = begin()
            periods += 1
        }
        lock.unlock()
        return Lease(owner: self)
    }

    /// 还一份：最后一份关断言（在锁外关）。
    fileprivate func giveBack() {
        lock.lock()
        count = max(0, count - 1)
        let finished = count == 0 ? activity : nil
        if count == 0 { activity = nil }
        lock.unlock()
        if let finished { end(finished) }
    }

    /// 此刻还有几份没还。
    var holders: Int { lock.withLock { count } }
    /// 此刻是不是持有着断言。
    var isHolding: Bool { lock.withLock { activity != nil } }
    /// 开过几次断言（一直有人在用的一段时间算一次）；自检看一次调用有没有真的开过。
    var heldPeriods: Int { lock.withLock { periods } }
}
