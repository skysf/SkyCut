import Foundation
import SrtFlowMCPKit

// MARK: - generate_media 的一次生成：送 Sky Studio 的 kind、prompt、params（纯值）
//
// 管什么：AI 给的参数读成 Sky Studio `/quote`、`/jobs` 要的那一份（收费方案第 6 刀 6b，2026-10-28 起；之前送 fal）。
// - 默认值：图和文生视频的画幅跟画布；图生视频送离首帧最近的那个；视频 5 秒 768p；音效 5 秒 wav；音乐纯音乐、长度让模型定。
// - 换成 Sky Studio 的写法：视频和音乐的秒数取整。
// - 给了但这一种用不上的参数说一句。
// **规矩在服务器上**（多长、多大、哪几种画幅、音乐 60–180 秒）：这里不另抄一份去拦，送过去不合规的 `/quote` 回 `invalid_request`，原话交给 AI。
// 取值见 Sky Studio 仓库 docs/agents/skycut-api.md「Per kind」。
// 不管什么：问价、把关、跑任务、下载（SkyStudioGenerateTool / SkyStudioGenerationRun）；用哪个模型（`/models` 按 kind 列）。

struct SkyStudioGeneration: Equatable, Sendable {
    /// generate_media 的 kind（= `MCPVocabulary.generationKinds`，check-sky-studio 对账）。旁白、克隆走 add_voiceover。
    enum Kind: String, CaseIterable, Sendable {
        case image
        case imageToVideo = "image_to_video"
        case textToVideo = "text_to_video"
        case music
        case soundEffect = "sound_effect"

        var isVideo: Bool { self == .imageToVideo || self == .textToVideo }
        var isSound: Bool { self == .music || self == .soundEffect }
    }

    /// 图片（Seedream 5 Flash）认的画幅：Sky Studio 的 `ARK_IMAGE_2K_ASPECT_RATIOS`（= `MCPVocabulary.generationAspects`）。
    static let imageAspects = ["21:9", "16:9", "3:2", "4:3", "5:4", "1:1", "4:5", "3:4", "2:3", "9:16"]
    /// 视频（MiniMax H3）认的画幅：`MINIMAX_H3_ASPECT_RATIOS`，都在图片那几种里。
    static let videoAspects = ["21:9", "16:9", "4:3", "1:1", "3:4", "9:16"]
    /// 视频的分辨率：`MINIMAX_H3_FRAMES_RESOLUTIONS`，没有 1080p（= `MCPVocabulary.videoResolutions`）。
    static let videoResolutions = ["480p", "768p"]
    static let defaultResolution = "768p"
    static let defaultVideoSeconds = 5.0
    static let defaultEffectSeconds = 5.0

    /// AI 给的那几个，都可以不给。
    struct Ask: Equatable, Sendable {
        var duration: Double?
        var resolution: String?
        var aspectRatio: String?
        var instrumental: Bool?
        var lyrics: String?

        init(duration: Double? = nil, resolution: String? = nil, aspectRatio: String? = nil, instrumental: Bool? = nil, lyrics: String? = nil) {
            self.duration = duration
            self.resolution = resolution
            self.aspectRatio = aspectRatio
            self.instrumental = instrumental
            self.lyrics = lyrics
        }
    }

    var kind: Kind
    var prompt: String
    var params: [String: JSONValue]
    /// 给了但这一种用不上、没送过去的参数（结果里说一句，AI 才知道它没生效）。
    var notes: [String]

    /// `canvas`：工程画布的宽 / 高（图和文生视频默认跟它）；`frame`：图生视频首帧的宽 / 高（读不出来就跟画布）。
    static func make(_ kind: Kind, prompt: String, ask: Ask, canvas: Double, frame: Double? = nil) -> SkyStudioGeneration {
        var params: [String: JSONValue] = [:]
        var notes: [String] = []
        func ignored(_ name: String, _ why: String) { notes.append("\(name) was ignored: \(why).") }
        switch kind {
        case .image:
            params["aspect_ratio"] = .string(ask.aspectRatio ?? nearestAspect(to: canvas, in: imageAspects))
        case .textToVideo, .imageToVideo:
            params["duration"] = .number((ask.duration ?? defaultVideoSeconds).rounded())
            params["resolution"] = .string(ask.resolution ?? defaultResolution)
            if kind == .textToVideo {
                params["aspect_ratio"] = .string(ask.aspectRatio ?? nearestAspect(to: canvas, in: videoAspects))
            } else {
                // 出来的视频跟着首帧的形状；网页那条路仍要一个画幅，送离首帧最近的那个（合同「Image to video」）。
                params["aspect_ratio"] = .string(nearestAspect(to: frame ?? canvas, in: videoAspects))
                if ask.aspectRatio != nil { ignored("aspect_ratio", "image_to_video keeps the picture's shape") }
            }
        case .music:
            // 不给时长就让模型自己定（Sky Studio 的 auto）。
            if let seconds = ask.duration { params["duration"] = .number(seconds.rounded()) }
            let instrumental = ask.instrumental ?? true
            params["instrumental"] = .bool(instrumental)
            if let lyrics = ask.lyrics?.trimmingCharacters(in: .whitespacesAndNewlines), !lyrics.isEmpty {
                if instrumental {
                    ignored("lyrics", "instrumental is true; pass instrumental=false for a song with words")
                } else {
                    params["lyrics"] = .string(lyrics)
                }
            }
        case .soundEffect:
            params["duration"] = .number(ask.duration ?? defaultEffectSeconds)
            params["audio_format"] = "wav"
        }
        if kind.isSound, ask.aspectRatio != nil { ignored("aspect_ratio", "it only applies to images and video") }
        if !kind.isVideo, ask.resolution != nil { ignored("resolution", "it only applies to video") }
        if kind == .image, ask.duration != nil { ignored("duration", "an image has no length") }
        if kind != .music, ask.instrumental != nil { ignored("instrumental", "it only applies to music") }
        if kind != .music, ask.lyrics != nil { ignored("lyrics", "it only applies to music") }
        return SkyStudioGeneration(kind: kind, prompt: prompt, params: params, notes: notes)
    }

