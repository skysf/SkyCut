import Foundation

// MARK: - Pro 的到期 / 续费失败提醒（纯值）
//
// 管什么：有效 /me 回答里的非自动续费七天提醒、扣款失败宽限和各自的续约入口，设置 / 导出 / AI 共用。
// 不管什么：功能授权（只听 SkyCutLicense 的 plan / features / valid_until）、网址校验、去问服务器或界面语言。

struct SkyCutProNotice: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case expiring(days: Int)
        /// 只显示日历日期：保留服务器时刻，和 SkyCutLicense.paidUntil 一样不挪钟差。
        case paymentGrace(until: Date)
    }

    var kind: Kind
    /// 商务续约始终给邮箱；其余只用服务器的可用地址，没有就给邮箱。
    var actionURL: URL?

    /// 只由 SkyCutLicense.evaluate 在确认 Key / valid_until / 钟回拨有效之后调用。
    static func evaluate(_ stored: SkyStudioStoredAnswer, now: Date) -> SkyCutProNotice? {
        let license = stored.me.skycut
        guard license.plan == "pro", license.planReason != "machine_limit_reached" else { return nil }
        // 宽限优先：paid_until 可能已经过去，不能据此撤销服务器仍然给的 Pro，也不能叫用户再买一份订阅。
        if let until = license.graceUntil {
            return SkyCutProNotice(kind: .paymentGrace(until: until), actionURL: license.upgradeURL)
        }
        guard license.autoRenews == false, let until = license.paidUntil else { return nil }
        // 和本机「现在」比才换算钟差；七天整包含在内，相等即到期，不满一天算一天。
        let remaining = stored.local(until).timeIntervalSince(now)
        guard remaining > 0, remaining <= 7 * 86_400 else { return nil }
        let days = Int((remaining / 86_400).rounded(.up))
        return SkyCutProNotice(kind: .expiring(days: days),
                               actionURL: license.proSource == "manual" ? nil : license.upgradeURL)
    }
}
