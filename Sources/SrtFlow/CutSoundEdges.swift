import Foundation

// MARK: - 声音怎么过一刀：挪声音的一头（纯值）
//
// 管什么：一段声音在切点那一头还有多少素材（余料）、把它的尾巴 / 头放到某一刻（源时间跟着换算，「源 ↔ 时间线」不变，
// 所以挂在声音上的字幕、音量曲线、标记都不动）、渐变多长；画面自己带着的声音怎么分出去 —— 分离走界面上那一份
// （`ClipSoundSeparation.separate`），分完把**另一头**改成它此刻实际响的样子：V1 上那一头有转场时，声音原来随转场借余料
// 叠过去、按转场时长渐变（两条渲染管线展开之后的那一份），分出去之后照样，不让别的刀跟着变硬。
// 改完撞上同一条轨的别的段就另找一条音频轨（`TimelineLinkageLanding.settle`，同联动 / 拖文件的梯子）。
// 不管什么：哪种过法挪哪一头、挪多少（CutSoundPlanner）。

enum CutSoundEdges {
    /// 声音的哪一头。
    enum Edge { case start, end }

    /// 从 `time` 往后，这段声音的文件里还有多少素材（时间线秒，按它自己的换算和变速）。
    static func roomAfter(_ clip: EditClip, at time: Double) -> Double {
        max(0, clip.assetDuration - clip.sourceTime(atTimeline: time)) / max(0.05, clip.speed)
    }

    /// 从 `time` 往前，文件里还有多少素材（到文件开头）。
    static func roomBefore(_ clip: EditClip, at time: Double) -> Double {
        max(0, clip.sourceTime(atTimeline: time)) / max(0.05, clip.speed)
    }

    /// 把一头放到 `time`、那一头渐变 `fade` 秒。源时间跟着换算（入点 / 出点挪同样多）；超出文件的那一点点（取整误差）夹回来。
    static func set(_ edge: Edge, of id: UUID, to time: Double, fade: Double, in state: inout TimelineState) {
        state.update(id) { clip in
            let speed = max(0.05, clip.speed)
            switch edge {
            case .end:
                let end = min(clip.sourceTime(atTimeline: time), clip.assetDuration)
                clip.sourceDuration = max(0, end - clip.sourceStart)
                clip.fadeOutDuration = max(0, fade)
            case .start:
                let source = max(0, clip.sourceTime(atTimeline: time))
                let end = clip.sourceStart + clip.sourceDuration
                clip.timelineStart += (source - clip.sourceStart) / speed
                clip.sourceStart = source
                clip.sourceDuration = max(0, end - source)
                clip.fadeInDuration = max(0, fade)
            }
        }
    }

    /// 画面自己带着的声音分出去，`other` 那一头照它此刻实际响的样子（见文件开头）。返回分出去那段的 id；分不了（静音、没声音）是 nil。
    /// `original`：改之前的时间线（量「实际响的样子」用，同一次调用里先改的几刀不算）。
    static func separate(_ picture: EditClip, keeping other: Edge, from original: TimelineState, in state: inout TimelineState) -> UUID? {
        let heard = renderedSound(of: picture, in: original)
        guard let id = ClipSoundSeparation.separate(picture.id, in: &state) else { return nil }
        switch other {
        case .start: set(.start, of: id, to: heard.start, fade: heard.fadeIn, in: &state)
        case .end: set(.end, of: id, to: heard.end, fade: heard.fadeOut, in: &state)
        }
        return id
    }

    /// 一段画面带着的声音此刻实际从哪响到哪、两头各渐变多久 —— 和音频引擎同一份账（`AudioEngineConfig.make`）：V1 先展开转场
    /// （借余料、定格补足；定格那一截没有声音），有转场的那一头按转场叠的时长渐变（`AudioFadeWindow.previewMainTrack`）。
    /// 上层轨没有转场，就是它自己的位置和渐变。
    static func renderedSound(of picture: EditClip, in state: TimelineState) -> (start: Double, end: Double, fadeIn: Double, fadeOut: Double) {
        let own = picture.audioFades
        guard state.mainClips.contains(where: { $0.id == picture.id }) else {
            return (picture.timelineStart, picture.timelineEnd, own.fadeIn, own.fadeOut)
        }
        var sorted = state
        sorted.sortMainClipsByStart()
        let expanded = sorted.expandingTransitionHandles()
        guard let index = expanded.mainClips.firstIndex(where: { $0.id == picture.id }) else {
            return (picture.timelineStart, picture.timelineEnd, own.fadeIn, own.fadeOut)
        }
        let clip = expanded.mainClips[index]
        let fades = AudioFadeWindow.previewMainTrack(
            clip: clip,
            transitionBefore: index > 0 ? expanded.transitionOverlap(afterMainIndex: index - 1) : 0,
            transitionAfter: expanded.transitionOverlap(afterMainIndex: index)
        )
        let start = clip.timelineStart + clip.renderHoldHead
        let end = start + clip.renderSourceDuration / max(0.05, clip.speed)
        // 渐变从展开后的段头 / 段尾算起；定格那一截没声音，从真素材开始的地方起算剩下的那一截。
        return (start, end, max(0, fades.fadeIn - clip.renderHoldHead), max(0, fades.fadeOut - clip.renderHoldTail))
    }

    /// 改过的声音撞上同一条轨上的别的段：另找一条放得下的音频轨，都放不下新开一条（让的是改过的那段）。
    static func settle(_ ids: Set<UUID>, in state: inout TimelineState) {
        guard !ids.isEmpty else { return }
        TimelineLinkageLanding.settle(lanes: ids, texts: [], filters: [], in: &state)
    }
}
