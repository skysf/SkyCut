import Foundation
import SrtFlowMCPKit

// 角色原生任务的 HTTP 合同。创建 / 头像各一条路，导入只走 import；不混入普通图的 aspect_ratio 或本机参考计数。
struct SkyStudioCharacterNativeRequest: Equatable, Sendable, Codable {
    enum Operation: String, Codable, Sendable { case create = "character_create", headshot = "character_headshot", importViews = "character_import" }
    var operation: Operation
    var fields: [String: JSONValue]

    var quoteBody: JSONValue {
        if operation == .importViews { return ["operation": .string(operation.rawValue)] }
        return .object(fields.merging(["kind": "image", "operation": .string(operation.rawValue)]) { _, new in new })
    }

    func submissionBody(inputs: [String: JSONValue], revision: String?, maxCredits: Double?, key: String) -> JSONValue {
        var body = fields
        body["idempotency_key"] = .string(key)
        if operation == .create, !inputs.isEmpty { body["inputs"] = .object(inputs) }
        if operation == .headshot {
            body["character_id"] = nil
            body["character_revision"] = revision.map(JSONValue.string)
        }
        if operation != .importViews { body["max_credits"] = maxCredits.map(JSONValue.number) }
        return .object(body)
    }

    var path: String {
        get throws {
            switch operation {
            case .create: return "characters/create"
            case .importViews: return "characters/import"
            case .headshot: return try SkyStudioCharacterPath.detail(fields["character_id"]?.stringValue ?? "") + "/headshot"
            }
        }
    }
}

// 免费修改的单次 HTTP 请求；不伪造 job / 钱包 / 时间线操作。
struct SkyStudioCharacterMutation: Equatable, Sendable, Codable {
    var id: String
    var method: String
    var role: String?
    var body: [String: JSONValue]
}
