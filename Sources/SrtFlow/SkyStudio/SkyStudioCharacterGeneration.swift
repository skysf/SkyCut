import Foundation
import SrtFlowMCPKit

// 角色与本机参考的组合：只做输入形状 / 目录检查；省略视图时的最终选择和 mode 仍以服务器报价为准。
enum SkyStudioCharacterGeneration {
    static func references(_ local: SkyStudioReferencePlan, model: SkyStudioModel, explicitMode: String?) -> SkyStudioReferencePlan {
        guard local.character != nil else { return local }
        var result = local
        if model.kind != "image", explicitMode == nil, local.firstFrame == nil,
           model.choices("mode").contains("multimodal") || model.inputs["modes"]?["multimodal"] != nil {
            result.mode = "multimodal"
        }
        result.characterImageCount = local.character?.roles?.count ?? 1
        return result
    }

    static func problem(_ plan: SkyStudioReferencePlan, model: SkyStudioModel) -> String? {
        guard let character = plan.character else { return nil }
        guard ["image", "image_to_video", "text_to_video"].contains(model.kind), model.operation == "generate" else { return "Characters support ordinary image/video generation only." }
        if plan.mode == "frames" {
            if model.kind != "image_to_video" || !plan.files.isEmpty || plan.webURL != nil { return "Character frames require image_to_video with no explicit frame or other reference; choose multimodal for combined inputs." }
            if let roles = character.roles, roles.count != 1 { return "Character frames accept one view only; omit roles to let Sky Studio select front." }
        }
        guard model.referenceLimits(mode: plan.mode) != nil else { return "The model catalog does not offer character image references in this mode." }
        return nil
    }

    static func accept(_ quote: SkyStudioQuote, generation: inout SkyStudioGeneration, references: inout SkyStudioReferencePlan, model: SkyStudioModel) throws {
        guard let character = generation.character else { return }
        guard let usage = quote.characterUsage else { throw SkyStudioFailure.badAnswer(status: 200) }
        let exact = try character.quoted(usage, localImages: references.localCount("image"))
        if generation.kind.isVideo {
            guard let mode = usage.mode else { throw SkyStudioFailure.badAnswer(status: 200) }
            generation.params["mode"] = .string(mode)
            references.mode = mode
        }
        generation.character = exact
        references.character = exact
        references.characterImageCount = usage.roles.count
        if let problem = self.problem(references, model: model) ?? references.problem(model: model) { throw AIToolError(problem) }
    }
}
