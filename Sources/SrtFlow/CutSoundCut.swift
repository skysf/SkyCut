import Foundation

// MARK: - 声音怎么过一刀：哪一刀、两边的声音在哪（纯值）
//
// 管什么：AI 点名的那一刀（画面的切点：一条视频轨上首尾相接、或磁吸排过带转场叠着的两段）在哪一刻、画面上有没有转场；
// 两边各自的声音在哪 —— 画面自己带着（没分离），还是已经分到音频轨上的那一段（同一个链接组、同一个文件）；
// bed / on_beat 用的那一层是哪段。
// 不管什么：怎么改（CutSoundPlanner / CutSoundEdges）、量声音（CutSoundMeasure）。规矩见 docs/architecture/cut-sound.md。

/// 一边的声音在哪。
struct CutSoundVoice: Equatable {
    /// 放着这段声音的那一段：没分离就是画面自己，分离了就是音频轨上的那一段。
    var id: UUID
    var embedded: Bool
}

struct CutSoundCut: Equatable {
    /// 切点前后的两段画面。
    let outgoing: EditClip
    let incoming: EditClip
    /// 两段在哪条视频轨上（V1 或上层轨）。
    let track: TrackSlot
    /// 画面换的那一刻：首尾相接就是接缝；磁吸排过、带转场叠着的取叠的正中（画面一半一半的那一刻）。
    let time: Double
    /// 这一刀上画面的转场（只有 V1 有；真做得出来的才算，同两条渲染管线的 `effectiveTransitionDuration`）。
    let transition: ClipTransition?

    /// `after_clip_id` 那一刀：给的是画面，或它分出去的声音（认回它的画面）。
    static func after(_ id: UUID, in state: TimelineState) throws -> CutSoundCut {
        guard let clip = state.clip(with: id) else {
            throw AIToolError("There is no clip with that id. Call get_timeline for current ids.")
        }
        let picture = clip.isAudioOnly ? Self.picture(of: clip, in: state) : clip
        guard let picture, let slot = state.location(of: picture.id)?.track, !slot.isAudio else {
            throw AIToolError(
                "Sound joins work on picture cuts: after_clip_id must be the clip before the cut on V1, V2… (or its separated "
                    + "sound). To overlap two sounds on audio tracks, use edit_clip start / source_in / fade_in."
            )
        }
        let lane = state[track: slot].sorted { $0.timelineStart < $1.timelineStart }
        guard let index = lane.firstIndex(where: { $0.id == picture.id }), index + 1 < lane.count else {
            throw AIToolError("That is the last clip on \(AITrackName.name(of: slot)); there is no cut after it.")
        }
        let next = lane[index + 1]
        let gap = next.timelineStart - picture.timelineEnd
        guard gap <= TimelineState.seamTolerance else {
            throw AIToolError(
                "The two clips do not touch (there is a \(String(format: "%.2f", gap)) s gap), so there is no cut to join the sound across."
            )
        }
        return try make(picture, next, slot, in: state)
    }

    /// V1 上每一刀（首尾相接或带转场叠着的相邻两段，两边都没藏起来的）：all=true。
    static func everyMainCut(in state: TimelineState) -> [CutSoundCut] {
        let main = state.mainClips.sorted { $0.timelineStart < $1.timelineStart }
        return main.indices.dropLast().compactMap { index in
            let (left, right) = (main[index], main[index + 1])
            guard right.timelineStart - left.timelineEnd <= TimelineState.seamTolerance else { return nil }
            return try? make(left, right, .main, in: state)
        }
    }

    private static func make(_ left: EditClip, _ right: EditClip, _ slot: TrackSlot, in state: TimelineState) throws -> CutSoundCut {
        for side in [left, right] where side.isHidden {
            throw AIToolError("\(side.name) is hidden, so its sound is not heard; show it first (edit_clip hidden=false).")
        }
        var transition: ClipTransition?
        if slot.isMain, let index = state.mainClips.firstIndex(where: { $0.id == left.id }),
           state.effectiveTransitionDuration(afterMainIndex: index) > 0 {
            transition = left.transitionAfter
        }
        return CutSoundCut(
            outgoing: left, incoming: right, track: slot,
            time: (left.timelineEnd + right.timelineStart) / 2, transition: transition
        )
    }

    // MARK: 两边的声音

    /// 一段画面的声音此刻在哪：画面自己带着（没静音、有声音）；否则是分到音频轨上的那一段（同组、同文件、没静音没藏）。
    /// 都没有（静音的视频、图片、所在的轨藏着）就是 nil。
    static func voice(of picture: EditClip, in state: TimelineState) -> CutSoundVoice? {
        if let slot = state.location(of: picture.id)?.track, state.isLaneHidden(slot) { return nil }
        if !picture.isAudioOnly, picture.hasAudio, !picture.isMuted { return CutSoundVoice(id: picture.id, embedded: true) }
        return separatedSound(of: picture, in: state).map { CutSoundVoice(id: $0.id, embedded: false) }
    }

