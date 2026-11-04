import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// 制作锚点只证明 current render 的首尾原图来自哪个已绑定输出的哪一侧用窗。
// source_clip_uuid 仅留来源记录；权威是 from_shot_id 的当前源身份/用窗，不重建历史渲染、不认证 final composite。
// 调用方先核对 PNG 读取权限，所有 stat 操作在 MediaReadQueue 上，await 返回后再做工程 CAS。
enum AIFilmProductionAnchorReader {
    typealias Anchor = FilmProductionState.SourceAnchor
    typealias Shot = AIFilmProductionGraph.Shot

    static func read(_ input: JSONValue, shot: Shot, graph: [Shot], state: TimelineState, allowedImages: Set<URL> = []) throws -> [Anchor] {
        guard let values = input.arrayValue, values.count <= 2 else { throw error("Expected at most one first and one last anchor.") }
        let anchors = try values.map { try readOne($0, shot: shot, graph: graph, state: state, allowedImages: allowedImages) }
        guard Set(anchors.map(\.role)).count == anchors.count else { throw error("Each input role has at most one source anchor.") }
        return anchors // 初次无输出时允许空；是否需要补锚点由制作摘要给出 needs_review，避免规划循环依赖。
    }

    /// 从工程读出后、quote/submit 使用前重新核对；旧工程声明不能绕过公开严格入口或磁盘身份。
    static func validate(_ anchors: [Anchor], shot: Shot, graph: [Shot], state: TimelineState, allowedImages: Set<URL> = []) throws {
        let rebuilt = try read(.array(try anchors.map(json)), shot: shot, graph: graph, state: state, allowedImages: allowedImages)
        guard rebuilt == anchors else { throw error("Saved anchor evidence is stale or has an invalid fingerprint; refresh it from the current bound output.") }
    }

    static func json(_ anchor: Anchor) throws -> JSONValue {
        guard anchor.sourceFrame.count <= 32_768 else { throw error("Source-frame evidence is too large.") }
        return ["role": .string(anchor.role.rawValue), "source_edge": .string(anchor.sourceEdge.rawValue),
                "from_shot_id": .string(anchor.fromShotID), "asset_url": .string(anchor.assetURL.absoluteString),
                "source_frame": try SourceFrameReader.read(JSONDecoder().decode(JSONValue.self, from: anchor.sourceFrame)).json]
    }

    private static func readOne(_ input: JSONValue, shot: Shot, graph: [Shot], state: TimelineState, allowedImages: Set<URL>) throws -> Anchor {
        let path = "production.anchors"
        let value = try SkyStudioFilmReader.object(input, keys: ["role", "source_edge", "from_shot_id", "asset_url", "source_frame"], at: path)
        guard let role = value["role"]?.stringValue.flatMap(Anchor.Role.init(rawValue:)),
              let edge = value["source_edge"]?.stringValue.flatMap(Anchor.SourceEdge.init(rawValue:)),
              let from = value["from_shot_id"]?.stringValue,
              let sourceShot = graph.first(where: { $0.film.shot.id == from }),
              allowed(role: role, edge: edge, from: from, for: shot) else {
            throw error("first uses previous.last_used or current.first_used; last uses current.last_used or next.first_used.")
        }
        guard let asset = value["asset_url"]?.stringValue, let url = URL(string: asset),
              shot.render.inputs[role == .first ? "image_url" : "last_frame_url"] == .string(asset) else {
            throw error("asset_url must exactly match the current render's corresponding first/last image input.")
        }
        // 复用官方原创图片规则；账户归属和上传字节仍由服务器确认，不把 generated URL 冒充 originals。
        try SkyStudioFilmInputs.validate(["image_url": .string(asset)], kind: "image", params: [:], at: path + ".asset_url")
        let evidence = try SourceFrameReader.read(value["source_frame"] ?? .null, at: path + ".source_frame")
        guard allowedImages.contains(evidence.imageFile) else {
            throw error("The source PNG has not been approved for reading in this project; inspect and authorize that file first.")
        }
        guard let output = sourceShot.record.outputClipID, let clip = state.clip(with: output),
              !clip.isStillImage, !clip.needsStillConversion else {
            throw error("from_shot_id needs a current bound video output before it can supply a native frame anchor.")
        }
        let source = try AIFilmProductionSnapshot.source(output, state: state, picture: true)
        guard let identity = source["source"] else { throw error("The bound output has no source identity.") }
        let bound = SourceFrameReader.BoundSource(identity: identity, start: clip.sourceStart, duration: clip.sourceDuration,
            speed: clip.speed, timelineStart: clip.timelineStart, fps: state.frameRate.fps,
            sourceHalfFrame: KeyframeTrack.sourceTolerance(frameRate: state.frameRate, speed: clip.speed))
        try SourceFrameReader.validate(evidence, against: bound, atEnd: edge == .lastUsed, at: path + ".source_frame")
        try SourceFrameReader.validateFiles(evidence, at: path + ".source_frame")
        let fingerprint = AIFilmProductionSnapshot.fingerprint([
            "role": .string(role.rawValue), "source_edge": .string(edge.rawValue), "from_shot_id": .string(from),
            "asset_url": .string(asset), "source_frame": evidence.json, "source": identity,
            "source_in": .number(clip.sourceStart), "source_duration": .number(clip.sourceDuration),
            "speed": .number(clip.speed), "timeline_start": .number(clip.timelineStart), "project_frame_rate": .number(Double(state.frameRate.fps))
        ])
        return Anchor(role: role, sourceEdge: edge, fromShotID: from, assetURL: url,
                      sourceFrame: try evidence.json.encodedData(), fingerprint: fingerprint)
    }

    static func allowed(role: Anchor.Role, edge: Anchor.SourceEdge, from: String, for shot: Shot) -> Bool {
        switch (role, edge) {
        case (.first, .lastUsed): return from == shot.film.previous?.shotID
        case (.first, .firstUsed), (.last, .lastUsed): return from == shot.film.shot.id
        case (.last, .firstUsed): return from == shot.film.next?.shotID
        }
    }

    private static func error(_ message: String) -> SkyStudioFilmError {
        SkyStudioFilmReader.error("production.anchors", message)
    }
}
