import Foundation
import ImageIO
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

    static func picks(_ args: AIToolArguments, kind: SkyStudioGeneration.Kind) throws -> (mode: String, files: [Pick]) {
        var picks: [Pick] = []
        func add(_ path: String, type: String, role: String) throws {
            let url = AIWorkspace.shared.resolve(path)
            guard FileManager.default.fileExists(atPath: url.path) else { throw AIToolError("There is no reference file at \(path).") }
            picks.append(Pick(type: type, file: url, role: role))
        }
        if let path = try args.string("image") { try add(path, type: "image", role: kind == .image ? "reference_image" : "first_frame") }
        if let path = try args.string("last_image") { try add(path, type: "image", role: "last_frame") }
        for (key, type) in [("reference_images", "image"), ("reference_videos", "video"), ("reference_audio", "audio")] {
            if let values = try args.array(key) {
                for value in values {
                    guard let path = value.stringValue, !path.isEmpty else { throw AIToolError("\(key) must contain file paths.") }
                    try add(path, type: type, role: "reference_\(type)")
                }
            }
        }
        let mode = try args.choice("input_mode", from: ["frames", "multimodal"]) ?? (picks.contains { $0.role.hasPrefix("reference_") } && kind.isVideo ? "multimodal" : "frames")
        if kind.isSound, !picks.isEmpty { throw AIToolError("Reference media apply only to image and video generation.") }
        if kind == .image {
            guard !picks.contains(where: { $0.type != "image" || $0.role == "last_frame" }) else { throw AIToolError("Image generation takes image references only.") }
            return ("images", picks)
        }
        if mode == "multimodal" {
            guard !picks.isEmpty, picks.allSatisfy({ $0.role.hasPrefix("reference_") }) else {
                throw AIToolError("Multimodal mode takes reference_images/reference_videos/reference_audio. Do not mix them with image/last_image.")
            }
        } else if kind.isVideo {
            guard !picks.contains(where: { $0.role.hasPrefix("reference_") }) else { throw AIToolError("Reference arrays require input_mode=multimodal.") }
            if kind == .imageToVideo, !picks.contains(where: { $0.role == "first_frame" }) { throw AIToolError("image is required for image_to_video in frames mode.") }
            if kind == .textToVideo, !picks.isEmpty { throw AIToolError("Use image_to_video for first/last frames.") }
            if picks.contains(where: { $0.role == "last_frame" }), !picks.contains(where: { $0.role == "first_frame" }) { throw AIToolError("last_image requires image.") }
        }
        return (mode, picks)
    }

    /// 调用者必须先 confirmReading；测量用于报价和提前说明限制，服务端还会探真实上传内容。
    static func measure(_ picked: (mode: String, files: [Pick]), project: VideoEditProject) async throws -> SkyStudioReferencePlan {
        var files: [SkyStudioReference] = []
        for pick in picked.files {
            let size = await MediaReadQueue.run(on: MediaReadQueue.analysis) {
                Result { ((try FileManager.default.attributesOfItem(atPath: pick.file.path))[.size] as? NSNumber)?.doubleValue ?? 0 }
            }
            let bytes = try size.get()
            guard bytes > 0 else { throw AIToolError("Reference file is empty: \(pick.file.lastPathComponent).") }
            var file = SkyStudioReference(type: pick.type, file: pick.file, role: pick.role, bytes: bytes)
            if pick.type == "video" {
                guard ["mp4", "mov"].contains(pick.file.pathExtension.lowercased()), let info = await project.mediaProbes.probeVideo(pick.file) else {
                    throw AIToolError("Video references must be readable MP4 or MOV files.")
                }
                file.duration = info.duration; file.width = Double(info.width); file.height = Double(info.height); file.fps = info.frameRate
            } else if pick.type == "audio" {
                guard ["mp3", "wav"].contains(pick.file.pathExtension.lowercased()), let duration = await project.mediaProbes.audioDuration(pick.file) else {
                    throw AIToolError("Audio references must be readable MP3 or WAV files.")
                }
                file.duration = duration
            } else {
                let dimensions: (Double, Double)? = await MediaReadQueue.run(on: MediaReadQueue.analysis) {
                    guard let source = CGImageSourceCreateWithURL(pick.file as CFURL, nil), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                          let width = properties[kCGImagePropertyPixelWidth] as? NSNumber, let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
                    let turned = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
                    return turned >= 5 ? (height.doubleValue, width.doubleValue) : (width.doubleValue, height.doubleValue)
                }
                guard let dimensions else {
                    throw AIToolError("Reference is not a readable image: \(pick.file.lastPathComponent).")
                }
                file.width = dimensions.0; file.height = dimensions.1
            }
            files.append(file)
        }
        return SkyStudioReferencePlan(mode: picked.mode, files: files)
    }

    static func upload(_ plan: SkyStudioReferencePlan, api: SkyStudioAPI, key: String,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> (inputs: [String: String], references: [JSONValue]) {
        var inputs: [String: String] = [:]
        var references: [JSONValue] = []
        for (index, file) in plan.files.enumerated() {
            try Task.checkCancellation()
            let prepared: SkyStudioGenerationFrame.Prepared?
            if file.type == "image" {
                let folder = SkyStudioGenerationRun.workFolder
                let result = await MediaReadQueue.run(on: MediaReadQueue.analysis) { Result { try SkyStudioGenerationFrame.prepare(file.file, workFolder: folder) } }
                prepared = try result.get()
            } else { prepared = nil }
            defer { prepared?.cleanUp() }
            let type = prepared?.contentType ?? (file.type == "video" ? (file.file.pathExtension.lowercased() == "mov" ? "video/quicktime" : "video/mp4")
                : file.file.pathExtension.lowercased() == "mp3" ? "audio/mpeg" : "audio/wav")
            let count = Double(plan.files.count)
            let url = try await api.upload(fileURL: prepared?.url ?? file.file, contentType: type, purpose: file.type, key: key) { fraction in
                progress((Double(index) + fraction) / count)
            }
            if file.role == "first_frame" { inputs["image_url"] = url.absoluteString }
            else if file.role == "last_frame" { inputs["last_frame_url"] = url.absoluteString }
            else { references.append(["type": .string(file.type), "url": .string(url.absoluteString)]) }
        }
        return (inputs, references)
    }
}
