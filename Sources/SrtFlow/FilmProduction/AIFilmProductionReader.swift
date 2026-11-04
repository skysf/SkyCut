import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// save_project 的公开制作计划入口；全量验证副本，所有 fingerprint 由当前时间线重算核对。
// 不直接改工程、不读取媒体内容；提交/存盘由 AIFilmProductionTool 收尾。
enum AIFilmProductionReader {
    typealias Plan = FilmProductionState
    typealias Graph = AIFilmProductionGraph

    /// 在普通保存分支之前核对组合，不能把显式 CAS 字段静默当成无意义参数。
    static func input(_ args: AIToolArguments) throws -> JSONValue? {
        guard let input = args.raw["production"] else {
            guard args.raw["expected_revision"] == nil else {
                throw error("expected_revision", "expected_revision requires production. Omit expected_revision for an ordinary save.")
            }
            return nil
        }
        return input
    }

    static func read(_ input: JSONValue, expectedRevision: Int, previous: Plan?, state: TimelineState, allowedImages: Set<URL> = [], catalog: SkyStudioCatalog? = nil) throws -> Plan {
        guard expectedRevision == (previous?.revision ?? 0) else { throw error("expected_revision", "The plan changed; read get_timeline again.") }
        let object = try SkyStudioFilmReader.object(input, keys: ["story", "shots", "sound_cues"], at: "production")
        let story = try text(object["story"], "production.story", maximum: 2000)
        let rawShots = try array(object["shots"], "production.shots", maximum: 100)
        guard !rawShots.isEmpty else { throw error("production.shots", "A story needs at least one shot.") }
        let ids = AIShortIDs(state: state)
        let prior = try previous.map(Graph.decode) ?? []
        var records = try rawShots.enumerated().map { index, raw -> Plan.Shot in
            let path = "production.shots[\(index)]"
            let value = try SkyStudioFilmReader.object(raw, keys: ["film", "render", "clip_id", "output_binding", "output_review", "anchors"], at: path)
            let film = try SkyStudioFilm(json: value["film"] ?? .null)
            let render = try SkyStudioFilmReader.readRender(value["render"], at: path + ".render")
            let retained = prior.first { $0.film.shot.id == film.shot.id }?.record.outputClipID
            let clipID = try itemID(value["clip_id"], path: path + ".clip_id", retained: retained, ids: ids)
            return Plan.Shot(film: try film.json.encodedData(), render: try render.json.encodedData(), outputClipID: clipID)
        }
        // 先按当前版本验证内容；到上限的原样回读仍应是 no-op，不能在判断相等前先 +1 拒掉。
        var proposal = Plan(revision: max(1, expectedRevision), story: story, shots: records, soundCues: [])
        let graph = try Graph.decode(proposal)
        try Graph.revisions(graph, after: prior)
        for shot in graph where prior.first(where: { $0.film.shot.id == shot.film.shot.id })?.render != shot.render {
            guard let catalog else {
                throw error("production.render", "Read get_status models=true or prepare_references before writing new render specifications; saving never fetches a catalog silently.")
            }
            try SkyStudioPublicRenderValidation.validate(shot.render, catalog: catalog, at: "production.render")
        }
        for index in records.indices {
            let current = graph[index]
            let old = prior.first { $0.film.shot.id == current.film.shot.id }
            let object = rawShots[index].objectValue!
            records[index].boundSourceFingerprint = try binding(object["output_binding"], current: current, previous: old, state: state)
            records[index].review = try AIFilmProductionReviewReader.read(object["output_review"], index: index,
                graph: graph, previous: old?.record.review, state: state)
            let rawAnchors = object["anchors"] ?? []
            let storedAnchors = old?.record.anchors ?? []
            let storedJSON = try? JSONValue.array(storedAnchors.map(AIFilmProductionAnchorReader.json))
            if rawAnchors == storedJSON {
                // 输入来源是历史事实；换了本镜输出后保留旧证据，不偷偷换 render.inputs 或把它刷新为当前。
                records[index].anchors = storedAnchors
            } else {
                records[index].anchors = try AIFilmProductionAnchorReader.read(rawAnchors, shot: current, graph: graph, state: state, allowedImages: allowedImages)
            }
        }
        proposal.shots = records
        let rawCues = try array(object["sound_cues"] ?? [], "production.sound_cues", maximum: 400)
        proposal.soundCues = try rawCues.enumerated().map { index, raw in
            try cue(raw, at: "production.sound_cues[\(index)]", graph: graph, previous: previous?.soundCues ?? [], state: state, ids: ids)
        }
        guard Set(proposal.soundCues.map(\.id)).count == proposal.soundCues.count else {
            throw error("production.sound_cues", "Cue ids must be unique.")
        }
        _ = try Graph.decode(proposal) // 完整外层持久值与来源 metadata 也走同一加载校验。
        if proposal == previous { return previous! } // 原样保存不制造撤销步骤或版本。
        proposal.revision = expectedRevision + 1
        _ = try Graph.decode(proposal)
        return proposal
    }

    private static func binding(_ input: JSONValue?, current: Graph.Shot, previous: Graph.Shot?, state: TimelineState) throws -> String? {
        let supplied = try input.flatMap { $0 == .null ? nil : try AIFilmProductionReviewReader.fingerprint($0, "production.output_binding") }
        guard let id = current.record.outputClipID else {
            guard supplied == nil else { throw error("production.output_binding", "An unbound shot has no output binding.") }
            return nil
        }
        if previous?.record.outputClipID == id {
            let stored = previous?.record.boundSourceFingerprint
            // 原样回读或省略字段都不表示重新接受已被换源/裁切的同 UUID；保留旧身份让读取/生成明确报 stale。
            if supplied == nil || supplied == stored { return stored }
        }
        let actual = AIFilmProductionSnapshot.fingerprint(try AIFilmProductionSnapshot.source(id, state: state, picture: true))
        guard supplied == nil || supplied == actual else {
            throw error("production.output_binding", "Echo expected_snapshots.output_binding to rebind this changed output, or clear the old binding when choosing a different clip_id.")
        }
        return actual
    }

