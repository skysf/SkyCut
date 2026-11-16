import Foundation

// MARK: - 声音怎么过一刀：要量电平的两种 —— 调增益、垫一层底（纯值）
//
// 管什么：
// - **调增益**（gain）：下一个镜头的声音整段平移，给了 gain_db 就照它，没给就调到和上一个镜头切点前的电平一样（「两边电平对齐」）。
// - **垫一层底**（bed）：拿音频轨上的一段（音乐、环境、长音；layer_id 或跨过切点最长的那段）当底，伸到切点两边各 N 帧（默认 2 秒，
//   真人南极正片里「从下面穿过去」= 两边都待 2 秒以上），余料不够照实报；然后两边的原声比底响 6 dB 以上的整段压到「底 + 6 dB」——
//   真人的规矩：一层底在切点上不比较响的一边低 6 dB 以上才盖得住（joins-human.md；没东西盖着的刀两边最多差 3.4 dB）。只压不抬。
// 听到的电平 = 素材在测量窗里的均方（App 量好传进来，CutSoundMeasure）+ 段的音量线在那一刻的 dB + 所在轨的推子。
// 不量渐变：调的是镜头本身的电平，渐变是过切点那一下的事。
// 不管什么：量（CutSoundMeasure）、挪声音（CutSoundPlanner / CutSoundEdges）。规矩见 docs/architecture/cut-sound.md。

enum CutSoundLevelPlan {
    /// 底至少不比两边较响的那一边低这么多 dB，才算盖得住切点上的跳变。
    static let bedMargin = 6.0

    /// 一段声音在 `time` 附近听到的电平（dB）：素材 + 段的音量线 + 推子。素材没量到（静的、读不了）是 nil。
    static func heard(material: Double?, clip: EditClip?, at time: Double, in state: TimelineState) -> Double? {
        guard let material, let clip, !clip.isMuted else { return nil }
        let fader = AudioGain.decibels(fromLinear: state.trackVolume(containingClip: clip.id))
        return material + clip.volumeLineDecibels(atTimeline: time) + fader
    }

    static func gain(_ work: inout CutSoundPlanner.Work, material: CutSoundPlanner.Material) throws {
        let into = try work.requireSound(.incoming)
        if let given = work.request.gainDB {
            try work.shiftGain(of: .incoming, by: given)
            return
        }
        let out = try work.requireSound(.outgoing)
        let middle = CutSoundWindows.middle
        let outLevel = heard(material: material.outgoing, clip: out, at: work.time - middle, in: work.state)
        let inLevel = heard(material: material.incoming, clip: into, at: work.time + middle, in: work.state)
        work.outcome.levels = CutSoundOutcome.Levels(outgoing: outLevel, incoming: inLevel)
        guard let outLevel, let inLevel else {
            throw AIToolError(
                "One side is silent right at the cut (SkyCut measures 0.3 s on each side), so there is no level to match. "
                    + "Pass gain_db to set the next clip's sound yourself. Nothing was changed."
            )
        }
        try work.shiftGain(of: .incoming, by: outLevel - inLevel)
    }

    static func bed(_ work: inout CutSoundPlanner.Work, layer: EditClip?, material: CutSoundPlanner.Material) throws {
        guard let layer, let clip = work.state.clip(with: layer.id) else {
            throw AIToolError("The bed sound is gone from the timeline. Call get_timeline and try again.")
        }
        let time = work.time
        try CutSoundLimits.check(work.frames, .bed, CutSoundLimits.reach(clip, around: time, work.state.frameRate))
        let reach = Double(work.frames) * work.spf
        var before = 0
        var after = 0
        if clip.timelineStart > time - reach + 1e-6 {
            before = CutSoundFrames.nearest(clip.timelineStart - (time - reach), work.state.frameRate)
            CutSoundEdges.set(.start, of: clip.id, to: time - reach, fade: clip.fadeInDuration, in: &work.state)
            work.touched.insert(clip.id)
        }
        if clip.timelineEnd < time + reach - 1e-6 {
            after = CutSoundFrames.nearest((time + reach) - clip.timelineEnd, work.state.frameRate)
            CutSoundEdges.set(.end, of: clip.id, to: time + reach, fade: clip.fadeOutDuration, in: &work.state)
            work.touched.insert(clip.id)
        }
        work.outcome.bed = CutSoundOutcome.Bed(clip: clip.id, extendedBefore: before, extendedAfter: after)
        try duckSides(&work, under: clip.id, material: material)
    }

    /// 两边的原声比底响 6 dB 以上的，整段压到「底 + 6 dB」（只压不抬）。
    private static func duckSides(_ work: inout CutSoundPlanner.Work, under bed: UUID, material: CutSoundPlanner.Material) throws {
        let state = work.state
        let middle = CutSoundWindows.middle
        let bedLevel = heard(material: material.layer, clip: state.clip(with: bed), at: work.time, in: state)
        let outLevel = heard(material: material.outgoing, clip: work.sound(.outgoing), at: work.time - middle, in: state)
        let inLevel = heard(material: material.incoming, clip: work.sound(.incoming), at: work.time + middle, in: state)
        work.outcome.levels = CutSoundOutcome.Levels(outgoing: outLevel, incoming: inLevel, bed: bedLevel)
        guard let bedLevel else {
            work.outcome.notes.append(
                "The bed is silent right at the cut, so it cannot cover the jump and the two sides were left as they are. "
                    + "Raise the bed there (edit_clip volume_curve) or pick another layer_id."
            )
            return
        }
        for (side, level) in [(CutSoundPlanner.Side.outgoing, outLevel), (.incoming, inLevel)] {
            guard let level, level > bedLevel + bedMargin + 0.05 else { continue }
            try work.shiftGain(of: side, by: bedLevel + bedMargin - level)
        }
    }

}
