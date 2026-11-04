import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// 制作记录的公开 JSON 回读形状；只展开通过唯一 DTO 入口核对过的故事，不输出不透明 Data 或收费凭据。
// plan 可按原样用于 save_project.production；revision/派生 readiness/expected_snapshots 在外层，不能混进作者输入。
enum AIFilmProductionJSON {
    typealias Plan = FilmProductionState

    static func plan(_ value: Plan, graph: [AIFilmProductionGraph.Shot], ids: AIShortIDs) throws -> JSONValue {
        ["story": .string(value.story), "shots": .array(try graph.map { shot in
            var result: [String: JSONValue] = ["film": shot.film.json, "render": shot.render.json,
                "clip_id": shot.record.outputClipID.map { identifier($0, ids: ids) } ?? .null,
                "output_binding": shot.record.boundSourceFingerprint.map(JSONValue.string) ?? .null,
                "anchors": .array(try shot.record.anchors.map(AIFilmProductionAnchorReader.json))]
            result["output_review"] = shot.record.review.map(review) ?? .null
            return .object(result)
        }), "sound_cues": .array(value.soundCues.map { cue($0, ids: ids) })]
    }

    static func review(_ value: Plan.OutputReview) -> JSONValue {
        ["source_times": .array(value.sourceTimes.map(JSONValue.number)), "source_snapshot": .string(value.sourceFingerprint),
         "notes": .string(value.notes), "action_samples": .array(value.actionSamples.map { action in
            ["action_id": .string(action.actionID), "source_times": .array(action.sourceTimes.map(JSONValue.number)), "notes": .string(action.notes)]
         }), "previous": value.previous.map(seam) ?? .null, "next": value.next.map(seam) ?? .null]
    }

    private static func seam(_ value: Plan.SeamReview) -> JSONValue {
        ["snapshot": .string(value.fingerprint), "timeline_times": .array(value.timelineTimes.map(JSONValue.number)), "notes": .string(value.notes)]
    }

    private static func cue(_ value: Plan.SoundCue, ids: AIShortIDs) -> JSONValue {
        var result: [String: JSONValue] = [
            "id": .string(value.id), "shot_ids": .array(value.shotIDs.map(JSONValue.string)), "layer": .string(value.layer.rawValue),
            "purpose": .string(value.purpose), "at": .number(value.at), "duration": .number(value.duration),
            "action_id": value.actionID.map(JSONValue.string) ?? .null,
            "audio_clip_id": value.audioClipID.map { identifier($0, ids: ids) } ?? .null,
            "silence_reason": value.silenceReason.map(JSONValue.string) ?? .null,
            "recovery_at": value.recoveryAt.map(JSONValue.number) ?? .null
        ]
        result["alignment"] = value.alignment.map { alignment in
            ["snapshot": .string(alignment.fingerprint), "measured_note": alignment.measuredNote.map(JSONValue.string) ?? .null,
             "listened_note": alignment.listenedNote.map(JSONValue.string) ?? .null]
        } ?? .null
        return .object(result)
    }

    private static func identifier(_ id: UUID, ids: AIShortIDs) -> JSONValue {
        let short = ids.short(id)
        return .string((try? ids.resolve(short)) == id ? short : id.uuidString.lowercased())
    }

    /// 只有已准许的 PNG 才会进入实际 stat；本方法只收集路径，不打开内容或文件属性。
    static func anchorImageURLs(_ plan: JSONValue) -> Set<URL> {
        let shots = plan["shots"]?.arrayValue ?? []
        return Set(shots.flatMap { $0["anchors"]?.arrayValue ?? [] }.compactMap {
            SourceFrameReader.permissionImageURL($0["source_frame"])
        })
    }

    /// 权限扫描不为找几条路径解码 film/render 或重新构造整份公开 plan。
    static func anchorImageURLs(_ production: Plan) -> Set<URL> {
        guard production.shots.count <= 100, production.shots.allSatisfy({ $0.anchors.count <= 2 }) else { return [] }
        return Set(production.shots.flatMap(\.anchors).compactMap {
            SourceFrameReader.permissionImageURL($0.sourceFrame)
        })
    }
}
