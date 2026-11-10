import Foundation

// MARK: - 一次多批配音的积分预留
// 管什么：整体判断并预留一次（每批报价的 credits 是这一批最多花多少）；每批做完按实收结算，未开跑的退回，提交结果未知的保留账并单独报告。
// 新的一段在回任务号之前就预留（SkyStudioVoiceoverStart：额度不够当场回 daily_budget_exceeded，什么都不起）；恢复时补没生成的批次在任务里预留。
// 不管什么：报价、HTTP、确认码。配音超每日硬预算暂停并提示设置，不另换音色、不索要越额确认码。

@MainActor
struct SkyStudioVoiceBudget {
    private var held: [SkyStudioHeldCredits?]
    private let credits: [Double]
    private(set) var charged: Double = 0
    private(set) var uncertain: Double = 0

    static func reserve(_ credits: [Double], store: SkyStudioSpendStore? = nil) -> SkyStudioVoiceBudget? {
        let store = store ?? SkyStudioSpendStore.shared
        let total = credits.reduce(0, +)
        guard !credits.isEmpty, credits.allSatisfy({ $0.isFinite && $0 >= 0 }),
              let reservation = SkyStudioJobGate.reserveWithoutAsking(credits: total, store: store) else { return nil }
        return SkyStudioVoiceBudget(held: credits.map {
            SkyStudioHeldCredits(.init(credits: $0, day: reservation.day), store: store)
        }, credits: credits)
    }

    mutating func settled(_ index: Int, charged: Double) {
        held[index]?.settle(charged: charged)
        held[index] = nil
        self.charged += charged
    }

    mutating func refund(_ index: Int) {
        held[index]?.refund()
        held[index] = nil
    }

    mutating func unknown(_ index: Int) {
        guard held[index] != nil else { return }
        uncertain += credits[index]
        held[index] = nil
    }

    mutating func refundUnused() {
        for index in held.indices { refund(index) }
    }
}
