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
    var contentType: String? = nil
    var hasTransparency = false
    var imageCount = 1
    var pages: Int? = nil
}

struct SkyStudioReferencePlan: Equatable, Sendable {
    var mode: String
    var files: [SkyStudioReference]
    var webURL: String? = nil
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
        if !model.choices("mode").isEmpty, !model.choices("mode").contains(mode) { return "\(model.title) requires input_mode=\(model.choices("mode").joined(separator: ", "))." }
        guard let limits = model.referenceLimits(mode: mode) else {
            // 旧服务器只支持一张首帧 / 图片参考；不能冒充已有多模态接口。
            return mode == "multimodal" || files.count > 1 ? "This server catalog does not offer these reference inputs for \(model.title)." : nil
        }
        for (field, value) in model.inputs where value["required"]?.boolValue == true {
            if !files.contains(where: { $0.role == field }) { return "\(model.title) requires \(field.replacingOccurrences(of: "_url", with: "")) and its other listed inputs." }
        }
        if model.kind == "lipsync" || model.operation == "remove_background" {
            let allowed = Set(model.inputs.keys)
            if files.contains(where: { !allowed.contains($0.role) }) || webURL != nil { return "This model accepts only its listed input files." }
        }
        for (type, field) in [("image", "max_images"), ("video", "max_videos"), ("audio", "max_audio"), ("document", "max_documents")] {
            if let max = limits[field]?.intValue, count(type) > max { return "\(model.title) accepts at most \(max) \(type) references in \(mode) mode." }
        }
        if webURL != nil, (limits["max_web_urls"]?.intValue ?? 0) == 0 { return "This model does not accept a webpage." }
        if webURL != nil, count("document") > 0, limits["document_and_web_mutually_exclusive"]?.boolValue == true { return "Choose a document or webpage, not both." }
        if let max = limits["max_total_files"]?.intValue, files.count + (webURL == nil ? 0 : 1) > max { return "\(model.title) accepts at most \(max) reference files in total." }
        if limits["requires_reference"]?.boolValue == true, files.isEmpty, webURL == nil { return "\(mode) mode requires a reference file." }
        if limits["audio_requires_visual"]?.boolValue == true, count("audio") > 0, count("image") + count("video") == 0 {
            return "\(model.title) requires an image or video together with audio references."
        }
        let tolerance = limits["duration_tolerance_seconds"]?.doubleValue ?? 0
        for file in files {
            if file.bytes <= 0 { return "Reference file is empty." }
            let mimes = limits["\(file.type)_mime_types"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if !mimes.isEmpty, let mime = file.contentType, !mimes.contains(mime) { return "\(file.file.lastPathComponent) has an unsupported format for \(model.title): \(mime)." }
            if file.type == "document" {
                let extensions = limits["document_extensions"]?.arrayValue?.compactMap(\.stringValue) ?? []
                if extensions.isEmpty || !extensions.contains(file.file.pathExtension.lowercased()) { return "This document format is not offered by the model." }
                if let pages = file.pages, let max = limits["max_document_pages"]?.intValue, pages > max { return "The document exceeds \(max) pages." }
            }
            if file.type == "image" {
                if limits["transparent_images"] == false && file.hasTransparency { return "\(model.title) does not accept transparent images." }
                if limits["still_images_only"] == true && file.imageCount != 1 { return "This model accepts still images only." }
                if let width = file.width, let height = file.height, let max = limits["max_image_pixels"]?.doubleValue, width * height > max { return "Image exceeds \(Int(max)) pixels." }
            }
            if let max = limits["max_\(file.type)_bytes"]?.doubleValue, file.bytes > max { return "\(file.file.lastPathComponent) exceeds \(model.title)'s \(file.type) size limit (\(Int(max)) bytes)." }
            if let seconds = file.duration {
                if let min = (limits["min_\(file.type)_clip_seconds"] ?? limits["min_\(file.type)_seconds"])?.doubleValue, seconds < min { return "\(file.file.lastPathComponent) must be at least \(min) seconds for \(model.title)." }
                if let max = (limits["max_\(file.type)_clip_seconds"] ?? limits["max_\(file.type)_seconds"])?.doubleValue, seconds > max + tolerance { return "\(file.file.lastPathComponent) exceeds \(model.title)'s \(max)-second reference limit." }
            }
            if let width = file.width, let height = file.height, height > 0 {
                let dimensions = limits["\(file.type)_dimensions"] ?? limits["media_dimensions"]
                if let minSide = dimensions?["min_side"]?.doubleValue, min(width, height) < minSide { return "\(file.file.lastPathComponent) is too small for \(model.title)." }
                if let maxSide = dimensions?["max_side"]?.doubleValue, max(width, height) > maxSide { return "\(file.file.lastPathComponent) is too large for \(model.title)." }
                let ratio = width / height
                let exclusive = file.type == "image" && limits["media_aspect_ratio"]?["image_bounds_exclusive"]?.boolValue == true
                if let low = limits["media_aspect_ratio"]?["min"]?.doubleValue, exclusive ? ratio <= low : ratio < low { return "\(file.file.lastPathComponent) is too tall for \(model.title)." }
                if let high = limits["media_aspect_ratio"]?["max"]?.doubleValue, exclusive ? ratio >= high : ratio > high { return "\(file.file.lastPathComponent) is too wide for \(model.title)." }
                if let low = limits["min_\(file.type)_aspect_ratio"]?.doubleValue, ratio < low { return "Image aspect ratio is below \(low)." }
                if let high = limits["max_\(file.type)_aspect_ratio"]?.doubleValue, ratio > high { return "Image aspect ratio is above \(high)." }
                if file.type == "video", let low = limits["video_pixel_count"]?["min"]?.doubleValue, width * height < low { return "Reference video has too few pixels for \(model.title)." }
                if file.type == "video", let high = limits["video_pixel_count"]?["max"]?.doubleValue, width * height > high { return "Reference video has too many pixels for \(model.title)." }
            }
            if file.type == "video", let fps = file.fps {
                if let min = limits["video_fps"]?["min"]?.doubleValue ?? limits["min_video_fps"]?.doubleValue, fps < min { return "Reference video frame rate is too low for \(model.title)." }
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
