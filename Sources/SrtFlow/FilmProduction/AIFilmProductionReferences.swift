import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// 已验证 native anchor 与本次真实引用计划的闭环；只读值，不 stat、不上传，也不自造图片来源。
// runtime 的 referenceSources 来自 OfficialPreparation.sources，prepared token 另行保证它就是已上传的原文件。
enum AIFilmProductionReferences {
    static func validate(_ anchors: [FilmProductionState.SourceAnchor], sources: JSONValue) throws -> JSONValue {
        guard let references = sources.arrayValue else {
            throw SkyStudioFilmReader.error("production.anchors", "Actual prepared reference sources are required.")
        }
        return .array(try anchors.map { anchor in
            let role = anchor.role == .first ? "first_frame" : "last_frame"
            let matching = references.filter { $0["role"]?.stringValue == role }
            let evidence = try SourceFrameReader.read(JSONDecoder().decode(JSONValue.self, from: anchor.sourceFrame))
            guard matching.count == 1, matching[0]["type"] == "image", matching[0]["file"] == evidence.imageIdentity else {
                throw SkyStudioFilmReader.error("production.anchors", "The native anchor PNG must be the exact current " + role + " reference file prepared for this generation.")
            }
            return ["role": .string(role), "file": evidence.imageIdentity, "asset_url": .string(anchor.assetURL.absoluteString)]
        })
    }
}
