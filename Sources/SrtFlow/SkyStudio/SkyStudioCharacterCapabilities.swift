import Foundation
import SrtFlowMCPKit

// 角色专用能力目录，独立于 /models。只读服务端模型、档位、默认值、价格与长度合同，不复制价格表。
struct SkyStudioCharacterCapabilities: Equatable, Sendable {
    var json: JSONValue
    var models: [JSONValue] { json["models"]!.arrayValue! }
    var promptLimit: Int { json["max_prompt_characters"]!.intValue! }
    var requiredRoles: [String] { json["required_import_roles"]!.arrayValue!.compactMap(\.stringValue) }

    init(json: JSONValue) throws {
        guard let models = json["models"]?.arrayValue, !models.isEmpty,
              models.allSatisfy({ $0["id"]?.stringValue != nil && $0["resolution"]?.arrayValue?.isEmpty == false }),
              let maximum = json["max_prompt_characters"]?.intValue, maximum > 0,
              json["defaults"]?["model"]?.stringValue != nil, json["defaults"]?["resolution"]?.stringValue != nil,
              let roles = json["required_import_roles"]?.arrayValue, !roles.isEmpty,
              roles.allSatisfy({ $0.stringValue.map(SkyStudioCharacter.roles.contains) == true }),
              json["import_credits"] == 0, json["mutation_credits"] == 0 else { throw SkyStudioFailure.badAnswer(status: 200) }
        self.json = json
    }

    func select(model requested: String?, resolution requestedResolution: String?, saved: SkyStudioCharacter?) throws -> (model: String, resolution: String) {
        let savedModel = saved?.json["default_generation_model"]?.stringValue
        let defaultModel = json["defaults"]!["model"]!.stringValue!
        let id = requested ?? (models.contains { $0["id"]?.stringValue == savedModel } ? savedModel : nil) ?? defaultModel
        guard let model = models.first(where: { $0["id"] == .string(id) }) else { throw AIToolError("Choose a native Character model from list_characters capabilities=true.") }
        let resolutions = model["resolution"]!.arrayValue!.compactMap(\.stringValue)
        let savedResolution = saved?.json["default_generation_resolution"]?.stringValue
        let fallback = json["defaults"]!["resolution"]!.stringValue!
        let resolution = requestedResolution ?? (savedModel == id && savedResolution.map(resolutions.contains) == true ? savedResolution : nil)
            ?? (resolutions.contains(fallback) ? fallback : resolutions.first)
        guard let resolution, resolutions.contains(resolution) else { throw AIToolError("Choose a Character resolution offered for \(id): \(resolutions.joined(separator: ", ")).") }
        return (id, resolution)
    }
}
