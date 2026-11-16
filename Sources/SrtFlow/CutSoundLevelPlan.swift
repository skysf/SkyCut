import Foundation

// MARK: - Sound across a cut: the two joins that measure levels — gain and bed (pure)
//
// Owns:
// - **gain**: with gain_db the next shot's sound moves by it; without, the louder side comes down to the quieter side's level
//   (2026-11-16 decision: keeps headroom and never lifts noise).
// - **bed**: a sound on an audio track (layer_id, or the longest across the cut) is stretched to reach N frames on each side
//   (default 2 s: the human film's "passes underneath" means 2 s or more on both sides); too little footage is refused. A bed
//   carries a jump only when it is no more than 6 dB under the louder side at the cut (joins-human.md: uncovered human cuts
//   differ by 3.4 dB at most). If it is quieter than that, the bed is **raised** around the cut with a swell in its volume
//   curve, which is how the human editor covered cuts (2026-11-16 decision). Only what the volume limit leaves uncovered
//   is taken off the loud side.
// Heard level = the material's mean square in the measuring window (measured by the App, CutSoundMeasure) + the clip's volume
// line at that moment + its track fader. Fades are left out: this is about the shot's level, fades are the join itself.
// Not here: measuring (CutSoundMeasure), moving edges (CutSoundPlanner / CutSoundEdges), drawing curves (CutSoundCurves).
// Rules: docs/architecture/cut-sound.md.

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
        // The louder side comes down to the quieter one (2026-11-16 decision); equal levels change nothing.
        if inLevel > outLevel {
            try work.shiftGain(of: .incoming, by: outLevel - inLevel)
        } else if outLevel > inLevel {
            try work.shiftGain(of: .outgoing, by: inLevel - outLevel)
        }
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
        try carry(&work, with: clip.id, reach: reach, material: material)
    }

    /// Makes the bed carry the cut: raise it around the cut until it is within 6 dB of the louder side (a swell of `reach / 2`
    /// at most on each side, full over the measuring windows); if the volume limit stops the swell short, lower each side that is
    /// still more than 6 dB over the raised bed down to bed + 6 dB.
    private static func carry(
        _ work: inout CutSoundPlanner.Work, with bed: UUID, reach: Double, material: CutSoundPlanner.Material
    ) throws {
        let state = work.state
        let middle = CutSoundWindows.middle
        let bedLevel = heard(material: material.layer, clip: state.clip(with: bed), at: work.time, in: state)
        let outLevel = heard(material: material.outgoing, clip: work.sound(.outgoing), at: work.time - middle, in: state)
        let inLevel = heard(material: material.incoming, clip: work.sound(.incoming), at: work.time + middle, in: state)
        work.outcome.levels = CutSoundOutcome.Levels(outgoing: outLevel, incoming: inLevel, bed: bedLevel)
        guard let bedLevel else {
            work.outcome.notes.append(
                "The bed is silent right at the cut, so it cannot cover the jump and nothing was raised or lowered. "
                    + "Pick another layer_id, or a stretch of the bed that sounds at the cut."
            )
            return
        }
        guard let louder = [outLevel, inLevel].compactMap({ $0 }).max() else { return }
        let missing = louder - bedMargin - bedLevel
        guard missing > 0.05 else { return }
        let half = min(swellHalf, reach / 2)
        let raised = CutSoundCurves.swell(bed, at: work.time, by: missing, half: half, in: &work.state)
        work.outcome.bed?.raised = raised
        work.touched.insert(bed)
        let carried = bedLevel + raised
        for (side, level) in [(CutSoundPlanner.Side.outgoing, outLevel), (.incoming, inLevel)] {
            guard let level, level > carried + bedMargin + 0.05 else { continue }
            try work.shiftGain(of: side, by: carried + bedMargin - level)
        }
    }

    /// The bed swell's full-level half-width around the cut (and the length of each ramp): it covers the 0.3 s measuring windows.
    static let swellHalf = 0.5
}
