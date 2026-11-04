import Foundation
import CryptoKit
import SrtFlowCore
import SrtFlowMCPKit

// 只从当前时间线及磁盘属性计算公开制作身份；不读媒体内容、不改状态、不假装实际画面验收。
enum AIFilmProductionSnapshot {
    static func encoded<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    static func fingerprint(_ value: JSONValue) -> String {
        SHA256.hash(data: Data(value.encodedString().utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func source(_ id: UUID, state: TimelineState, picture: Bool) throws -> JSONValue {
        // 非法旧速度可能触发 EditClip 的时长保护下限；这种几何不能用另一套 raw-speed 时间账冒充已用帧。
        guard let clip = state.clip(with: id), let slot = state.location(of: id)?.track,
              clip.speed.isFinite, clip.speed > 0, clip.sourceStart.isFinite, clip.sourceStart >= 0,
              clip.sourceDuration.isFinite, clip.sourceDuration > 0, (clip.sourceStart + clip.sourceDuration).isFinite,
              clip.timelineStart.isFinite, clip.timelineStart >= 0, clip.timelineEnd.isFinite, clip.timelineEnd > clip.timelineStart,
              clip.timelineDuration == clip.sourceDuration / clip.speed,
              !(picture && clip.isHidden), !(picture && clip.isAudioOnly) else {
            throw SkyStudioFilmReader.error("production.clip_id", "Bind a visible current clip with valid used source geometry.")
        }
        guard !(picture && state.isLaneHidden(slot)), !clip.needsStillConversion else {
            throw SkyStudioFilmReader.error("production.clip_id", "A hidden or still-converting track has no used output.")
        }
        var fields: [String: JSONValue] = [
            "clip_id": .string(id.uuidString.lowercased()), "track": .string(AITrackName.name(of: slot)),
            "track_hidden": .bool(state.isLaneHidden(slot)),
            "source": try SkyStudioApproval.file(clip.stillImageURL ?? clip.sourceURL),
            "source_in": .number(clip.sourceStart), "source_out": .number(clip.sourceStart + clip.sourceDuration),
            "speed": .number(clip.speed), "timeline_start": .number(clip.timelineStart), "timeline_end": .number(clip.timelineEnd),
            "frame_rate": .number(Double(state.frameRate.fps)), "canvas": try encoded(state.canvasRatio),
            "geometry": try geometry(clip, picture: picture)
        ]
        if picture {
            let canvas = TimelineRenderSize.size(for: rendered(state))
            guard canvas.width.isFinite, canvas.height.isFinite, canvas.width > 0, canvas.height > 0 else {
                throw SkyStudioFilmReader.error("production.clip_id", "The effective rendered canvas must be finite and nonempty.")
            }
            fields["effective_canvas"] = ["width": .number(Double(canvas.width)), "height": .number(Double(canvas.height))]
        }
        if clip.stillImageURL != nil { fields["still_video"] = try SkyStudioApproval.file(clip.sourceURL) }
        return .object(fields)
    }

    private static func geometry(_ clip: EditClip, picture: Bool) throws -> JSONValue {
        // 标记/链接行为不改变已看画面；画面身份排除纯声音旋钮，声音身份保留其完整配置。
        var fields = try encoded(clip).objectValue!
        for field in ["markers", "remoteKey", "upscale", "linkGroup"] { fields[field] = nil }
        if picture {
            for field in ["isMuted", "volume", "fadeInDuration", "fadeOutDuration", "volumeCurve", "soundScene"] { fields[field] = nil }
        }
        return .object(fields)
    }

    static func authoredSource(_ shot: AIFilmProductionGraph.Shot, state: TimelineState) throws -> JSONValue {
        guard let id = shot.record.outputClipID else {
            throw SkyStudioFilmReader.error("production.clip_id", "Bind an output clip first.")
        }
        // 邻镜 render/cut 的改动只属于 seam；不能因此把本镜未变画面的观察废掉。
        // revision 是作者 CAS，邻镜修改也可能推进它；源证据比较本镜真实内容，不拿版本号代替内容。
        return ["shot_id": .string(shot.film.shot.id), "entry": shot.film.shot.entry.json,
                "exit": shot.film.shot.exit.json, "actions": .array(shot.film.shot.actions.map(JSONValue.string)),
                "context": shot.film.context.json, "render": shot.render.json,
                "source": try source(id, state: state, picture: true)]
    }

    static func authoredSeam(_ left: AIFilmProductionGraph.Shot, _ right: AIFilmProductionGraph.Shot,
                             state: TimelineState) throws -> JSONValue {
        guard let a = left.record.outputClipID, let b = right.record.outputClipID else {
            throw SkyStudioFilmReader.error("production.clip_id", "Both seam outputs must exist.")
        }
        return ["left": try authoredSource(left, state: state), "right": try authoredSource(right, state: state),
                "left_next": left.film.next?.json(side: "next") ?? .null,
                "right_previous": right.film.previous?.json(side: "previous") ?? .null,
                "seam": try seam(a, b, state: state)]
    }

    static func seam(_ left: UUID, _ right: UUID, state: TimelineState) throws -> JSONValue {
        guard let a = state.clip(with: left), let b = state.clip(with: right),
              state.mainClips.contains(where: { $0.id == left }), state.mainClips.contains(where: { $0.id == right }),
              let index = state.mainClips.firstIndex(where: { $0.id == left }),
              state.mainClips.indices.contains(index + 1), state.mainClips[index + 1].id == right else {
            throw SkyStudioFilmReader.error("production.output_review", "Output seam review requires adjacent V1 clips in story order.")
        }
        let from = max(a.timelineStart, a.timelineEnd - 2), to = min(b.timelineEnd, b.timelineStart + 2)
        return ["left": try source(left, state: state, picture: true), "right": try source(right, state: state, picture: true),
                "composition": try composition(state, from: from, to: to)]
    }

    private static func composition(_ state: TimelineState, from: Double, to: Double) throws -> JSONValue {
        // 参与这两秒合成的上层画面、滤镜、文字、形状、字幕也算；不得只看主轨原片。
        // 同 builder 一样先排序并借余料；短镜尾部可能已看见第三镜借来的头，不能只按作者原窗选源。
        let evaluation = rendered(state)
        let overlapping = evaluation.allClips.filter {
            guard !$0.isAudioOnly, !$0.isHidden, !$0.needsStillConversion,
                  let slot = evaluation.location(of: $0.id)?.track else { return false }
            return !evaluation.isLaneHidden(slot) && $0.timelineStart < to && $0.timelineEnd > from
        }
        let texts = state.renderedTextOverlays.filter { $0.timelineStart < to && $0.timelineStart + $0.duration > from }
        let shapes = (state.renderedShapes + state.renderedCovers).filter { $0.timelineStart < to && $0.timelineStart + $0.duration > from }
        let filters = state.renderedFilters.filter { $0.timelineStart < to && $0.timelineStart + $0.duration > from }
        let pictures: [JSONValue] = try overlapping.map { clip in
            ["source": try source(clip.id, state: state, picture: true), "render_geometry": try geometry(clip, picture: true),
             "render_hold_head": .number(clip.renderHoldHead), "render_hold_tail": .number(clip.renderHoldTail)]
        }
        return ["clips": .array(pictures),
                "texts": try encoded(texts), "shapes": try encoded(shapes), "filters": try encoded(filters),
                "subtitles": try subtitles(state, from: from, to: to), "from": .number(from), "to": .number(to)]
    }

    private static func rendered(_ state: TimelineState) -> TimelineState {
        var result = state
        result.sortMainClipsByStart()
        return result.expandingTransitionHandles()
    }

    private static func subtitles(_ state: TimelineState, from: Double, to: Double) throws -> JSONValue {
        let blocks: [JSONValue] = try state.subtitleScreenBlocks().compactMap { block in
            let layers = block.layers.map { $0.filter { $0.start < to && $0.end > from } }
            guard layers.contains(where: { !$0.isEmpty }) else { return nil }
            let contents: [JSONValue] = try layers.map { cues in
                .array(try cues.map { cue in
                    var fields = try encoded(cue).objectValue!
                    fields["index"] = nil // 远处增删字幕造成的重编号不改变这段画面；数组仍保留实际渲染顺序。
                    return .object(fields)
                })
            }
            return ["layers": .array(contents), "layout": try encoded(block.layout), "highlight": try encoded(block.highlight)]
        }
        guard !blocks.isEmpty else { return .array([]) }
        guard let style = state.projectSubtitleStyle else {
            throw SkyStudioFilmReader.error("production.output_review", "Capture the effective subtitle style on the MainActor before evaluating a composed seam.")
        }
        var styling = try encoded(style).objectValue!
        for key in ["id", "name", "isBuiltIn"] { styling[key] = nil }
        return ["blocks": .array(blocks), "style": .object(styling)]
    }

    private static func mix(_ state: TimelineState, from: Double, to: Double) throws -> JSONValue {
        // measured/listened 指这段混音：覆盖贡献源的静音/场景/曲线、所在轨推子和总推子。
        // 复用真正引擎的借余料/定格留空/渐变与曲线。只要 metadata，不运行响度补偿的合成 DSP。
        // 带 scene 的更早声音保守保留（余音可能越过段尾）；scene 参数自己入身份，不把占位补偿值当测量。
        guard state.masterVolume.isFinite else {
            throw SkyStudioFilmReader.error("production.sound_cues", "The current master volume must be finite.")
        }
        let config = AudioEngineConfig.make(from: state, measuringSceneCompensation: false)
        guard config.master.isFinite else { throw SkyStudioFilmReader.error("production.sound_cues", "The rendered master volume must be finite.") }
        let tracks: [JSONValue] = try config.tracks.compactMap { track in
            let segments = track.segments.filter { $0.start < to && ($0.end > from || $0.scene != nil) }
            guard !segments.isEmpty else { return nil }
            guard track.fader.isFinite else {
                throw SkyStudioFilmReader.error("production.sound_cues", "The current contributing track volume must be finite.")
            }
            let values: [JSONValue] = try segments.map { segment in
                guard [segment.start, segment.end, segment.sourceStart, segment.speed].allSatisfy(\.isFinite),
                      segment.gain.points.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.from.isFinite && $0.to.isFinite }) else {
                    throw SkyStudioFilmReader.error("production.sound_cues", "The rendered sound window and gains must be finite.")
                }
                let gains: [JSONValue] = segment.gain.points.map {
                    ["start": .number($0.start), "end": .number($0.end), "from": .number(Double($0.from)), "to": .number(Double($0.to))]
                }
                return ["source": try source(segment.clipID, state: state, picture: false),
                        "start": .number(segment.start), "end": .number(segment.end), "source_in": .number(segment.sourceStart),
                        "speed": .number(segment.speed), "gain_points": .array(gains), "scene_parameters": try encoded(segment.scene)]
            }
            return ["track": .string(track.name), "volume": .number(Double(track.fader)), "segments": .array(values)]
        }
        return ["tracks": .array(tracks), "master_volume": .number(Double(config.master)), "scene_compensation_measured": false]
    }

    static func cue(_ cue: FilmProductionState.SoundCue, shots: [AIFilmProductionGraph.Shot], state: TimelineState) throws -> JSONValue {
        let covered = try cue.shotIDs.map { id -> AIFilmProductionGraph.Shot in
            guard let record = shots.first(where: { $0.film.shot.id == id }), let clip = record.record.outputClipID,
                  let output = state.clip(with: clip), cue.at < output.timelineEnd, cue.at + cue.duration > output.timelineStart else {
                throw SkyStudioFilmReader.error("production.sound_cues", "Alignment must overlap the current output of every covered shot.")
            }
            return record
        }
        let pictured = try covered.map { record -> JSONValue in
            ["output": try authoredSource(record, state: state), "sound": record.film.sound.json]
        }
        let clips = covered.compactMap { $0.record.outputClipID.flatMap { state.clip(with: $0) } }
        guard let first = clips.map(\.timelineStart).min(), let last = clips.map(\.timelineEnd).max(),
              cue.at >= first, cue.at + cue.duration <= last else {
            throw SkyStudioFilmReader.error("production.sound_cues", "Spotting must lie within the covered output shots.")
        }
        if let audioID = cue.audioClipID {
            guard let clip = state.clip(with: audioID), clip.hasAudio, !clip.isHidden, !clip.isMuted,
                  let slot = state.location(of: audioID)?.track, !state.isLaneHidden(slot),
                  cue.at >= clip.timelineStart, cue.at < clip.timelineEnd else {
                throw SkyStudioFilmReader.error("production.sound_cues", "Align the cue trigger to the used audio clip first.")
            }
        }
        let audio = try cue.audioClipID.map { try source($0, state: state, picture: false) } ?? .null
        return ["shots": .array(pictured), "audio": audio, "at": .number(cue.at), "duration": .number(cue.duration),
                "layer": .string(cue.layer.rawValue), "action": cue.actionID.map(JSONValue.string) ?? .null,
                "id": .string(cue.id), "purpose": .string(cue.purpose),
                "silence_reason": cue.silenceReason.map(JSONValue.string) ?? .null,
                "recovery_at": cue.recoveryAt.map(JSONValue.number) ?? .null,
                "mix": try mix(state, from: cue.at, to: cue.at + cue.duration)]
    }
}
