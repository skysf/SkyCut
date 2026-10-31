import Foundation
import ImageIO
import UniformTypeIdentifiers
import SrtFlowMCPKit

// MARK: - generate_media 的参考素材：解析路径、获准后测量、按顺序上传
// 管什么：所有引用都过同一份文件读取授权；不在这里选模型、裁短片子或改写提示词。
@MainActor
enum SkyStudioReferenceFiles {
    struct Pick: Sendable {
        var type: String
        var file: URL
        var role: String
    }

    struct Picks { var mode: String; var files: [Pick]; var webURL: String? = nil }

    static func picks(_ args: AIToolArguments, kind: SkyStudioGeneration.Kind) throws -> Picks {
        var picks: [Pick] = []
        func add(_ path: String, type: String, role: String) throws {
            let url = AIWorkspace.shared.resolve(path)
            guard FileManager.default.fileExists(atPath: url.path) else { throw AIToolError("There is no reference file at \(path).") }
            picks.append(Pick(type: type, file: url, role: role))
        }
        let removal = try args.string("operation") == "remove_background" || args.string("model") == "ideogram-remove-background"
        if let path = try args.string("image") { try add(path, type: "image", role: kind == .lipsync || removal ? "image_url" : kind == .image ? "reference_image" : "first_frame") }
        if let path = try args.string("last_image") { try add(path, type: "image", role: "last_frame") }
        for type in ["video", "audio"] {
            if let path = try args.string(type) { try add(path, type: type, role: "\(type)_url") }
        }
        if let path = try args.string("document") { try add(path, type: "document", role: "file_url") }
        let webURL = try args.string("web_url")
        if let webURL, !["http", "https"].contains(URL(string: webURL)?.scheme?.lowercased() ?? "") || URL(string: webURL)?.host == nil {
            throw AIToolError("web_url must be a public HTTP(S) page without login.")
        }
        for (key, type) in [("reference_images", "image"), ("reference_videos", "video"), ("reference_audio", "audio")] {
            if let values = try args.array(key) {
                for value in values {
                    guard let path = value.stringValue, !path.isEmpty else { throw AIToolError("\(key) must contain file paths.") }
                    try add(path, type: type, role: "reference_\(type)")
                }
            }
        }
        if kind == .lipsync {
            guard webURL == nil, picks.allSatisfy({ ["image_url", "video_url", "audio_url"].contains($0.role) }),
                  picks.count == 2, picks.contains(where: { $0.role == "audio_url" }) else { throw AIToolError("lipsync requires exactly one image or video and one audio file; choose a matching model from /models.") }
            return Picks(mode: "lipsync", files: picks)
        }
        guard !picks.contains(where: { ["video_url", "audio_url"].contains($0.role) }) else { throw AIToolError("video/audio inputs require kind=lipsync; use reference arrays for multimodal video.") }
        let mode = try args.choice("input_mode", from: ["frames", "multimodal"]) ?? ((picks.contains { $0.role.hasPrefix("reference_") || $0.type == "document" } || webURL != nil) && kind.isVideo ? "multimodal" : "frames")
        if kind.isSound, !picks.isEmpty { throw AIToolError("Reference media apply only to image and video generation.") }
        if kind == .image {
            guard !picks.contains(where: { $0.type != "image" || $0.role == "last_frame" }) else { throw AIToolError("Image generation takes image references only.") }
            guard webURL == nil else { throw AIToolError("Image operations do not accept webpage inputs.") }
            return Picks(mode: "images", files: picks)
        }
        if mode == "multimodal" {
            guard (!picks.isEmpty || webURL != nil), picks.allSatisfy({ $0.role.hasPrefix("reference_") || $0.role == "file_url" }) else {
                throw AIToolError("Multimodal mode takes reference_images/reference_videos/reference_audio. Do not mix them with image/last_image.")
            }
        } else if kind.isVideo {
            guard !picks.contains(where: { $0.role.hasPrefix("reference_") }) else { throw AIToolError("Reference arrays require input_mode=multimodal.") }
            if kind == .imageToVideo, !picks.contains(where: { $0.role == "first_frame" }) { throw AIToolError("image is required for image_to_video in frames mode.") }
            if kind == .textToVideo, !picks.isEmpty { throw AIToolError("Use image_to_video for first/last frames.") }
            if picks.contains(where: { $0.role == "last_frame" }), !picks.contains(where: { $0.role == "first_frame" }) { throw AIToolError("last_image requires image.") }
        }
        return Picks(mode: mode, files: picks, webURL: webURL)
    }

