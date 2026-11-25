import Foundation
import SrtFlowMCPKit

// MARK: - MCP 改权限 / 提高硬预算：永远先问（全部权限也一样）
// 令牌绑定改前值与这次所有参数；未批准时整个 set_settings 不写任何 Store。
// 打开全部权限：问句后面接那段说明（SkyStudioVoiceStandingNotice：不再先问的事、声音的一次性费用价目、每日额度、打开即记下的长期授权那句），
// 令牌另绑那一句的版本（点过头记的就是用户看到的那一版，SkyCut 声音方案 5.6）。
// A daily-limit refusal asks its suggested raise in advance (limitRaise, the user's 「只问一次」, 2026-11-25): the same identity as
// check() computes for set_settings {daily_ai_credit_limit: value} from this limit and mode, so the user's yes to the refusal's
// question is the approval; any other change is asked here as before.
@MainActor
enum AISettingsApproval {
    static func check(_ args: AIToolArguments, mode: AIAccessMode?, limit: Double?, fullAccess: SkyStudioVoiceStandingNotice? = nil,
                      access: AIAccessStore? = nil, currentLimit: Double? = nil) throws -> AIToolResult? {
        let token = try args.string("confirm_token")
        let access = access ?? .shared
        let beforeLimit = currentLimit ?? SkyStudioSpendStore.shared.dailyLimit
        let asks = mode.map({ $0 != access.mode }) == true || limit.map({ $0 > beforeLimit }) == true
        // A token answers the change from the limit and mode it was asked with. Once the limit moved (the user set 2,000 after a
        // 1,000 → 1,500 offer), its late answer would set the limit back: it is void, and the change is asked again even though
        // it now lowers the limit (MSG1 review, 2026-11-25).
        let late = token != nil && limit.map({ $0 != beforeLimit }) == true
        guard asks || late else { return nil }
        var fields = args.raw.objectValue ?? [:]
        fields["confirm_token"] = nil
        let turningOn = mode == .full && access.mode != .full
        let identity = identity(changes: fields, from: access.mode, limit: beforeLimit,
                                standingVersion: turningOn ? fullAccess?.statement.version : nil)
        let redemption = AIConfirmations.shared.redeem(token, for: identity)
        guard redemption != .accepted else { return nil }
        var changes: [String] = []
        if let mode, mode != access.mode { changes.append("permission mode: \(access.mode.title) -> \(mode.title)") }
        // Named as the user finds it (MSG1): SkyCut's own setting, not the Sky Studio balance; whole credits, not "1000.0".
        if let limit, limit != beforeLimit {
            changes.append("SkyCut's daily credit limit for AI (a SkyCut setting at \(SkyCutDailyLimit.settingsPath { $0 }), not the "
                + "Sky Studio balance): \(SkyStudioCredits.text(beforeLimit)) -> \(SkyStudioCredits.text(limit)) credits a day")
        }
        var question = "Ask the user in their conversation language to approve these settings changes: \(changes.joined(separator: "; ")). "
            + "Use the localized permission names (Chinese: request approval / all permissions); only after explicit agreement repeat this exact call with confirm_token. No settings have changed."
        if turningOn, let fullAccess { question += " " + fullAccess.turnOnText }
        var result = AIConfirmations.shared.ask(question, action: identity, refused: redemption.refusal)
        if case .object(var value) = result.payload {
            value["permission_modes"] = .array(AIAccessMode.allCases.map { ["id": .string($0.rawValue), "names": $0.names] })
            result.payload = .object(value)
        }
        return result
    }

    /// A daily-limit refusal's option (a): SkyCut's question and a token for exactly set_settings {daily_ai_credit_limit: `to`}
    /// from `currentLimit` in the current permission mode. Asking again before the answer returns the same token.
    static func limitRaise(to limit: Double, currentLimit: Double, access: AIAccessStore? = nil) -> SkyCutDailyLimit.RaiseQuestion? {
        let access = access ?? .shared
        guard limit > currentLimit else { return nil }
        let identity = identity(changes: ["daily_ai_credit_limit": .number(limit)], from: access.mode, limit: currentLimit, standingVersion: nil)
        let question = SkyCutDailyLimit.raiseQuestion(from: currentLimit, to: limit)
        let asked = AIConfirmations.shared.ask(question, action: identity, refused: nil)
        guard let token = asked.payload["confirm_token"]?.stringValue else { return nil }
        return .init(question: question, token: token, validMinutes: Int(AIConfirmations.lifetime / 60))
    }

    /// What a settings token is bound to: the change as sent (confirm_token removed), the mode and limit it starts from, and the
    /// full-access statement's version when it turns full access on.
    private static func identity(changes: [String: JSONValue], from mode: AIAccessMode, limit: Double, standingVersion: String?) -> String {
        var value: [String: JSONValue] = ["from_mode": .string(mode.rawValue), "from_limit": .number(limit), "changes": .object(changes)]
        if let standingVersion { value["standing_statement_version"] = .string(standingVersion) }
        return "ai-settings:" + JSONValue.object(value).encodedString()
    }
}
