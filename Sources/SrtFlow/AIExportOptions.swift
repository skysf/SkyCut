import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MCP 剪辑导出的单次设置；复用文件工具的质量映射，不保存用户偏好，不修改工程帧率/画布。
enum AIExportOptions {
    struct Choice {
        var settings: VideoEncodeSettings
        var preset: String
    }

    static func parse(_ args: AIToolArguments, base: VideoEncodeSettings) throws -> Choice {
        let preset = try args.choice("preset", from: ["final", "quick_review"]) ?? "final"
        var settings = base
        if preset == "quick_review" {
            settings = AIEncodeOptions.apply(.init(quality: "small", fast: true, resolution: .hd720), to: settings)
            settings.preset = .veryfast
            settings.audio = AudioHandling(mode: .aac, kbps: 128)
            settings.fastStart = true
        }
        if let quality = try args.choice("quality", from: MCPVocabulary.encodeQualities) {
            settings = AIEncodeOptions.apply(.init(quality: quality), to: settings)
        }
        if let encoder = try args.choice("encoder", from: ["software", "hardware"]) {
            settings.encoder = encoder == "hardware" ? .hardware : .softwareCRF
        }
        if let resolution = try args.choice("resolution", from: MCPVocabulary.resolutions) {
            settings.resolution = AIEncodeOptions.resolution(resolution)
        }
        return Choice(settings: settings, preset: preset)
    }

    /// 从交给生产导出器的同一份设置报实际参数；时间线帧率不是 settings.frameRate 的上限。
    static func describe(_ choice: Choice, frameRate: ProjectFrameRate) -> JSONValue {
        let s = choice.settings
        var result: [String: JSONValue] = [
            "preset": .string(choice.preset), "encoder": .string(s.encoder == .hardware ? "hardware" : "software"),
            "video_codec": .string(s.encoder == .hardware ? "h264_videotoolbox" : "libx264"),
            "pixel_format": "yuv420p", "frame_rate": .number(Double(frameRate.fps)),
            "resolution_limit": .string(s.resolution.maxShortSide.map { "\($0)p" } ?? "original"),
            "audio_codec": "aac", "audio_bitrate_kbps": .number(Double(s.audio.kbps)),
            "fast_start": .bool(s.fastStart), "strip_metadata": .bool(s.stripMetadata)
        ]
        if s.encoder == .hardware { result["hardware_quality"] = .number(Double(s.hardwareQuality)) }
        else { result["crf"] = .number(Double(s.crf)); result["software_preset"] = .string(s.preset.rawValue) }
        return .object(result)
    }
}
