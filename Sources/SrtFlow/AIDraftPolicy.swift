import Foundation
import SrtFlowMCPKit

// MARK: - 目录驱动的草稿分辨率、越档判断与项目批准规格（纯值）。
enum AIDraftPolicy {
    static func resolution(model: SkyStudioModel, mode: String) -> String? {
        let choices = model.resolutions(mode: mode).sorted { rank($0) < rank($1) }
        guard !choices.isEmpty else { return model.defaults["resolution"]?.stringValue }
        if model.kind == "image" { return choices.first }
        // 视频优先 720p 同档；H3 是 768p。最低只有 1080p 的模型照实际能力，不捏造档位。
        return choices.first { rank($0) >= 720 } ?? choices.last
    }

    static func rank(_ value: String) -> Double {
        let text = value.lowercased()
        if text == "1k" { return 1024 }
        if text == "2k" { return 1440 }
        if text == "4k" { return 2160 }
        return Double(text.replacingOccurrences(of: "px", with: "").replacingOccurrences(of: "p", with: "")) ?? .infinity
    }

    static func deviations(_ generation: SkyStudioGeneration, model: SkyStudioModel) -> [String] {
        overrides(generation, model: model).map(\.reason)
    }

    /// 越档的每一项，连同用户点名它时会说的写法（user_requested_overrides 要 user_request 里找得到，AIOverrideQuote）。
    static func overrides(_ generation: SkyStudioGeneration, model: SkyStudioModel) -> [AIOverrideQuote.Item] {
        var result: [AIOverrideQuote.Item] = []
        let mode = generation.params["mode"]?.stringValue ?? "frames"
        if let actual = generation.params["resolution"]?.stringValue, let draft = resolution(model: model, mode: mode), rank(actual) > rank(draft) {
            result.append(.init(reason: "Resolution \(actual) exceeds this model's draft setting \(draft).", names: AIOverrideQuote.resolutionNames(actual)))
        }
        if let seconds = generation.params["duration"]?.doubleValue,
           let base = model.defaults["duration"]?.doubleValue, seconds > base {
            result.append(.init(reason: "Duration \(seconds)s exceeds the default \(base)s.", names: AIOverrideQuote.durationNames(seconds)))
        }
        return result
    }

    // 项目放行只覆盖同模型 / 规格和价格上限；不把整段提示词或随机 seed 绑成同一条镜头。
    static func profile(_ job: SkyStudioJobRequest) -> String {
        var params = job.params
        for key in ["seed", "reference_image_count", "reference_video_count", "reference_video_seconds", "reference_audio_count"] { params[key] = nil }
        let value: JSONValue = ["kind": .string(job.kind), "model": .string(job.model), "params": .object(params)]
        return value.encodedString()
    }
}
