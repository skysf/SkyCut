import Foundation

// MARK: - AI 起的 fal 任务共用的两样：花钱的把关、钥匙串授权框的提醒
//
// 管什么：（1）**先问后花**（方案第 18 条；2026-10-17 起照 AI 多开方案板 9 改成确认码）：起任务之前、在工具调用里过这一关 ——
// 额度内直接记账；这一次会让今天超过每日上限、或者模型没登记单价，**当场回 needs_confirmation + 确认码**（`AIConfirmations`，删文件那一套），
// AI 在聊天里问用户、用户点头后带着令牌再调一次才记账、起任务。令牌绑着这一次的估价和那几个记号（模型、时长、清晰度…），换一样不认。
// 以前是任务跑起来之后在**顶上的提示条**上问：后台工程没有窗口、用户没在看 SrtFlow，提示条上的问题没人看见（docs/plans/2026-10-17-multi-project-ai-editing.md J 节）。
// 决定和记账在同一步里做完（中间没有 await），同时起的几个任务不会各自以为还在额度内。
// （2）钥匙串的授权框只能由用户点：给 AI 的那句话、提示条上的那一句。
// generate_media（FalGenerateTool）和 upscale_clip（AIUpscaleTool）都走这里 —— 规则只有一处（checks/fal-wiring.sh 第 4、5 条钉着）。
// 不管什么：退款（各任务自己：没做出来才退）、面板起的 upscale（面板本身就是确认，不经这里）。

@MainActor
enum FalJobGate {
    /// 记上账的那一笔（退款时按这一天退）。
    struct Reservation: Equatable {
        let amount: Double
        let day: Date
    }

    enum Decision {
        /// 记上账了：可以起任务。
        case reserved(Reservation)
        /// 要用户点头：把这个结果原样回给 AI（needs_confirmation + confirm_token），什么都没起、没记账。
        case needsConfirmation(AIToolResult)
    }

    /// 起任务之前调一次。`summary`：「MiniMax H3 Max · 5 s · 768P」这种不带语言的几个记号（也是令牌绑着的那件事的一部分）。
    static func decide(estimate: Double?, summary: String, args: AIToolArguments) throws -> Decision {
        let store = FalSettingsStore.shared
        switch store.decide(estimate: estimate) {
        case .allow:
            return .reserved(record(store, estimate))
        case .ask(let reason):
            let action = "fal:" + summary + "|" + (estimate.map { String(format: "%.4f", $0) } ?? "price unknown")
            let redemption = AIConfirmations.shared.redeem(try args.string("confirm_token"), for: action)
            if redemption == .accepted { return .reserved(record(store, estimate)) }
            return .needsConfirmation(AIConfirmations.shared.ask(question(reason, summary), action: action, refused: redemption.refusal))
        }
    }

    private static func record(_ store: FalSettingsStore, _ estimate: Double?) -> Reservation {
        let amount = estimate ?? 0
        store.recordSpend(amount)
        return Reservation(amount: amount, day: Date())
    }

    /// 要用户点头的那一句（英文，给 AI 转述）。
    static func question(_ reason: FalSpendPolicy.Reason, _ summary: String) -> String {
        switch reason {
        case .unknownPrice:
            return "fal.ai · \(summary) — SrtFlow does not know this model's price, so it asks each time. Spend it?"
        case .overLimit(let spent, let estimate, let limit):
            return "fal.ai · \(summary) — estimated cost \(FalMoney.text(estimate)); today's spending would reach "
                + "\(FalMoney.text(spent + estimate)), over the user's \(FalMoney.text(limit)) daily limit. Spend it?"
        }
    }

    // MARK: 钥匙串的授权框

    /// AI 看 get_job 只见 running：得让它知道是 macOS 的授权框在等用户（不然它会对着一个「没动静」的任务干等）。
    static let keyPromptWaiting = "macOS is asking the user, in a system dialog, whether SrtFlow may use the fal.ai key. Tell the user to click "
        + "Always Allow (a Mac login password may be needed; a new version of SrtFlow is asked once), then keep waiting with get_job."

    /// 提示条上说一句、把剪辑页摆出来（提示条在剪辑页里）、把 SrtFlow 摆到前面（授权框跟着 App）。
    static func showKeyPromptHint() {
        AISession.shared.setHint(L10n("macOS is about to ask whether SrtFlow may use your fal.ai key. Click Always Allow."))
        if MainWindowState.shared.section != .videoEdit { MainWindowState.shared.section = .videoEdit }
        AITranslationReadiness.bringSrtFlowForward()
    }

    static func clearKeyPromptHint() {
        AISession.shared.setHint(nil)
    }
}
