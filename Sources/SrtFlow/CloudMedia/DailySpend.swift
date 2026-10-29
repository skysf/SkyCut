import Foundation

// MARK: - 每日额度与按天记账（纯值）
// 管什么：本机自然日的花费、预留、退款与额度判断；金额单位由调用方决定，当前 Sky Studio 用积分。
// 不管什么：报价、确认码、账的持久化（SkyStudioSpendStore），或 HTTP。

enum DailySpendPolicy {
    enum Reason: Equatable {
        /// 这个模型没登记单价：估不出来，每次都先问。
        case unknownPrice
        /// 这一次做完今天就超过上限了。
        case overLimit(spent: Double, estimate: Double, limit: Double)
    }

    enum Decision: Equatable {
        case allow
        case ask(Reason)
    }

    /// 一单位的千分之一以内的误差不算（浮点加出来的 9.999999999 不该多问一次）。
    private static let slack = 0.0005

    static func decide(estimate: Double?, spentToday: Double, dailyLimit: Double) -> Decision {
        guard let estimate else { return .ask(.unknownPrice) }
        if spentToday + estimate <= dailyLimit + slack { return .allow }
        return .ask(.overLimit(spent: spentToday, estimate: estimate, limit: dailyLimit))
    }

    /// 配旁白不会停下来索要花钱确认：额度不够时直接退到下一档声音（本机的 / macOS 的）。
    static func allowsWithoutAsking(estimate: Double?, spentToday: Double, dailyLimit: Double) -> Bool {
        decide(estimate: estimate, spentToday: spentToday, dailyLimit: dailyLimit) == .allow
    }
}

/// 按天记的花费（本地时区的自然日）。只记数字，不记内容。
struct DailySpendLedger: Codable, Equatable, Sendable {
    /// `yyyy-MM-dd` → 这一天记录了多少金额。
    private(set) var days: [String: Double] = [:]

    init(days: [String: Double] = [:]) { self.days = days }

    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    func spent(on date: Date, calendar: Calendar = .current) -> Double {
        days[Self.dayKey(for: date, calendar: calendar)] ?? 0
    }

    mutating func add(_ amount: Double, on date: Date, calendar: Calendar = .current) {
        guard amount > 0 else { return }
        days[Self.dayKey(for: date, calendar: calendar), default: 0] += amount
    }

    /// 退回一笔（生成失败 / 取消了、服务器没收钱）：不会退到负数。
    mutating func refund(_ amount: Double, on date: Date, calendar: Calendar = .current) {
        guard amount > 0 else { return }
        let key = Self.dayKey(for: date, calendar: calendar)
        guard let current = days[key] else { return }
        let left = max(0, current - amount)
        if left == 0 { days[key] = nil } else { days[key] = left }
    }

    /// 只留最近的几天：账本不该越攒越长。
    mutating func prune(keepingDays: Int = 40, now: Date, calendar: Calendar = .current) {
        guard let cutoff = calendar.date(byAdding: .day, value: -keepingDays, to: now) else { return }
        let oldest = Self.dayKey(for: cutoff, calendar: calendar)
        days = days.filter { $0.key >= oldest }
    }
}
