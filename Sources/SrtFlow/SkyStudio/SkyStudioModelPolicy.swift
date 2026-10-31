import Foundation
import SrtFlowMCPKit

// MARK: - 生成模型的偏好顺序（纯值）
// 管什么：用户 2026-10-30 定的顺序；只从服务器实际提供且能收完整输入的模型里挑。
// 不管什么：猜人物国籍 / 文化背景（由理解需求的 AI 填 image_context）、模型能力或价格（只读 /models）、付费和重试。
enum SkyStudioModelPolicy {
    static let videoOrder = ["minimax-h3", "gemini-omni-1.1-flash", "veo-fast", "seedance-2-pro", "seedance-2-5", "veo-pro"]
    static let qualityOrder = ["seedance-2-5", "veo-pro", "minimax-h3", "gemini-omni-1.1-flash", "veo-fast", "seedance-2-pro"]
    static let guidance = "Images: Asian people, places or cultural scenes prefer seedream5-flash; non-Asian, mixed or unclear prefer nano2. "
        + "Judge the subject, not the prompt language. Video: minimax-h3, then gemini-omni-1.1-flash, veo-fast, seedance-2-pro. "
        + "Only when the user explicitly wants maximum quality without cost/time limits use highest: seedance-2-5, then veo-pro. "
        + "Select lip-sync by its image/audio or video/audio inputs; use image operation=remove_background for cutouts. "
        + "Never automatically regenerate or switch models after failure or an unknown outcome. Query the original job and its billing. Read each model's input modes and limits."

    static func ordered(kind: String, imageContext: String, quality: String) -> [String] {
        if kind == "image" { return imageContext == "asian" ? ["seedream5-flash", "nano2"] : ["nano2", "seedream5-flash"] }
        return quality == "highest" ? qualityOrder : videoOrder
    }

    static func select(catalog: SkyStudioCatalog, kind: String, requested: String?, imageContext: String = "other", quality: String = "standard",
                       accepts: (SkyStudioModel) -> Bool = { _ in true }) -> SkyStudioModel? {
        let offered = catalog.models(kind: kind)
        if let requested { return offered.first { $0.id == requested && accepts($0) } }
        if kind == "music" || kind == "sound_effect" || kind == "lipsync" { return offered.first(where: accepts) }
        if kind == "image", let removal = offered.first(where: { $0.operation == "remove_background" && accepts($0) }) { return removal }
        return ordered(kind: kind, imageContext: imageContext, quality: quality).compactMap { id in offered.first { $0.id == id } }.first(where: accepts)
    }

    static func problem(model: SkyStudioModel, ask: SkyStudioGeneration.Ask, references: SkyStudioReferencePlan) -> String? {
        if let problem = references.problem(model: model) { return problem }
        if let resolution = ask.resolution {
            let choices = model.resolutions(mode: references.mode)
            if !choices.isEmpty, !choices.contains(where: { $0.caseInsensitiveCompare(resolution) == .orderedSame }) { return "\(model.title) accepts resolution \(choices.joined(separator: ", ")) in \(references.mode) mode." }
        }
        if model.kind == "text_to_video" || model.kind == "image_to_video", let seconds = ask.duration?.rounded() {
            if let values = model.params["duration_values"]?.arrayValue?.compactMap(\.doubleValue), !values.isEmpty, !values.contains(seconds) {
                return "\(model.title) accepts duration \(values.map { String(Int($0)) }.joined(separator: ", ")) seconds."
            }
            if model.params["duration_values"] == nil, let range = model.params["duration"]?.arrayValue?.compactMap(\.doubleValue), range.count == 2,
               seconds < range[0] || seconds > range[1] { return "\(model.title) accepts \(range[0])–\(range[1]) seconds." }
        }
        return nil
    }
}
