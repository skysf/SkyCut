import Foundation

// MARK: - 交给 Sky Studio 的活花多少积分：每日上限和按天的账
//
// 管什么：收费方案第 6 刀 —— 钱从美元换成积分，**每日上限默认 1,000 积分**（Sky Studio 一个积分标价 1 美分，等于原来 fal 那一档默认的 10 美元），
// 用户在设置里能改；日预算为硬上限，AI / 面板起的活均不得通过确认码绕过（SkyStudioJobGate）。
// 账按本地时区的自然日记（同一份 DailySpendLedger / DailySpendPolicy：规矩只有一处，第 7 刀删 fal 时改名留下）：交活之前按 /quote 报的数记上，
// 做完按实收（credits_charged）改，没花出去的（没交上、排队中取消了、服务器说没做成）退回。
// 不管什么：报价（/quote）、问用户（SkyStudioJobGate、面板）、界面（设置里「Sky Studio」一节）。
//
// 身份类的键名照旧用 SrtFlow 前缀（docs/architecture/product-name.md）。

@MainActor
final class SkyStudioSpendStore: ObservableObject {
    static let shared = SkyStudioSpendStore()

    static let limitKey = "SrtFlow.skystudio.dailyCreditLimit"
    static let ledgerKey = "SrtFlow.skystudio.creditLedger.v1"
    static let defaultLimit: Double = 1_000
    /// 设得下的范围（0 = 暂停收费任务）。Not actor-bound: a refusal's suggested limit reads it as a pure value (SkyCutDailyLimit).
    nonisolated static let limitRange: ClosedRange<Double> = 0...1_000_000

    @Published private(set) var dailyLimit: Double
    @Published private(set) var ledger: DailySpendLedger
    /// How many times the daily limit changed in this run. A set_settings token is bound to it, so any change since its question
    /// voids the token, also a change back to the same value (Codex CXM3: a 1,000 → 1,500 token wrote 1,500 after the user went to
    /// 2,000 and back to 1,000). Tokens live only in memory, so the count does too.
    private(set) var limitRevision = 0

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.object(forKey: Self.limitKey) as? Double
        dailyLimit = stored.map(Self.clamped) ?? Self.defaultLimit
        ledger = defaults.data(forKey: Self.ledgerKey).flatMap { try? JSONDecoder().decode(DailySpendLedger.self, from: $0) } ?? DailySpendLedger()
    }

    static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return defaultLimit }
        return min(limitRange.upperBound, max(limitRange.lowerBound, value.rounded()))
    }

    func setDailyLimit(_ value: Double) {
        let next = Self.clamped(value)
        guard next != dailyLimit else { return }
        dailyLimit = next
        limitRevision += 1
        defaults.set(next, forKey: Self.limitKey)
    }

    func spentToday(now: Date = Date()) -> Double { ledger.spent(on: now) }

    /// 判断本笔是否在预算内；超了是 .overLimit，由收费闸转成 blocked（daily_budget_exceeded），不索要越额批准。
    func decide(credits: Double, now: Date = Date()) -> DailySpendPolicy.Decision {
        DailySpendPolicy.decide(estimate: credits, spentToday: spentToday(now: now), dailyLimit: dailyLimit)
    }

    /// 记上一笔（交活之前按报价记）。Returns the ledger's day key it was booked on, which a refund reuses.
    @discardableResult
    func record(_ credits: Double, now: Date = Date()) -> String {
        let key = DailySpendLedger.dayKey(for: now)
        record(credits, dayKey: key, now: now)
        return key
    }

    /// Books on a day key worked out at booking (a settlement of a reservation).
    func record(_ credits: Double, dayKey: String, now: Date = Date()) {
        var next = ledger
        next.add(credits, dayKey: dayKey)
        next.prune(now: now)
        save(next)
    }

    /// 退回一笔（按记上的那一天）。
    func refund(_ credits: Double, on day: Date) {
        refund(credits, dayKey: DailySpendLedger.dayKey(for: day))
    }

    /// Refunds on the day key recorded at booking, whatever the time zone is now.
    func refund(_ credits: Double, dayKey: String) {
        var next = ledger
        next.refund(credits, dayKey: dayKey)
        save(next)
    }

    /// Swaps a reservation for the actual charge on the day it was booked, in one ledger write. Written as a refund and then a
    /// booking, a kill between the two lost the charge (60 held, 20 spent, 40 charged: 20 left on the books and 70 more allowed
    /// under 100; Codex CXM3).
    func settle(reserved: Double, charged: Double, dayKey: String, now: Date = Date()) {
        var next = ledger
        next.refund(reserved, dayKey: dayKey)
        next.add(charged, dayKey: dayKey)
        next.prune(now: now)
        save(next)
    }

    private func save(_ next: DailySpendLedger) {
        guard next != ledger else { return }
        ledger = next
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: Self.ledgerKey) }
    }
}

/// 积分怎么写给人 / AI 看：整数不带小数，不是整数留一位（服务器按 0.1 积分取整）。
enum SkyStudioCredits {
    static func text(_ credits: Double) -> String {
        credits == credits.rounded() ? String(Int(credits)) : String(format: "%.1f", credits)
    }

    /// 给 AI 的 JSON 里那个数（留一位小数）。
    static func number(_ credits: Double) -> Double { (credits * 10).rounded() / 10 }
}
