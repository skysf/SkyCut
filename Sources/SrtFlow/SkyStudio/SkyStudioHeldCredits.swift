import Foundation
import os

// MARK: - 一单 Sky Studio 的活记在本机积分账上的那一笔
//
// 管什么：每日积分上限按本机的账算（SkyStudioSpendStore）。一单活在起任务之前就记上：
// - AI 起的在 SkyStudioJobGate 里记（把关和记账同一步）；
// - 面板起的在任务开跑时记上报价（面板本身就是确认）。
// 之后只有两种动作：
// - **退回**（只退一次）：没交上（裁、传的时候停了 / 出错）、排队中取消了、Sky Studio 说没做成（它自己退钱）；
// - **按实收换**：做完了，服务器按实际的文件算，比报价低就收低的。
// 交上之后停不下来的（已经开始了、取消没送到）不退：积分花了。upscale（UpscaleJob）和生成（SkyStudioGenerationRun）共用这一份。
// Both go to the day key recorded at booking. A reservation without one (a voice library order saved before day keys) uses only a
// day the ledger proves holds it; otherwise the books stay as they are, counting too much rather than too little, and the log says
// so (Codex CXM3). A settlement is one ledger write (SkyStudioSpendStore.settle).
// 不管什么：账本怎么存、每日上限（SkyStudioSpendStore）；要不要问用户（SkyStudioJobGate）。

@MainActor
struct SkyStudioHeldCredits {
    private static let log = Logger(subsystem: "com.srtflow.SrtFlow", category: "credit-ledger")
    private var held: SkyStudioJobGate.Reservation?
    private let store: SkyStudioSpendStore

    /// AI 起的：起任务之前在 SkyStudioJobGate 里已经记上的那一笔。
    init(_ reservation: SkyStudioJobGate.Reservation, store: SkyStudioSpendStore? = nil) {
        self.store = store ?? SkyStudioSpendStore.shared
        held = reservation
    }

    /// 面板起的：开跑时记上报价。
    /// One moment for the booking and the refund's day, like SkyStudioJobGate (MSG1 review, 2026-11-25).
    static func recording(_ credits: Double, now: Date = Date()) -> SkyStudioHeldCredits {
        let key = SkyStudioSpendStore.shared.record(credits, now: now)
        return SkyStudioHeldCredits(SkyStudioJobGate.Reservation(credits: credits, day: now, dayKey: key))
    }

    /// 没花出去：退回（只退一次）。
    mutating func refund() {
        guard let held else { return }
        if let key = bookedDay(of: held, for: "refund") { store.refund(held.credits, dayKey: key) }
        self.held = nil
    }

    /// 做完：账上记的是报价，换成实收（一般一样）。实收记在预留的那一天：Sky Studio 交的时候就扣了，
    /// 跨了零点（SkyCut 重启之后第二天才接着跟完的声音库收费单）也不挪到今天的额度上。
    /// `now`: the clock the ledger's 40-day clean-up goes by (a check passes its own; Codex CXM4).
    mutating func settle(charged: Double, now: Date = Date()) {
        guard let held, abs(held.credits - charged) > 0.0001, let key = bookedDay(of: held, for: "settlement") else { return }
        store.settle(reserved: held.credits, charged: charged, dayKey: key, now: now)
        self.held = SkyStudioJobGate.Reservation(credits: charged, day: held.day, dayKey: key)
    }

    /// The day key the reservation was booked on; for one saved without it, the only day the ledger proves holds it, else nil.
    private func bookedDay(of held: SkyStudioJobGate.Reservation, for action: String) -> String? {
        if let key = held.dayKey ?? store.ledger.provenDayKey(holding: held.credits, bookedAt: held.day) { return key }
        Self.log.notice("Credit \(action, privacy: .public) of \(held.credits) left on the books: the reservation has no day key and the ledger does not prove its day")
        return nil
    }
}
