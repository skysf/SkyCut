import Foundation
import SrtFlowMCPKit

// MARK: - MCP 改权限 / 提高硬预算：永远先问（全部权限也一样）
// 令牌绑定改前值与这次所有参数；未批准时整个 set_settings 不写任何 Store。
@MainActor
enum AISettingsApproval {
    static func check(_ args: AIToolArguments, mode: AIAccessMode?, limit: Double?, access: AIAccessStore? = nil,
                      currentLimit: Double? = nil) throws -> AIToolResult? {
        _ = try args.string("confirm_token")
        let access = access ?? .shared
        let beforeLimit = currentLimit ?? SkyStudioSpendStore.shared.dailyLimit
        guard mode.map({ $0 != access.mode }) == true || limit.map({ $0 > beforeLimit }) == true else { return nil }
        var fields = args.raw.objectValue ?? [:]
        fields["confirm_token"] = nil
        let value: JSONValue = ["from_mode": .string(access.mode.rawValue), "from_limit": .number(beforeLimit), "changes": .object(fields)]
        let identity = "ai-settings:" + value.encodedString()
        let redemption = AIConfirmations.shared.redeem(try args.string("confirm_token"), for: identity)
        guard redemption != .accepted else { return nil }
        var changes: [String] = []
        if let mode, mode != access.mode { changes.append("permission mode: \(access.mode.title) -> \(mode.title)") }
        if let limit, limit > beforeLimit { changes.append("daily hard budget: \(beforeLimit) -> \(limit) credits") }
        var result = AIConfirmations.shared.ask(
            "Ask the user in their conversation language to approve these settings changes: \(changes.joined(separator: "; ")). "
                + "Use the localized permission names (Chinese: request approval / all permissions); only after explicit agreement repeat this exact call with confirm_token. No settings have changed.",
            action: identity, refused: redemption.refusal
        )
        if case .object(var value) = result.payload {
            value["permission_modes"] = .array(AIAccessMode.allCases.map { ["id": .string($0.rawValue), "names": $0.names] })
            result.payload = .object(value)
        }
        return result
    }
}