    private static func cue(_ input: JSONValue, at path: String, graph: [Graph.Shot], previous: [Plan.SoundCue],
                            state: TimelineState, ids: AIShortIDs) throws -> Plan.SoundCue {
        let value = try SkyStudioFilmReader.object(input, keys: ["id", "shot_ids", "layer", "purpose", "at", "duration",
            "action_id", "audio_clip_id", "silence_reason", "recovery_at", "alignment"], at: path)
        let id = try text(value["id"], path + ".id")
        let shotIDs = try array(value["shot_ids"], path + ".shot_ids", maximum: 100).map { try text($0, path + ".shot_ids") }
        guard !shotIDs.isEmpty, Set(shotIDs).count == shotIDs.count, shotIDs.allSatisfy({ id in graph.contains { $0.film.shot.id == id } }),
              let layer = value["layer"]?.stringValue.flatMap(Plan.SoundCue.Layer.init(rawValue:)) else {
            throw error(path, "Name existing distinct shots and music/environment/foley/silence.")
        }
        let at = try number(value["at"], path + ".at"), duration = try number(value["duration"], path + ".duration")
        guard duration > 0, at + duration <= 86_400 else { throw error(path + ".duration", "Duration must be positive and end within 86400 seconds.") }
        let action = try value["action_id"].flatMap { $0 == .null ? nil : try text($0, path + ".action_id") }
        if layer == .foley {
            guard shotIDs.count == 1, let action, graph.first(where: { $0.film.shot.id == shotIDs[0] })?.film.shot.actions.contains(action) == true else {
                throw error(path + ".action_id", "Foley must name a new visible action in exactly one shot; never replay an entry completed action.")
            }
        }
        let retainedAudio = previous.first(where: { $0.id == id })?.audioClipID
        let audio = try itemID(value["audio_clip_id"], path: path + ".audio_clip_id", retained: retainedAudio, ids: ids)
        if let audio, audio != retainedAudio, state.clip(with: audio)?.hasAudio != true {
            throw error(path + ".audio_clip_id", "Bind a current clip with audio.")
        }
        let reason = try value["silence_reason"].flatMap { $0 == .null ? nil : try text($0, path + ".silence_reason", maximum: 400) }
        let recovery = try value["recovery_at"].flatMap { $0 == .null ? nil : try number($0, path + ".recovery_at") }
        if layer == .silence {
            guard reason != nil, let recovery, abs(recovery - at - duration) < 0.001, audio == nil else {
                throw error(path, "Intentional silence requires a reason and recovery_at equal to its end; do not attach an audible clip.")
            }
        }
        var cue = Plan.SoundCue(id: id, shotIDs: shotIDs, layer: layer, purpose: try text(value["purpose"], path + ".purpose", maximum: 400),
            at: at, duration: duration, actionID: action, audioClipID: audio, silenceReason: reason, recoveryAt: recovery)
        if let raw = value["alignment"], raw != .null {
            let a = try SkyStudioFilmReader.object(raw, keys: ["snapshot", "measured_note", "listened_note"], at: path + ".alignment")
            let alignment = Plan.Alignment(fingerprint: try AIFilmProductionReviewReader.fingerprint(a["snapshot"], path + ".alignment.snapshot"),
                measuredNote: try a["measured_note"].flatMap { $0 == .null ? nil : try text($0, path + ".measured_note", maximum: 400) },
                listenedNote: try a["listened_note"].flatMap { $0 == .null ? nil : try text($0, path + ".listened_note", maximum: 400) })
            let unchanged = previous.first(where: { $0.id == id })?.alignment == alignment
            if !unchanged {
                guard layer == .silence || audio != nil,
                      alignment.fingerprint == (try AIFilmProductionSnapshot.fingerprint(AIFilmProductionSnapshot.cue(cue, shots: graph, state: state))) else {
                    throw error(path + ".alignment", "Use the current expected snapshot after actually realigning/listening; the old evidence is stale.")
                }
            }
            cue.alignment = alignment
        }
        return cue
    }

    private static func itemID(_ input: JSONValue?, path: String, retained: UUID?, ids: AIShortIDs) throws -> UUID? {
        guard let input, input != .null else { return nil }
        let value = try text(input, path)
        // 已删除的历史绑定仍能原样保存为 stale；只认旧记录的完整 UUID，绝不把任意新 UUID 当工程素材。
        if let retained, UUID(uuidString: value) == retained { return retained }
        return try ids.resolve(value)
    }

    static func text(_ value: JSONValue?, _ path: String, maximum: Int = 80) throws -> String {
        try SkyStudioFilmReader.text(value, at: path, maximum: maximum)
    }
    static func array(_ value: JSONValue?, _ path: String, maximum: Int) throws -> [JSONValue] {
        guard let values = value?.arrayValue, values.count <= maximum else { throw error(path, "Expected a bounded list (max \(maximum)).") }
        return values
    }
    static func number(_ value: JSONValue?, _ path: String) throws -> Double {
        guard let value = value?.doubleValue, value.isFinite, value >= 0, value <= 86_400 else { throw error(path, "Expected finite seconds in 0...86400.") }
        return value
    }
    static func error(_ path: String, _ message: String) -> SkyStudioFilmError { SkyStudioFilmReader.error(path, message) }
}
