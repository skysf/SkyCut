import Foundation

// MARK: - 一次多批配音的积分预留
// 管什么：整体判断并预留一次；每批做完按实收结算，未开跑的退回，提交结果未知的保留账并单独报告。
// 不管什么：报价、HTTP、确认码。配音超每日上限仍退到本机，不停下来索要确认码。

@MainActor
struct SkyStudioVoiceBudget {
    private var held: [SkyStudioHeldCredits?]
    private let quotes: [SkyStudioQuote]
    private(set) var charged: Double = 0
    private(set) var uncertain: Double = 0

    static func reserve(_ quotes: [SkyStudioQuote], store: SkyStudioSpendStore? = nil) -> SkyStudioVoiceBudget? {
        let store = store ?? SkyStudioSpendStore.shared
        let total = quotes.reduce(0) { $0 + $1.credits }
        guard !quotes.isEmpty, quotes.allSatisfy({ $0.credits.isFinite && $0.credits >= 0 }),
              let reservation = SkyStudioJobGate.reserveWithoutAsking(credits: total, store: store) else { return nil }
        return SkyStudioVoiceBudget(held: quotes.map {
            SkyStudioHeldCredits(.init(credits: $0.credits, day: reservation.day), store: store)
        }, quotes: quotes)
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
        uncertain += quotes[index].credits
        held[index] = nil
    }

    mutating func refundUnused() {
        for index in held.indices { refund(index) }
    }
}
