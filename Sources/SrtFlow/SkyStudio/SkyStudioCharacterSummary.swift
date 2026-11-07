import Foundation
import SrtFlowMCPKit

// 角色选择页的有界摘要；完整 DTO / 资产地址只供 get_character，不因列表裁短而改缓存或详情。
enum SkyStudioCharacterSummary {
    static let maximumBytes = 1024

    static func json(_ character: SkyStudioCharacter) -> JSONValue {
        let original = character.json
        var fields: [String: JSONValue] = [
            "id": .string(UUID(uuidString: character.id)!.uuidString.lowercased()),
            "name": text(original["name"], budget: 256, truncate: true) ?? "",
            "status": text(original["status"], budget: 16, truncate: true) ?? "",
            "revision": .string(character.revision),
            "available_roles": .array(SkyStudioCharacter.roles.filter { character.images[$0]?.isNull == false }.map(JSONValue.string))
        ]
        for (key, budget) in [("default_generation_model", 96), ("default_generation_resolution", 32), ("created_at", 40), ("updated_at", 40)] {
            // 不裁断模型身份或日期；异常长的可选字段留到完整详情，避免造出另一个模型 id。
            if let value = text(original[key], budget: budget) { fields[key] = value }
        }
        return .object(fields)
    }

    /// 按 JSON 的真实 UTF-8 字节计（含引号 / 转义），不按可能无限长的 grapheme 数计。
    private static func text(_ value: JSONValue?, budget: Int, truncate: Bool = false) -> JSONValue? {
        guard let text = value?.stringValue else { return nil }
        if JSONValue.string(text).encodedString().utf8.count <= budget { return .string(text) }
        guard truncate else { return nil }
        var clipped = ""
        for scalar in text.unicodeScalars {
            let next = clipped + String(scalar)
            if JSONValue.string(next).encodedString().utf8.count > budget { break }
            clipped = next
        }
        return .string(clipped)
    }
}
