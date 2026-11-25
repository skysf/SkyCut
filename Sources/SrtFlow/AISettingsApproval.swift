import Foundation
import SrtFlowMCPKit

// MARK: - MCP 改权限 / 提高硬预算：永远先问（全部权限也一样）
// 令牌绑定改前值与这次所有参数；未批准时整个 set_settings 不写任何 Store。
// 打开全部权限：问句后面接那段说明（SkyStudioVoiceStandingNotice：不再先问的事、声音的一次性费用价目、每日额度、打开即记下的长期授权那句），
// 令牌另绑那一句的版本（点过头记的就是用户看到的那一版，SkyCut 声音方案 5.6）。
// A daily-limit refusal asks its suggested raise in advance (limitRaise, the user's 「只问一次」, 2026-11-25): the same identity as
// check() computes for set_settings {daily_ai_credit_limit: value} from this limit and mode, so the user's yes to the refusal's
// question is the approval; any other change is asked here as before.
// A token is also bound to the limit's revision (SkyStudioSpendStore.limitRevision): any change of the limit since its question
// voids it, also a change back to the same value. A call that carries a token has it checked before anything in the call is
// written, and a token that is not accepted authorizes nothing (Codex CXM3, 2026-11-26).
@MainActor
enum AISettingsApproval {
    /// nil: go ahead and write. Otherwise the result to return: the question (asked again), and nothing is written.
    /// Throws for a token that was not accepted on a call with nothing that needs the user's yes.
    static func check(_ args: AIToolArguments, mode: AIAccessMode?, limit: Double?, fullAccess: SkyStudioVoiceStandingNotice? = nil,
                      access: AIAccessStore? = nil, spend: SkyStudioSpendStore? = nil) throws -> AIToolResult? {
        let token = try args.string("confirm_token")
        let access = access ?? .shared
        let spend = spend ?? .shared
        let beforeLimit = spend.dailyLimit
        let newMode = mode.flatMap { $0 == access.mode ? nil : $0 }
        let newLimit = limit.flatMap { $0 == beforeLimit ? nil : $0 }
        // Without a token only a mode change or a raise asks (lowering the limit needs no yes).
        guard token != nil || newMode != nil || newLimit.map({ $0 > beforeLimit }) == true else { return nil }
        var fields = args.raw.objectValue ?? [:]
        fields["confirm_token"] = nil
        let turningOn = newMode == .full
        let identity = identity(changes: fields, from: access.mode, limit: beforeLimit, revision: spend.limitRevision,
                                standingVersion: turningOn ? fullAccess?.statement.version : nil)
        let redemption = AIConfirmations.shared.redeem(token, for: identity)
        guard redemption != .accepted else { return nil }
        guard newMode != nil || newLimit != nil else {
            // A replay of a used token, or one for another change, on a call with nothing to approve (CXM3: a used 1,000 → 1,500
            // token replayed with the same limit and theme=classic wrote the theme): it authorizes nothing.
            throw AIToolError("The confirm_token was not accepted (\(Self.reason(redemption.refusal))), so nothing was changed. Nothing "
                + "in this call needs the user's approval: repeat it without confirm_token.")
        }
        // Asked (again). With a token that was not accepted, a limit change is asked even when it lowers the limit: the token answered
        // an earlier state (the user set 2,000 after a 1,000 → 1,500 offer), and writing it would undo the user's own change.
        var changes: [String] = []
        if let newMode { changes.append("permission mode: \(access.mode.title) -> \(newMode.title)") }
        // Named as the user finds it (MSG1): SkyCut's own setting, not the Sky Studio balance; whole credits, not "1000.0".
        if let newLimit {
            changes.append("SkyCut's daily credit limit for AI (a SkyCut setting at \(SkyCutDailyLimit.settingsPath { $0 }), not the "
                + "Sky Studio balance): \(SkyStudioCredits.text(beforeLimit)) -> \(SkyStudioCredits.text(newLimit)) credits a day")
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
    /// from `currentLimit` in the current permission mode and at the limit's current revision. Asking again before the answer
    /// returns the same token.
    static func limitRaise(to limit: Double, currentLimit: Double, access: AIAccessStore? = nil,
                           spend: SkyStudioSpendStore? = nil) -> SkyCutDailyLimit.RaiseQuestion? {
        let access = access ?? .shared
        guard limit > currentLimit else { return nil }
        let identity = identity(changes: ["daily_ai_credit_limit": .number(limit)], from: access.mode, limit: currentLimit,
                                revision: (spend ?? .shared).limitRevision, standingVersion: nil)
        let question = SkyCutDailyLimit.raiseQuestion(from: currentLimit, to: limit)
        let asked = AIConfirmations.shared.ask(question, action: identity, refused: nil)
        guard let token = asked.payload["confirm_token"]?.stringValue else { return nil }
        return .init(question: question, token: token, validMinutes: Int(AIConfirmations.lifetime / 60))
    }

    /// What a settings token is bound to: the change as sent (confirm_token removed), the mode and limit it starts from, the
    /// limit's revision, and the full-access statement's version when it turns full access on.
    private static func identity(changes: [String: JSONValue], from mode: AIAccessMode, limit: Double, revision: Int,
                                 standingVersion: String?) -> String {
        var value: [String: JSONValue] = ["from_mode": .string(mode.rawValue), "from_limit": .number(limit),
                                          "limit_revision": .number(Double(revision)), "changes": .object(changes)]
        if let standingVersion { value["standing_statement_version"] = .string(standingVersion) }
        return "ai-settings:" + JSONValue.object(value).encodedString()
    }

    private static func reason(_ refusal: AIConfirmations.Refusal?) -> String {
        switch refusal {
        case .used?: return "it was already used"
        case .expired?: return "it expired"
        case .otherAction?: return "it was issued for another change, or the daily limit changed since"
        case .unknown?, nil: return "SkyCut did not issue it, or issued it too long ago"
        }
    }
}
