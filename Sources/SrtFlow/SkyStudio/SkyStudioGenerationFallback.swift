import Foundation

// MARK: - Seedance 真人参考拒绝后的单次替换（纯值）
// 管什么：只有明确拒绝 + 未扣 / 已退才挑 MiniMax 或 Google，完整保留素材和时长。
// 不管什么：重交、消费、提示词改写；通用安全拒绝、超时、未知结果都不触发。
enum SkyStudioGenerationFallback {
    struct Candidate: Equatable, Sendable {
        var model: SkyStudioModel
        var generation: SkyStudioGeneration
    }

    static func candidate(failure: SkyStudioJobFailure, originalModel: String, generation: SkyStudioGeneration,
                          ask: SkyStudioGeneration.Ask, references: SkyStudioReferencePlan, catalog: SkyStudioCatalog,
                          canvas: Double, frame: Double?, alreadySwitched: Bool) -> Candidate? {
        guard !alreadySwitched, failure.mayReplace, generation.kind.isVideo, !references.files.isEmpty,
              ["seedance-2-pro", "seedance-2-5"].contains(originalModel) else { return nil }
        for id in SkyStudioModelPolicy.refusalOrder {
            guard let model = catalog.model(id, kind: generation.kind.rawValue) else { continue }
            var next = ask
            next.duration = generation.params["duration"]?.doubleValue
            // 只换输出档位；首帧、多模态引用和要求的长度一个也不丢。
            let choices = model.resolutions(mode: references.mode)
            if let resolution = next.resolution, !choices.isEmpty, !choices.contains(resolution) { next.resolution = nil }
            guard SkyStudioModelPolicy.problem(model: model, ask: next, references: references) == nil else { continue }
            let made = SkyStudioGeneration.make(generation.kind, prompt: generation.prompt, ask: next, canvas: canvas, frame: frame,
                                                model: model, inputMode: references.mode, references: references)
            return Candidate(model: model, generation: made)
        }
        return nil
    }
}
