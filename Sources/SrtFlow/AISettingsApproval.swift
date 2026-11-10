import Foundation
import SrtFlowMCPKit

// MARK: - MCP 改权限 / 提高硬预算：永远先问（全部权限也一样）
// 令牌绑定改前值与这次所有参数；未批准时整个 set_settings 不写任何 Store。
// 打开全部权限：问句后面接那段说明（SkyStudioVoiceStandingNotice：不再先问的事、声音的一次性费用价目、每日额度、打开即记下的长期授权那句），
// 令牌另绑那一句的版本（点过头记的就是用户看到的那一版，SkyCut 声音方案 5.6）。
@MainActor
enum AISettingsApproval {
    static func check(_ args: AIToolArguments, mode: AIAccessMode?, limit: Double?, fullAccess: SkyStudioVoiceStandingNotice? = nil,
                      access: AIAccessStore? = nil, currentLimit: Double? = nil) throws -> AIToolResult? {
        _ = try args.string("confirm_token")
        let access = access ?? .shared
        let beforeLimit = currentLimit ?? SkyStudioSpendStore.shared.dailyLimit
        guard mode.map({ $0 != access.mode }) == true || limit.map({ $0 > beforeLimit }) == true else { return nil }
        var fields = args.raw.objectValue ?? [:]
        fields["confirm_token"] = nil
        var value: [String: JSONValue] = ["from_mode": .string(access.mode.rawValue), "from_limit": .number(beforeLimit), "changes": .object(fields)]
        let turningOn = mode == .full && access.mode != .full
        if turningOn, let fullAccess { value["standing_statement_version"] = .string(fullAccess.statement.version) }
        let identity = "ai-settings:" + JSONValue.object(value).encodedString()
        let redemption = AIConfirmations.shared.redeem(try args.string("confirm_token"), for: identity)
        guard redemption != .accepted else { return nil }
        var changes: [String] = []
        if let mode, mode != access.mode { changes.append("permission mode: \(access.mode.title) -> \(mode.title)") }
        if let limit, limit > beforeLimit { changes.append("daily hard budget: \(beforeLimit) -> \(limit) credits") }
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
}
