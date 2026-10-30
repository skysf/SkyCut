import Foundation
import SrtFlowMCPKit

// MARK: - 一组参考素材的本机测量与模型限制（纯值）
// 管什么：数量、文件大小、长度、组合照 /models 检查；报价用测到的数量和视频总长。
// 不管什么：读 / 上传文件，服务端的实际探测与扣费；不裁素材、不丢引用来凑上限。
struct SkyStudioReference: Equatable, Sendable {
    var type: String
    var file: URL
    var role: String
    var bytes: Double
    var duration: Double? = nil
    var width: Double? = nil
    var height: Double? = nil
    var fps: Double? = nil
}

struct SkyStudioReferencePlan: Equatable, Sendable {
    var mode: String
    var files: [SkyStudioReference]
    var uploads: Bool { !files.isEmpty }
    var firstFrame: URL? { files.first { $0.role == "first_frame" }?.file }
    var videoSeconds: Double { files.filter { $0.type == "video" }.reduce(0) { $0 + ($1.duration ?? 0) } }
    func count(_ type: String) -> Int { files.filter { $0.type == type }.count }

    var quoteParams: [String: JSONValue] {
        var value: [String: JSONValue] = ["reference_image_count": .number(Double(count("image")))]
        if mode == "multimodal" {
            value["reference_video_count"] = .number(Double(count("video")))
            value["reference_video_seconds"] = .number(videoSeconds)
        }
        return value
    }

    func problem(model: SkyStudioModel) -> String? {
        guard let limits = model.referenceLimits(mode: mode) else {
            // 旧服务器只支持一张首帧 / 图片参考；不能冒充已有多模态接口。
            return mode == "multimodal" || files.count > 1 ? "This server catalog does not offer these reference inputs for \(model.title)." : nil
        }
        for (type, field) in [("image", "max_images"), ("video", "max_videos"), ("audio", "max_audio")] {
            if let max = limits[field]?.intValue, count(type) > max { return "\(model.title) accepts at most \(max) \(type) references in \(mode) mode." }
        }
        if let max = limits["max_total_files"]?.intValue, files.count > max { return "\(model.title) accepts at most \(max) reference files in total." }
        if limits["requires_reference"]?.boolValue == true, files.isEmpty { return "\(mode) mode requires a reference file." }
        if limits["audio_requires_visual"]?.boolValue == true, count("audio") > 0, count("image") + count("video") == 0 {
            return "\(model.title) requires an image or video together with audio references."
        }
        let tolerance = limits["duration_tolerance_seconds"]?.doubleValue ?? 0
        for file in files {
            if let max = limits["max_\(file.type)_bytes"]?.doubleValue, file.bytes > max { return "\(file.file.lastPathComponent) exceeds \(model.title)'s \(file.type) size limit (\(Int(max)) bytes)." }
            if let seconds = file.duration {
                if let min = limits["min_\(file.type)_clip_seconds"]?.doubleValue, seconds < min { return "\(file.file.lastPathComponent) must be at least \(min) seconds for \(model.title)." }
                if let max = limits["max_\(file.type)_clip_seconds"]?.doubleValue, seconds > max + tolerance { return "\(file.file.lastPathComponent) exceeds \(model.title)'s \(max)-second reference limit." }
            }
            if let width = file.width, let height = file.height, height > 0 {
                if let minSide = limits["media_dimensions"]?["min_side"]?.doubleValue, min(width, height) < minSide { return "\(file.file.lastPathComponent) is too small for \(model.title)." }
                if let maxSide = limits["media_dimensions"]?["max_side"]?.doubleValue, max(width, height) > maxSide { return "\(file.file.lastPathComponent) is too large for \(model.title)." }
                let ratio = width / height
                let exclusive = file.type == "image" && limits["media_aspect_ratio"]?["image_bounds_exclusive"]?.boolValue == true
                if let low = limits["media_aspect_ratio"]?["min"]?.doubleValue, exclusive ? ratio <= low : ratio < low { return "\(file.file.lastPathComponent) is too tall for \(model.title)." }
                if let high = limits["media_aspect_ratio"]?["max"]?.doubleValue, exclusive ? ratio >= high : ratio > high { return "\(file.file.lastPathComponent) is too wide for \(model.title)." }
                if file.type == "video", let low = limits["video_pixel_count"]?["min"]?.doubleValue, width * height < low { return "Reference video has too few pixels for \(model.title)." }
                if file.type == "video", let high = limits["video_pixel_count"]?["max"]?.doubleValue, width * height > high { return "Reference video has too many pixels for \(model.title)." }
            }
            if file.type == "video", let fps = file.fps {
                if let min = limits["video_fps"]?["min"]?.doubleValue, fps < min { return "Reference video frame rate is too low for \(model.title)." }
                if let max = limits["video_fps"]?["max"]?.doubleValue, fps > max { return "Reference video frame rate is too high for \(model.title)." }
            }
        }
        for type in ["video", "audio"] {
            let total = files.filter { $0.type == type }.reduce(0) { $0 + ($1.duration ?? 0) }
            if let max = limits["max_total_\(type)_seconds"]?.doubleValue, total > max + tolerance { return "\(model.title) accepts at most \(max) seconds of \(type) references in total." }
        }
        let allBytes = files.reduce(0) { $0 + $1.bytes }
        if let max = limits["max_total_bytes"]?.doubleValue, allBytes > max { return "The reference files exceed \(model.title)'s total size limit." }
        let videoBytes = files.filter { $0.type == "video" }.reduce(0) { $0 + $1.bytes }
        if let max = limits["max_total_video_bytes_exclusive"]?.doubleValue, videoBytes >= max { return "The reference videos must total less than \(Int(max)) bytes for \(model.title)." }
        return nil
    }
}
