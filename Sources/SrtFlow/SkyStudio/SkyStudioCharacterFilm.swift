import Foundation
import SrtFlowMCPKit

// 官方 render 的角色资产解析；不下载图片，所有权和实际选图由服务器最终核对。
@MainActor
enum SkyStudioCharacterFilm {
    static func resolve(_ plan: SkyStudioReferencePlan, model: SkyStudioModel, key: String, api: SkyStudioAPI = SkyStudioAPI()) async throws -> SkyStudioReferencePlan {
        guard let reference = plan.character else { return plan }
        let character = try await api.character(reference.id, key: key)
        guard character.json["status"] == "ready" else { throw AIToolError("character_not_ready: wait for the original Character job before preparing an official render.") }
        if let revision = reference.revision, revision != character.revision { throw SkyStudioCharacterError.changed }
        let limits = model.referenceLimits(mode: plan.mode)
        let capacity = plan.mode == "frames" ? 1 : min((limits?["max_images"]?.intValue ?? 0) - plan.localCount("image"),
            (limits?["max_total_files"]?.intValue ?? Int.max) - plan.files.count)
        let roles = reference.roles ?? (plan.mode == "frames" ? ["front"] : Array(SkyStudioCharacter.roles.filter { character.images[$0] != nil }.prefix(max(0, capacity))))
        guard !roles.isEmpty, roles.count <= capacity, roles.allSatisfy({ character.images[$0] != nil }) else { throw AIToolError("Character views are unavailable or exceed the combined model limit.") }
        let urls = try roles.map { role -> String in
            guard let url = character.images[role]?["asset_url"]?.stringValue else { throw SkyStudioFailure.badAnswer(status: 200) }
            return url
        }
        let usage = try SkyStudioCharacterUsage(json: ["character_id": .string(reference.id), "revision": .string(character.revision),
            "roles": .array(roles.map(JSONValue.string)), "reference_image_count": .number(Double(plan.localCount("image") + roles.count)),
            "mode": model.kind == "image" ? .null : .string(plan.mode)])
        var result = plan
        result.character = .init(id: reference.id, roles: reference.roles, revision: character.revision)
        result.characterImageCount = roles.count
        result.characterAssets = SkyStudioCharacterAssets(usage: usage, urls: urls)
        return result
    }
}
