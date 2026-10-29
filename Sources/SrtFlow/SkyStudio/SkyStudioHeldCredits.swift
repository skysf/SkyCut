import Foundation

// MARK: - 一单 Sky Studio 的活记在本机积分账上的那一笔
//
// 管什么：每日积分上限按本机的账算（SkyStudioSpendStore）。一单活在起任务之前就记上：
// - AI 起的在 SkyStudioJobGate 里记（把关和记账同一步）；
// - 面板起的在任务开跑时记上报价（面板本身就是确认）。
// 之后只有两种动作：
// - **退回**（只退一次）：没交上（裁、传的时候停了 / 出错）、排队中取消了、Sky Studio 说没做成（它自己退钱）；
// - **按实收换**：做完了，服务器按实际的文件算，比报价低就收低的。
// 交上之后停不下来的（已经开始了、取消没送到）不退：积分花了。upscale（UpscaleJob）和生成（SkyStudioGenerationRun）共用这一份。
// 不管什么：账本怎么存、每日上限（SkyStudioSpendStore）；要不要问用户（SkyStudioJobGate）。

@MainActor
struct SkyStudioHeldCredits {
    private var held: SkyStudioJobGate.Reservation?
    private let store: SkyStudioSpendStore

    /// AI 起的：起任务之前在 SkyStudioJobGate 里已经记上的那一笔。
    init(_ reservation: SkyStudioJobGate.Reservation, store: SkyStudioSpendStore? = nil) {
        self.store = store ?? SkyStudioSpendStore.shared
        held = reservation
    }

    /// 面板起的：开跑时记上报价。
    static func recording(_ credits: Double) -> SkyStudioHeldCredits {
        SkyStudioSpendStore.shared.record(credits)
        return SkyStudioHeldCredits(SkyStudioJobGate.Reservation(credits: credits, day: Date()))
    }

    /// 没花出去：退回（只退一次）。
    mutating func refund() {
        guard let held else { return }
        store.refund(held.credits, on: held.day)
        self.held = nil
    }

    /// 做完：账上记的是报价，换成实收（一般一样）。
    mutating func settle(charged: Double) {
        guard let held, abs(held.credits - charged) > 0.0001 else { return }
        store.refund(held.credits, on: held.day)
        store.record(charged)
        self.held = SkyStudioJobGate.Reservation(credits: charged, day: Date())
    }
}
