import Foundation

// MARK: - 此刻 SkyCut 的授权：免费 / 体验 / 正式，MCP 开不开、导出加不加水印（纯值）
//
// 管什么：从「上一次 /me 的回答 + 拿到它的那一刻」和「现在」算出此刻作数的授权。
// 规矩（Sky Studio 仓库 docs/agents/skycut-api.md「GET /me」，收费方案第 5 条）：
// - **规则全在服务器**：plan、features、valid_until 照它给的用，SkyCut 不写死天数、不自己算体验还剩没剩；
// - 没有 Key、还没问到过、或者过了 valid_until 还没问到新的 → **按免费版**（MCP 关、导出带水印）。这是「没有授权」本身的定义，
//   不是一条规则；服务器那边免费版的默认开关也是这一组；
// - valid_until 是服务器的钟：换成「拿到回答那一刻的本机时间 + (valid_until − server_time)」，本机的钟和服务器差多少都不影响；
//   本机的钟比拿到回答那一刻还早 5 分钟以上（钟被往回拨了），这份回答也不再作数，要重新问。
// 不管什么：去问（SkyStudioAccount / SkyStudioAPI）、照着拦（收费方案第 5 刀第二步：WatermarkPolicy、MCP 的门）。

struct SkyCutLicense: Equatable, Sendable {
    enum Plan: String, Sendable {
        case free, trial, pro
    }

    /// 这份授权从哪来。
    enum Basis: Equatable, Sendable {
        /// 没有 Key。
        case noKey
        /// 有 Key、还没问到过。
        case notChecked
        /// 服务器的回答，还没过 valid_until。
        case server
        /// 有过回答，但已经过了 valid_until（或本机的钟往回拨了）：按免费版，等问到新的。
        case expired
    }

    /// 服务器说的 plan；认不出的名字是 nil（能用什么只看 `mcp` / `watermark`）。
    var plan: Plan?
    var mcp: Bool
    var watermark: Bool
    var basis: Basis
    /// 体验的起止：本机时间（换算过钟差），拿来和本机的「现在」比。
    var trialStartedAt: Date?
    var trialEndsAt: Date?
    /// 正式版到哪一刻：**照服务器给的，不换算**。它只用来显示是哪天（plan 是服务器说的，回答本来就在 valid_until 作废），
    /// 而换算会把请求在路上的几秒也算进钟差：后台「开通到 12-31」是北京时间那天 23:59:59，挪 5 秒就显示成第二年 1 月 1 日
    ///（2026-10-28 真服务器，docs/bugfixes/2026-10-28-trial-and-pro-dates-shown-a-day-late.md）。
    var paidUntil: Date?
    /// 这份回答作数到哪：本机时间（换算过钟差）。
    var validUntil: Date?
    /// 服务器说为什么没给体验（`machine_used`）。
    var trialUnavailable: String?
    /// 服务器给的购买页，只从还作数的回答读；不会据此改变功能开关。
    var upgradeURL: URL?

    /// 未开通时去哪里购买。正式版可能有功能 override，不能因此叫用户再买一次。
    var proActivationURL: URL? { plan == .pro ? nil : upgradeURL }

    /// 没有授权：免费版的那一组。
    static func free(_ basis: Basis) -> SkyCutLicense {
        SkyCutLicense(plan: .free, mcp: false, watermark: true, basis: basis)
    }

    /// 能和本机的钟差多少：钟往回拨超过这么多，上一次的回答就不作数了。
    static let clockRewindTolerance: TimeInterval = 300

    static func evaluate(_ stored: SkyStudioStoredAnswer?, hasKey: Bool, now: Date) -> SkyCutLicense {
        guard hasKey else { return .free(.noKey) }
        guard let stored else { return .free(.notChecked) }
        let license = stored.me.skycut
        let validUntil = stored.local(license.validUntil)
        guard now >= stored.receivedAt.addingTimeInterval(-clockRewindTolerance), now < validUntil else {
            var expired = SkyCutLicense.free(.expired)
            expired.validUntil = validUntil
            return expired
        }
        return SkyCutLicense(
            plan: Plan(rawValue: license.plan),
            mcp: license.features.mcp,
            watermark: license.features.watermark,
            basis: .server,
            trialStartedAt: license.trialStartedAt.map(stored.local),
            trialEndsAt: license.trialEndsAt.map(stored.local),
            paidUntil: license.paidUntil,
            validUntil: validUntil,
            trialUnavailable: license.trialUnavailable,
            upgradeURL: license.upgradeURL
        )
    }

    /// 体验还剩几天（不满一天算一天；不在体验里是 nil）。到期那一刻服务器的 plan 就变了，所以这里只管显示。
    /// **不超过体验本身的天数**（起止都在同一份回答里）：服务器的 server_time 取在请求一进来那一刻，体验的起点是几秒后写库时的钟，
    /// 换算到本机后刚开始的 7 天体验剩「7 天零几秒」，向上取整就成了 8 天（2026-10-28 真服务器）。后台改过的体验照它自己的长度算，
    /// 不到一分钟的零头不算（10.5 天的体验刚开始是 11 天）。
    func trialDaysLeft(now: Date) -> Int? {
        guard plan == .trial, let trialEndsAt, trialEndsAt > now else { return nil }
        let left = Int((trialEndsAt.timeIntervalSince(now) / 86_400).rounded(.up))
        guard let trialStartedAt, trialEndsAt > trialStartedAt else { return left }
        let length = Int(((trialEndsAt.timeIntervalSince(trialStartedAt) - 60) / 86_400).rounded(.up))
        return min(left, max(1, length))
    }
}

/// 什么时候再问一次 /me（纯规则）。问一次很便宜，但也别每次切回 SkyCut 都问：
/// - 从没问到过、回答过期了（或本机的钟往回拨了）→ 马上问；
/// - 启动 / 回到 SkyCut：此刻不是正式版时隔 1 分钟，正式版照旧隔 30 分钟；后台每小时看一眼时隔 6 小时；
/// - 上一次没问成，至少隔 5 分钟再试（断网时不必每切一次窗口就发一次）。
enum SkyStudioRefresh {
    enum Trigger {
        case activation, background, beforeUse
    }

    static let retryAfterFailure: TimeInterval = 5 * 60

    static func isDue(stored: SkyStudioStoredAnswer?, lastFailure: Date?, now: Date, trigger: Trigger) -> Bool {
        if let lastFailure, now.timeIntervalSince(lastFailure) < retryAfterFailure, now >= lastFailure { return false }
        guard let stored else { return true }
        let license = SkyCutLicense.evaluate(stored, hasKey: true, now: now)
        guard license.basis == .server else { return true }
        let interval: TimeInterval
        switch trigger {
        case .activation: interval = license.plan == .pro ? 30 * 60 : 60
        case .background: interval = 6 * 3600
        case .beforeUse: interval = 0
        }
        return now.timeIntervalSince(stored.receivedAt) >= interval
    }
}
