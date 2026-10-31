import Foundation
import SrtFlowMCPKit

// MARK: - 目录驱动的生成附加参数
// 管什么：MCP 参数类型、模型公开的开关 / 数值 / 默认值，以及操作必需项；不计价、不上传、不猜供应商限制。
enum SkyStudioGenerationControls {
    static let flags = ["enable_caption", "enable_dynamic_duration", "disable_music_track", "enable_speech_enhancement",
                        "enable_transcription", "enable_safety_checker", "sync_mode", "enable_prompt_expansion", "enable_thinking"]
    static let names = flags + ["title", "start_time", "end_time", "seed"]

    static func ask(_ args: AIToolArguments) throws -> SkyStudioGeneration.Ask {
        let smart = args.raw["duration"]?.isNull == true || args.raw["duration"]?.stringValue?.lowercased() == "auto"
        var ask = SkyStudioGeneration.Ask(duration: smart ? nil : try args.double("duration"), resolution: try args.string("resolution"),
            aspectRatio: try args.string("aspect_ratio"), instrumental: try args.bool("instrumental"), lyrics: try args.string("lyrics"),
            generateAudio: try args.bool("generate_audio"))
        ask.smartDuration = smart
        ask.operation = try args.choice("operation", from: ["generate", "remove_background"]) ?? "generate"
        for field in flags {
            if let flag = try args.bool(field) { ask.controls[field] = .bool(flag) }
        }
        if let title = try args.string("title") { ask.controls["title"] = .string(title) }
        for field in ["start_time", "end_time", "seed"] {
            if let number = try args.double(field) { ask.controls[field] = .number(number) }
        }
        if try args.bool("auto_fallback") == true {
            throw AIToolError("Automatic model replacement is disabled. Query the original job; a new generation needs a new approved budget.")
        }
        return ask
    }

    static func problem(model: SkyStudioModel, ask: SkyStudioGeneration.Ask, prompt: String, references: SkyStudioReferencePlan) -> String? {
        if model.operation != ask.operation { return "\(model.title) serves operation=\(model.operation)." }
        let audioDriven = model.kind == "lipsync"
        let remove = ask.operation == "remove_background"
        if ask.resolution != nil, model.params["resolution"] == nil { return "This model does not expose a resolution selector." }
        if audioDriven || remove {
            if !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "This operation takes media, not a prompt." }
            if ask.duration != nil || ask.smartDuration || ask.aspectRatio != nil || ask.generateAudio != nil || ask.instrumental != nil || ask.lyrics != nil {
                return "This operation does not accept duration, aspect_ratio, generate_audio, instrumental or lyrics. Output duration follows the supplied audio/video."
            }
            if remove && ask.resolution != nil { return "Background removal has no resolution selector; use the actual output dimensions." }
        } else if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  model.kind != "image_to_video" || model.params["smart_duration"] == nil { return "prompt is required for this model." }
        if let max = model.limit("max_prompt_characters"), Double(prompt.unicodeScalars.count) > max { return "prompt exceeds \(Int(max)) Unicode characters." }
        if ask.smartDuration && model.params["smart_duration"] == nil { return "This model does not offer smart duration (null/auto)." }
        if model.params["smart_duration"] != nil, let seconds = ask.duration, seconds.rounded() != seconds { return "duration must be whole seconds or auto for this model." }
        if let ratio = ask.aspectRatio, !model.choices("aspect_ratio").isEmpty, !model.choices("aspect_ratio").contains(ratio) {
            return "aspect_ratio must be one of: \(model.choices("aspect_ratio").joined(separator: ", "))."
        }
        for (field, value) in ask.controls {
            guard let spec = model.params[field] else { return "\(model.title) does not expose \(field)." }
            if case .bool = value, let choices = spec.arrayValue, !choices.contains(value) { return "Unsupported \(field) value." }
            if let number = value.doubleValue {
                if number < 0 { return "\(field) must be non-negative." }
                if field == "seed" {
                    let range = spec.arrayValue?.compactMap(\.doubleValue) ?? []
                    let low = spec["min"]?.doubleValue ?? range.first
                    let high = spec["max"]?.doubleValue ?? range.last
                    if number.rounded() != number || low.map({ number < $0 }) == true || high.map({ number > $0 }) == true { return "seed is outside the catalog's integer range." }
                }
            }
        }
        if let title = ask.controls["title"]?.stringValue, let max = model.limit("max_title_characters"), Double(title.unicodeScalars.count) > max { return "title exceeds \(Int(max)) Unicode characters." }
        let start = ask.controls["start_time"]?.doubleValue ?? 0
        let end = ask.controls["end_time"]?.doubleValue
        if let video = references.files.first(where: { $0.role == "video_url" })?.duration,
           start >= video || end.map({ $0 > video || $0 <= start }) == true { return "start_time/end_time must be inside the measured source video, with end_time greater than start_time." }
        if references.webURL != nil || references.count("document") > 0, model.limits["document_or_web_requires_thinking"]?.boolValue == true {
            if ask.controls["enable_thinking"] == false || ask.controls["enable_prompt_expansion"] == false { return "Document/page references require thinking and prompt expansion." }
        }
        if let seconds = ask.duration, let max = model.limit("max_input_plus_output_seconds"), seconds + ceil(references.videoSeconds) > max {
            return "Reference video plus output exceeds the catalog's \(max)-second limit."
        }
        return nil
    }
}