    /// 调用者必须先 confirmReading；测量用于报价和提前说明限制，服务端还会探真实上传内容。
    static func measure(_ picked: Picks, project: VideoEditProject) async throws -> SkyStudioReferencePlan {
        var files: [SkyStudioReference] = []
        for pick in picked.files {
            let size = await MediaReadQueue.run(on: MediaReadQueue.analysis) {
                Result { ((try FileManager.default.attributesOfItem(atPath: pick.file.path))[.size] as? NSNumber)?.doubleValue ?? 0 }
            }
            let bytes = try size.get()
            guard bytes > 0 else { throw AIToolError("Reference file is empty: \(pick.file.lastPathComponent).") }
            var file = SkyStudioReference(type: pick.type, file: pick.file, role: pick.role, bytes: bytes)
            if pick.type == "video" {
                guard ["mp4", "mov", "webm"].contains(pick.file.pathExtension.lowercased()), let info = await project.mediaProbes.probeVideo(pick.file) else {
                    throw AIToolError("Video input must be a readable MP4, MOV or WebM file; the model catalog restricts accepted formats.")
                }
                file.duration = info.duration; file.width = Double(info.width); file.height = Double(info.height); file.fps = info.frameRate
                file.contentType = pick.file.pathExtension.lowercased() == "webm" ? "video/webm" : pick.file.pathExtension.lowercased() == "mov" ? "video/quicktime" : "video/mp4"
            } else if pick.type == "audio" {
                guard ["mp3", "wav"].contains(pick.file.pathExtension.lowercased()), let duration = await project.mediaProbes.audioDuration(pick.file) else {
                    throw AIToolError("Audio references must be readable MP3 or WAV files.")
                }
                file.duration = duration
                file.contentType = pick.file.pathExtension.lowercased() == "mp3" ? "audio/mpeg" : "audio/wav"
            } else if pick.type == "document" {
                file.contentType = UTType(filenameExtension: pick.file.pathExtension)?.preferredMIMEType
                if pick.file.pathExtension.lowercased() == "pdf" {
                    file.pages = await MediaReadQueue.run(on: MediaReadQueue.analysis) { CGPDFDocument(pick.file as CFURL)?.numberOfPages }
                }
            } else {
                let measured: SkyStudioReference? = await MediaReadQueue.run(on: MediaReadQueue.analysis) {
                    guard let source = CGImageSourceCreateWithURL(pick.file as CFURL, nil), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                          let width = properties[kCGImagePropertyPixelWidth] as? NSNumber, let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
                    let turned = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
                    var image = SkyStudioReference(type: "image", file: pick.file, role: pick.role, bytes: bytes)
                    image.width = turned >= 5 ? height.doubleValue : width.doubleValue
                    image.height = turned >= 5 ? width.doubleValue : height.doubleValue
                    image.contentType = (CGImageSourceGetType(source) as String?).flatMap { UTType($0)?.preferredMIMEType }
                    image.imageCount = CGImageSourceGetCount(source)
                    image.hasTransparency = StillImageClipFactory.usesTransparency(pick.file)
                    return image
                }
                guard let measured else {
                    throw AIToolError("Reference is not a readable image: \(pick.file.lastPathComponent).")
                }
                file = measured
            }
            files.append(file)
        }
        return SkyStudioReferencePlan(mode: picked.mode, files: files, webURL: picked.webURL)
    }

    static func upload(_ plan: SkyStudioReferencePlan, model: SkyStudioModel, api: SkyStudioAPI, key: String,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> (inputs: [String: String], references: [JSONValue]) {
        var inputs: [String: String] = [:]
        if let webURL = plan.webURL { inputs["web_url"] = webURL }
        var references: [JSONValue] = []
        for (index, file) in plan.files.enumerated() {
            try Task.checkCancellation()
            guard let type = file.contentType else { throw AIToolError("Cannot determine input format: \(file.file.lastPathComponent).") }
            let purpose = model.inputs[file.role]?["upload_purpose"]?.stringValue ?? file.type
            let count = Double(plan.files.count)
            let url = try await api.upload(fileURL: file.file, contentType: type, purpose: purpose, key: key) { fraction in
                progress((Double(index) + fraction) / count)
            }
            if file.role == "first_frame" { inputs["image_url"] = url.absoluteString }
            else if file.role == "last_frame" { inputs["last_frame_url"] = url.absoluteString }
            else if file.role.hasSuffix("_url") { inputs[file.role] = url.absoluteString }
            else { references.append(["type": .string(file.type), "url": .string(url.absoluteString)]) }
        }
        return (inputs, references)
    }
}
