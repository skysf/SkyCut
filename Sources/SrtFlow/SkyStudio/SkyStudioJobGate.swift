import Foundation

// MARK: - AI 起的 Sky Studio 活：花积分之前过的那一关
//
// 管什么：起任务之前、在工具调用里：额度内直接记账；这一次会让今天超过每日积分上限，**当场回 needs_confirmation + 确认码**
// （`AIConfirmations`，删文件那一套，和 fal 那一关同一个做法：AI 多开方案板 9），AI 在聊天里问用户、用户点头后带着令牌再调一次才记账、起任务。
// 令牌绑着完整请求（SkyStudioApproval：种类、模型、文字、全部参数、输入身份、精确报价和落点），换一样不认；给人看的 summary 只管显示。
// 决定和记账在同一步里做完（中间没有 await），同时起的几个不会各自以为还在额度内。
// 价格一律是 /quote 报的（不会有「不知道多少钱」）。upscale_clip（AIUpscaleTool）走这里；生成、配旁白改走 Sky Studio 时也走这里。
// 不管什么：报价（/quote）、退款（各任务自己：没花出去的退回）、面板起的（面板本身就是确认，不经这里）。

@MainActor
enum SkyStudioJobGate {
    /// 记上账的那一笔（退款时按这一天退）。
    struct Reservation: Equatable {
        let credits: Double
        let day: Date
    }

    enum Decision {
        /// 记上账了：可以起任务。
        case reserved(Reservation)
        /// 要用户点头：把这个结果原样回给 AI（needs_confirmation + confirm_token），什么都没起、没记账。
        case needsConfirmation(AIToolResult)
    }

    /// 起任务之前调一次。`summary`：「Topaz Starlight · 4K · 7.0 s」这种不带语言的几个记号（也是令牌绑着的那件事的一部分）。
    static func decide(credits: Double, summary: String, identity: String, args: AIToolArguments, store: SkyStudioSpendStore? = nil) throws -> Decision {
        let store = store ?? SkyStudioSpendStore.shared
        switch store.decide(credits: credits) {
        case .allow:
            return .reserved(record(store, credits))
        case .ask(let reason):
            let action = identity
            let redemption = AIConfirmations.shared.redeem(try args.string("confirm_token"), for: action)
            if redemption == .accepted { return .reserved(record(store, credits)) }
            return .needsConfirmation(AIConfirmations.shared.ask(question(reason, summary), action: action, refused: redemption.refusal))
        }
    }

    /// 配旁白不能停下来问：整体额度内一次预留，额度不够由调用方退本机（克隆报错）。
    static func reserveWithoutAsking(credits: Double, store: SkyStudioSpendStore? = nil) -> Reservation? {
        let store = store ?? SkyStudioSpendStore.shared
        guard case .allow = store.decide(credits: credits) else { return nil }
        return record(store, credits)
    }

    private static func record(_ store: SkyStudioSpendStore, _ credits: Double) -> Reservation {
        store.record(credits)
        return Reservation(credits: credits, day: Date())
    }

    /// 要用户点头的那一句（英文，给 AI 转述）。
    static func question(_ reason: DailySpendPolicy.Reason, _ summary: String) -> String {
        switch reason {
        case .unknownPrice:
            return "Sky Studio · \(summary) — SkyCut does not know the price. Spend it?"
        case .overLimit(let spent, let credits, let limit):
            return "Sky Studio · \(summary) — \(SkyStudioCredits.text(credits)) credits; today's spending would reach "
                + "\(SkyStudioCredits.text(spent + credits)), over the user's \(SkyStudioCredits.text(limit))-credit daily limit. Spend it?"
        }
    }
}
