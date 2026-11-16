import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// MARK: - 声音怎么过一刀：结果（纯值）
//
// 管什么：做完之后回给 AI 的 —— 每一刀两边的声音现在在哪段、哪条轨，断在哪一刻、比画面的切点早 / 晚几帧，渐变几帧，
// 这次新分出去的是哪段画面的声音，增益要了多少、实际调了多少（到顶被夹住要看得出来），文件里切点两边还剩几帧素材（还能放多宽），
// on_beat 落在哪一拍、挪了几帧，bed 用的哪段、往两边伸了几帧、量到的电平。全按**提交之后**的工程读（同 mcp-edit-parameters 的
// applied：不报中间状态）；画面自己带着的声音按它实际响的样子报（V1 有转场的一头按转场，CutSoundEdges.renderedSound）。
// 不管什么：改（CutSoundPlanner）。

enum CutSoundReport {
    static func json(_ outcomes: [CutSoundOutcome], in state: TimelineState, ids: AIShortIDs) -> JSONValue {
        var result: [String: JSONValue] = [
            "sound": .string(outcomes.first?.mode.rawValue ?? ""),
            "cuts": .array(outcomes.map { cut($0, in: state, ids: ids) }),
            "picture": "unchanged"
        ]
        var notes: [String] = []
        if outcomes.contains(where: { !$0.separated.isEmpty }) {
            notes.append("separated_from: that clip's sound now plays from an audio track, linked to its picture (it moves and trims with it).")
        }
        if outcomes.contains(where: { $0.crossfadeShape == "equal_power" }) {
            notes.append("equal_power: each sound's volume curve carries a small bump over the crossfade, so the loudness holds through the middle.")
        }
        if !notes.isEmpty { result["note"] = .string(notes.joined(separator: " ")) }
        return .object(result)
    }

    private static func cut(_ outcome: CutSoundOutcome, in state: TimelineState, ids: AIShortIDs) -> JSONValue {
        let rate = state.frameRate
        let time = outcome.cut.time
        var entry: [String: JSONValue] = [
            "after": .string(ids.short(outcome.cut.outgoing.id)),
            "cut": AIFormat.seconds(time)
        ]
        if let frames = outcome.frames { entry["frames"] = .number(Double(frames)) }
        if let shape = outcome.crossfadeShape { entry["shape"] = .string(shape) }
        if let transition = outcome.cut.transition { entry["picture_transition"] = .string(transition.rawValue) }
        var room: [String: JSONValue] = [:]
        if let id = outcome.outgoing, let clip = state.clip(with: id) {
            entry["out"] = side(clip, edge: .end, outcome, in: state, ids: ids)
            room["out"] = .number(Double(CutSoundFrames.whole(CutSoundEdges.roomAfter(clip, at: time), rate)))
        } else {
            entry["out"] = "no sound"
        }
        if let id = outcome.incoming, let clip = state.clip(with: id) {
            entry["in"] = side(clip, edge: .start, outcome, in: state, ids: ids)
            room["in"] = .number(Double(CutSoundFrames.whole(CutSoundEdges.roomBefore(clip, at: time), rate)))
        } else {
            entry["in"] = "no sound"
        }
        entry["room_frames"] = .object(room)
        if let beat = outcome.beat {
            entry["beat"] = ["at": AIFormat.seconds(beat.at), "moved_frames": .number(Double(beat.offsetFrames)),
                             "music": .string(ids.short(beat.music))]
        }
        if let bed = outcome.bed, let clip = state.clip(with: bed.clip) {
            var object: [String: JSONValue] = [
                "id": .string(ids.short(clip.id)), "from": AIFormat.seconds(clip.timelineStart), "to": AIFormat.seconds(clip.timelineEnd),
                "extended_frames": ["before": .number(Double(bed.extendedBefore)), "after": .number(Double(bed.extendedAfter))],
                "raised_db": decibels(bed.raised)
            ]
            if let slot = state.location(of: clip.id)?.track { object["track"] = .string(AITrackName.name(of: slot)) }
            entry["bed"] = .object(object)
        }
        if let levels = outcome.levels {
            var object: [String: JSONValue] = [:]
            if let value = levels.outgoing { object["out"] = decibels(value) }
            if let value = levels.incoming { object["in"] = decibels(value) }
            if let value = levels.bed { object["bed"] = decibels(value) }
            if !object.isEmpty { entry["levels_db"] = .object(object) }
        }
        if !outcome.notes.isEmpty { entry["note"] = .string(outcome.notes.joined(separator: " ")) }
        return .object(entry)
    }

    /// 一边的声音：在哪段、哪条轨，挨着切点那一头在哪一刻、离画面的切点几帧，渐变几帧，新分出去的、调过增益的另写。
    private static func side(
        _ clip: EditClip, edge: CutSoundEdges.Edge, _ outcome: CutSoundOutcome, in state: TimelineState, ids: AIShortIDs
    ) -> JSONValue {
        let rate = state.frameRate
        let heard: (start: Double, end: Double, fadeIn: Double, fadeOut: Double) = clip.isAudioOnly
            ? (clip.timelineStart, clip.timelineEnd, clip.audioFades.fadeIn, clip.audioFades.fadeOut)
            : CutSoundEdges.renderedSound(of: clip, in: state)
        let at = edge == .end ? heard.end : heard.start
        let fade = edge == .end ? heard.fadeOut : heard.fadeIn
        var object: [String: JSONValue] = [
            "id": .string(ids.short(clip.id)),
            edge == .end ? "ends" : "starts": AIFormat.seconds(at),
            "offset_frames": .number(Double(CutSoundFrames.nearest(at - outcome.cut.time, rate))),
            "fade_frames": .number(Double(CutSoundFrames.nearest(fade, rate)))
        ]
        if let slot = state.location(of: clip.id)?.track { object["track"] = .string(AITrackName.name(of: slot)) }
        if let picture = outcome.separated[clip.id] { object["separated_from"] = .string(ids.short(picture)) }
        let gains = outcome.gains.filter { $0.clip == clip.id }
        if !gains.isEmpty {
            let applied = gains.reduce(0) { $0 + $1.applied }
            let requested = gains.reduce(0) { $0 + $1.requested }
            object["gain_db"] = decibels(applied)
            if abs(applied - requested) > 0.05 {
                object["requested_gain_db"] = decibels(requested)
                object["gain_note"] = "clamped: the clip volume stays within edit_limits.volume_db"
            }
        }
        return .object(object)
    }

    private static func decibels(_ value: Double) -> JSONValue {
        .number((value * 10).rounded() / 10)
    }
}