    /// 画面分出去的那段声音：同一个链接组、同一个文件、只取声音、在一条没藏的音频轨上、没静音没藏。先认「源 ↔ 时间线」
    /// 和画面对得上的（分离出来、J/L 只挪两头，换算不变），再认和画面重叠最多的。
    static func separatedSound(of picture: EditClip, in state: TimelineState) -> EditClip? {
        guard let group = picture.linkGroup else { return nil }
        let candidates = state.audioTracks.enumerated().flatMap { index, lane in
            state.isLaneHidden(.audio(index)) ? [] : lane.clips
        }.filter {
            $0.linkGroup == group && $0.isAudioOnly && $0.sourceURL == picture.sourceURL && !$0.isMuted && !$0.isHidden
        }
        return candidates.max { a, b in rank(a, for: picture) < rank(b, for: picture) }
    }

    /// 一段分出去的声音是哪段画面的（认回画面用）：同组、同文件、有画面，先认换算对得上的。
    static func picture(of sound: EditClip, in state: TimelineState) -> EditClip? {
        guard let group = sound.linkGroup else { return nil }
        let candidates = state.allClips.filter { $0.linkGroup == group && !$0.isAudioOnly && $0.sourceURL == sound.sourceURL }
        return candidates.max { a, b in rank(sound, for: a) < rank(sound, for: b) }
    }

    /// 排序用：换算对得上的排前面，再按重叠多长。
    private static func rank(_ sound: EditClip, for picture: EditClip) -> Double {
        let sameMapping = abs(sound.speed - picture.speed) < 1e-9
            && abs(sound.timelineTime(atSource: 0) - picture.timelineTime(atSource: 0)) < 0.001
        let overlap = max(0, min(sound.timelineEnd, picture.timelineEnd) - max(sound.timelineStart, picture.timelineStart))
        return (sameMapping ? 1_000_000 : 0) + overlap
    }

    // MARK: bed / on_beat 用的那一层

    /// 这次请求要不要一层、要的话是哪段（bed / on_beat 才要；两边自己的声音不算；找的范围至少切点两边各 0.3 秒）。
    static func layer(for request: CutSoundRequest, at cut: CutSoundCut, in state: TimelineState) throws -> EditClip? {
        guard request.mode == .bed || request.mode == .onBeat else { return nil }
        let own = Set([cut.outgoing, cut.incoming].compactMap { voice(of: $0, in: state)?.id })
        let reach = CutSoundFrames.seconds(request.resolvedFrames(state.frameRate), state.frameRate)
        return try layer(request.layer, around: cut, reach: max(reach, CutSoundWindows.span), excluding: own, in: state)
    }

    /// bed 铺在底下的、on_beat 找拍子的那一段声音。给了 id 就用它（必须是音频轨上的声音、不是两边自己的）；
    /// 没给就在音频轨上找和 [切点 − reach, 切点 + reach] 重叠最多的那段（一样多取长的）。
    static func layer(_ id: UUID?, around cut: CutSoundCut, reach: Double, excluding: Set<UUID>, in state: TimelineState) throws -> EditClip {
        if let id {
            guard let clip = state.clip(with: id), let slot = state.location(of: id)?.track, slot.isAudio else {
                throw AIToolError("layer_id must be a sound on an audio track (A1, A2…): music, ambience or a long tone.")
            }
            guard !excluding.contains(id) else {
                throw AIToolError("layer_id is one of the two sounds at this cut; pick another sound to run under it.")
            }
            guard !clip.isMuted, !clip.isHidden, !state.isLaneHidden(slot) else {
                throw AIToolError("\(clip.name) is muted or hidden, so it cannot carry the cut.")
            }
            return clip
        }
        let from = cut.time - reach
        let to = cut.time + reach
        let candidates = state.audioTracks.enumerated().flatMap { index, lane in
            state.isLaneHidden(.audio(index)) ? [] : lane.clips
        }.filter { !excluding.contains($0.id) && !$0.isMuted && !$0.isHidden && $0.timelineEnd > from && $0.timelineStart < to }
        func overlap(_ clip: EditClip) -> Double { min(clip.timelineEnd, to) - max(clip.timelineStart, from) }
        let best = candidates.max { a, b in
            abs(overlap(a) - overlap(b)) > 1e-6 ? overlap(a) < overlap(b) : a.timelineDuration < b.timelineDuration
        }
        guard let best else {
            throw AIToolError(
                "No sound on an audio track runs across this cut (music for on_beat; music or ambience for bed): put one there first "
                    + "(find_audio, add_clips), then pass it as layer_id. Nothing was changed."
            )
        }
        return best
    }
}
