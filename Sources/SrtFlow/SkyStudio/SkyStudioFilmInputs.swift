import Foundation
import SrtFlowMCPKit

// 官方无素材请求只允许本账号上传的原创图片。这里只检查公开输入形状，归属 / 字节 / 模型能力仍由服务器核对。
// 不下载引用、不猜账户、不把 generated URL 改装成 uploads，也不处理私有来源。
enum SkyStudioFilmInputs {
    static func validate(_ inputs: [String: JSONValue], kind: String, params: [String: JSONValue], at path: String = "inputs") throws {
        _ = try SkyStudioFilmReader.object(.object(inputs), keys: ["image_url", "last_frame_url", "references"], at: path)
        guard SkyStudioFilm.Render.Kind(rawValue: kind) != nil else {
            throw SkyStudioFilmReader.error("kind", "Official shots accept image, text_to_video or image_to_video.")
        }
        let first = try image(inputs["image_url"], at: path + ".image_url")
        let last = try image(inputs["last_frame_url"], at: path + ".last_frame_url")
        let references = try references(inputs["references"], at: path + ".references")
        let mode = params["mode"]?.stringValue ?? "frames"
        let count: Int
        if kind == "image" {
            guard !last else { throw SkyStudioFilmReader.error(path, "Image generation has no last frame.") }
            count = references + (first ? 1 : 0)
        } else if mode == "frames" {
            guard references == 0, !last || first,
                  kind != "image_to_video" || first, kind != "text_to_video" || (!first && !last) else {
                throw SkyStudioFilmReader.error(path, "Use image_to_video with its first frame; last frame requires first and reference arrays require multimodal mode.")
            }
            count = 0 // 服务端 reference_image_count 只统计多参考；首尾帧角色单独记入 pin。
        } else if mode == "multimodal" {
            guard !first && !last && references > 0 else {
                throw SkyStudioFilmReader.error(path, "Multimodal images cannot be combined with first/last frames and must not be empty.")
            }
            count = references
        } else {
            throw SkyStudioFilmReader.error("params.mode", "Use frames or multimodal for an official video shot.")
        }
        for name in ["reference_video_count", "reference_video_seconds"] {
            if let value = params[name], value != .null, value.doubleValue != 0 {
                throw SkyStudioFilmReader.error("params." + name, "Official no-footage shots cannot use video references.")
            }
        }
        if let value = params["reference_image_count"], value != .null, value.doubleValue != Double(count) {
            throw SkyStudioFilmReader.error("params.reference_image_count", "The count must match actual image assets, not future uploads.")
        }
    }

    @discardableResult
    private static func image(_ value: JSONValue?, at path: String) throws -> Bool {
        guard let value, value != .null else { return false }
        guard let text = value.stringValue, let u = URLComponents(string: text), u.scheme == "https",
              u.host?.isEmpty == false, u.user == nil, u.password == nil, u.query == nil, u.fragment == nil,
              u.path.hasPrefix("/originals/"), !u.path.contains(".."), !u.path.contains("\\"),
              u.path.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw SkyStudioFilmReader.error(path, "Use a durable original image file_url from this account's /uploads, without credentials, queries or fragments.")
        }
        let pieces = u.path.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count >= 4, !pieces[2].isEmpty, pieces.dropFirst(3).contains(where: { !$0.isEmpty }) else {
            throw SkyStudioFilmReader.error(path, "Use an original image file_url returned by /uploads.")
        }
        return true
    }

    private static func references(_ value: JSONValue?, at path: String) throws -> Int {
        guard let value, value != .null else { return 0 }
        guard let list = value.arrayValue else { throw SkyStudioFilmReader.error(path, "Expected an ordered image-reference array.") }
        for (index, item) in list.enumerated() {
            let p = path + "[\(index)]"
            let o = try SkyStudioFilmReader.object(item, keys: ["type", "url"], at: p)
            guard o["type"] == "image", try image(o["url"], at: p + ".url") else {
                throw SkyStudioFilmReader.error(p, "Official no-footage references must be original images.")
            }
        }
        return list.count
    }
}