    /// 送 `/quote`、`/jobs` 的那一份（每次一个新的 idempotency_key）。`imageURL`：图生视频的首帧（`/uploads` 上去的）；
    /// `maxCredits`：用户同意的价（只有 `/jobs` 带）。
    func job(model: String, imageURL: URL? = nil, maxCredits: Double? = nil) -> SkyStudioJobRequest {
        var inputs: [String: String] = [:]
        if let imageURL { inputs["image_url"] = imageURL.absoluteString }
        return SkyStudioJobRequest(kind: kind.rawValue, model: model, prompt: prompt, inputs: inputs, params: params, maxCredits: maxCredits)
    }

    /// 「MiniMax H3 · 5 s · 768p」：确认码绑着它（SkyStudioJobGate），状态行上也写它。不带语言的几个记号。
    func summary(modelTitle: String) -> String {
        var parts = [modelTitle]
        switch kind {
        case .image:
            parts.append(params["aspect_ratio"]?.stringValue ?? "")
        case .imageToVideo, .textToVideo:
            parts.append("\(Int(params["duration"]?.doubleValue ?? 0)) s")
            parts.append(params["resolution"]?.stringValue ?? Self.defaultResolution)
        case .music:
            parts.append(params["duration"]?.doubleValue.map { "\(Int($0)) s" } ?? "auto")
            if params["instrumental"]?.boolValue == false { parts.append("vocals") }
        case .soundEffect:
            parts.append(String(format: "%.1f s", params["duration"]?.doubleValue ?? 0))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// `/quote` 没报 typical_seconds 时按种类估（状态行上「通常几分钟」、给 AI 的「等多久」）。
    var typicalSeconds: Double {
        switch kind {
        case .image: return 15
        case .soundEffect: return 10
        case .music: return 60
        case .imageToVideo, .textToVideo: return 180
        }
    }

    // MARK: 画幅

    /// 一个画幅在给定的几个里离谁最近（按宽高比取对数差）；`ratio` 不是正数就是第一个。
    static func nearestAspect(to ratio: Double, in options: [String]) -> String {
        guard ratio > 0, ratio.isFinite else { return options.first ?? "16:9" }
        var best = options.first ?? "16:9"
        var bestGap = Double.infinity
        for option in options {
            guard let value = aspectValue(option) else { continue }
            let gap = abs(log(value / ratio))
            if gap < bestGap { best = option; bestGap = gap }
        }
        return best
    }

    /// `16:9` → 1.777…；写不对就是 nil。
    static func aspectValue(_ text: String) -> Double? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]), width > 0, height > 0 else { return nil }
        return width / height
    }

    // MARK: 成品

    /// 成品存成什么扩展名：先看服务器说的类型，再看地址的扩展名，都不认识按种类猜。
    static func fileExtension(contentType: String?, url: URL, kind: Kind) -> String {
        let byType = [
            "image/png": "png", "image/jpeg": "jpg", "image/webp": "webp", "video/mp4": "mp4", "video/quicktime": "mov",
            "audio/mpeg": "mp3", "audio/mp3": "mp3", "audio/wav": "wav", "audio/x-wav": "wav", "audio/wave": "wav", "audio/mp4": "m4a"
        ]
        if let type = contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased(), let known = byType[type] {
            return known
        }
        let fromURL = url.pathExtension.lowercased()
        if ["png", "jpg", "webp", "mp4", "mov", "mp3", "wav", "m4a"].contains(fromURL) { return fromURL }
        if fromURL == "jpeg" { return "jpg" }
        switch kind {
        case .image: return "png"
        case .imageToVideo, .textToVideo: return "mp4"
        case .music: return "mp3"
        case .soundEffect: return "wav"
        }
    }
}
