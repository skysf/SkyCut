import Foundation

// MARK: - AI 起的 Sky Studio 活：花积分之前过的那一关
//
// 管什么：先守每日硬预算；预算内按 AI 权限决定草稿越档是否需要确认，获准后才预留。
// 令牌绑着完整请求（SkyStudioApproval：种类、模型、文字、全部参数、输入身份、精确报价和落点），换一样不认；给人看的 summary 只管显示。
// 决定和记账在同一步里做完（中间没有 await），同时起的几个不会各自以为还在额度内。
// 价格一律是 /quote 报的（不会有「不知道多少钱」）。upscale_clip（AIUpscaleTool）走这里；生成、配旁白改走 Sky Studio 时也走这里；
// 声音库的授权、一次性费用、删声音（声音 PR 6）也在这里，不另开确认入口。
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

    /// 硬预算先判断；请求批准模式只对偏离草稿的操作发码。全部权限只跳过操作审批。
    /// user_requested_overrides 只在 user_request（用户点名规格的原话）里找得到每一项越档的名字时才免问（AIOverrideQuote）；
    /// 找不到就照常发确认码、结果里说明为什么没免（2026-11-10：Codex 把「画质尽量好」当成点名，自己跳过了确认）。
    /// overrides 是每一项越档和它的名字；不给就按 reason 算一项、没有能点名的写法（带了原话就算）。
    static func decide(credits: Double, summary: String, identity: String, args: AIToolArguments,
                       store: SkyStudioSpendStore? = nil, access: AIAccessStore? = nil,
                       reason: String? = nil, overrides: [AIOverrideQuote.Item]? = nil, project: String? = nil, profile: String = "") throws -> Decision {
        let store = store ?? SkyStudioSpendStore.shared
        let access = access ?? AIAccessStore.shared
        let scope = try args.choice("approval_scope", from: ["once", "project"]) ?? "once"
        let userRequested = try args.bool("user_requested_overrides") ?? false
        let userWords = try args.string("user_request")
        guard credits.isFinite, credits >= 0 else { throw AIToolError("Sky Studio returned an invalid price; nothing was started.") }
        guard case .allow = store.decide(credits: credits) else {
            return .needsConfirmation(budgetBlocked(credits: credits, store: store))
        }
        let priceChange = access.approvedPrice(project: project, profile: profile).flatMap { ceiling -> String? in
            credits > ceiling ? "The quote exceeds this project's approved per-task price of \(SkyStudioCredits.text(ceiling)) credits." : nil
        }
        let approvalReason = reason ?? priceChange
        let items = (overrides ?? reason.map { [AIOverrideQuote.Item(reason: $0, names: [])] } ?? [])
            + (priceChange.map { [AIOverrideQuote.Item(reason: $0, names: [])] } ?? [])
        let unnamed = userRequested ? AIOverrideQuote.unnamed(items, in: userWords) : items
        let userNamedIt = userRequested && unnamed.isEmpty
        if let reason = approvalReason, access.mode == .ask, !userNamedIt, !access.allows(project: project, profile: profile, credits: credits) {
            let action = identity + ":approval_scope:" + scope
            let redemption = AIConfirmations.shared.redeem(try args.string("confirm_token"), for: action)
            guard redemption == .accepted else {
                var result = AIConfirmations.shared.ask(
                    "Sky Studio · \(summary) — \(SkyStudioCredits.text(credits)) credits. \(reason) Approve \(scope == "project" ? "this model/specification for this project up to this price per task" : "this task")?",
                    action: action, refused: redemption.refusal)
                if case .object(var value) = result.payload {
                    value["approval_scope"] = .string(scope)
                    value["next_step"] = "Ask in the conversation language before proceeding; offer once or project approval. Keep the scope unchanged when redeeming its token. Never treat the assistant's own plan as user approval."
                    if userRequested {
                        // 说清楚为什么 user_requested_overrides 没免掉这一问：叫它去问用户，别编一段原话再试。
                        value["overrides_not_applied"] = .string((userWords ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "user_requested_overrides needs user_request: the user's own words that name the setting (for example \"4K\" or \"use GPT Image 2\")."
                            : "user_request does not name: " + unnamed.map(\.reason).joined(separator: " ") + " Words like \"best quality\" are not a named setting.")
                    }
                    result.payload = .object(value)
                }
                return .needsConfirmation(result)
            }
            if scope == "project", let project { access.approve(project: project, profile: profile, credits: credits) }
        } else if userNamedIt, scope == "project", let project {
            access.approve(project: project, profile: profile, credits: credits)
        }
        return .reserved(record(store, credits))
    }

    static func budgetBlocked(credits: Double, store: SkyStudioSpendStore) -> AIToolResult {
        .ok(["status": "blocked", "code": "daily_budget_exceeded", "credits_needed": .number(credits),
             "spent_today_credits": .number(store.spentToday()), "daily_limit_credits": .number(store.dailyLimit),
             "settings_section": "sky_studio", "settings_field": "daily_ai_credit_limit",
             "next_step": "Nothing started or charged. Notify the user in their conversation language that the daily hard budget is exhausted. They can raise it in SkyCut Settings > Sky Studio, or explicitly ask you to help change it with set_settings. Do not ask for a one-off budget bypass or silently raise it. Full access obeys the same cap."])
    }

    /// 配旁白不能停下来问：整体额度内一次预留，额度不够由调用方退本机（克隆报错）。
    static func reserveWithoutAsking(credits: Double, store: SkyStudioSpendStore? = nil) -> Reservation? {
        let store = store ?? SkyStudioSpendStore.shared
        guard case .allow = store.decide(credits: credits) else { return nil }
        return record(store, credits)
    }

    /// 原单已明确退回、用户已授权替换：既不能高于原报价，也不能突破当前每日硬预算。
    static func reserveReplacement(credits: Double, approvedCeiling: Double, store: SkyStudioSpendStore? = nil) -> Reservation? {
        let store = store ?? SkyStudioSpendStore.shared
        guard credits.isFinite, credits >= 0, approvedCeiling.isFinite, credits <= approvedCeiling,
              case .allow = store.decide(credits: credits) else { return nil }
        return record(store, credits)
    }

    // MARK: 声音库的三件事（SkyCut 声音方案 4.5；令牌绑什么、问句怎么写在 SkyStudioVoiceApproval）
    //
    // 用录音建声音的授权和一次性费用（建 MiniMax 版、设计）这一刀**两种模式都问**：全部权限下不问，要靠打开全部权限时那一次说明（价目 +
    // 授权那句）和记下的长期授权（声音 PR 7）；在那之前照方案 4.5 末条「没有有效的长期授权，就照请求批准模式问」。
    // 删声音不花钱、不要授权：请求批准模式问一句，全部权限直接删。每日硬预算两种模式都拦（一次性费用先判预算再问）。

    /// 用录音建声音 / 加一种语言的录音：点过头（令牌收下）回 nil，调用方带 `consent: true` 发；否则回问句。
    static func voiceConsent(action: String, question: String, token: String?) -> AIToolResult? {
        let redemption = AIConfirmations.shared.redeem(token, for: action)
        if redemption == .accepted { return nil }
        return voiceQuestion(AIConfirmations.shared.ask(question, action: action, refused: redemption.refusal),
            next: "Show the statement to the user in their language. Only if they confirm it is true for this recording, repeat the "
                + "same call with confirm_token. Never confirm on the user's behalf.")
    }

    /// 一次性费用：每日硬预算先判（超了回 daily_budget_exceeded、不发码），点过头才记上账。
    static func voiceOneTime(credits: Double, action: String, question: String, token: String?,
                             store: SkyStudioSpendStore? = nil) throws -> Decision {
        let store = store ?? SkyStudioSpendStore.shared
        guard credits.isFinite, credits >= 0 else { throw AIToolError("Sky Studio returned an invalid price; nothing was started.") }
        guard case .allow = store.decide(credits: credits) else { return .needsConfirmation(budgetBlocked(credits: credits, store: store)) }
        let redemption = AIConfirmations.shared.redeem(token, for: action)
        guard redemption == .accepted else {
            return .needsConfirmation(voiceQuestion(AIConfirmations.shared.ask(question, action: action, refused: redemption.refusal),
                next: "Ask the user in their language, with the price. Only if they agree, repeat the same call with confirm_token. "
                    + "Never treat your own plan as the user's approval."))
        }
        return .reserved(record(store, credits))
    }

    /// 删声音：请求批准模式问一句；全部权限直接删（结果里说删了）。点过头回 nil。
    static func voiceDeletion(action: String, question: String, token: String?, access: AIAccessStore? = nil) -> AIToolResult? {
        if (access ?? AIAccessStore.shared).mode == .full { return nil }
        let redemption = AIConfirmations.shared.redeem(token, for: action)
        if redemption == .accepted { return nil }
        return AIConfirmations.shared.ask(question, action: action, refused: redemption.refusal)
    }

    private static func voiceQuestion(_ result: AIToolResult, next: String) -> AIToolResult {
        guard case .object(var value) = result.payload else { return result }
        value["next_step"] = .string(next)
        var copy = result
        copy.payload = .object(value)
        return copy
    }

    private static func record(_ store: SkyStudioSpendStore, _ credits: Double) -> Reservation {
        store.record(credits)
        return Reservation(credits: credits, day: Date())
    }

}
