import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// Sound across a cut — the 2026-11-16 decisions (docs/architecture/cut-sound.md):
// 1. Crossfades are equal power. Linear fade x the curve bump keeps the summed power within 0.5 dB through the window, where
//    linear fades alone dip about 3 dB (control). The bump is 0 dB at both window ends, so the clip's line still starts at its
//    body level. One continuous take stays linear and sums exactly. Joining the same cut again replaces the bump instead of
//    stacking it, and `cut` removes it.
// 2. bed raises the bed around the cut (a swell in its volume curve, on top of any curve already there). Only the part the
//    volume limit leaves uncovered comes off the loud side (CutSoundLevelChecks). A bed that already carries the cut is left alone.
// 3. gain without gain_db brings the louder side down (CutSoundLevelChecks).

func runCutSoundDecisionChecks() {
    equalPowerChecks()
    bedRaiseChecks()
}

/// Summed power (dB) of the two sounds at `time`: each plays its line (volume or curve) times its linear fade.
private func summedPower(_ out: EditClip, _ into: EditClip, at time: Double) -> Double {
    let a = out.heardGain(atTimeline: time, trackGain: 1)
    let b = into.heardGain(atTimeline: time, trackGain: 1)
    return 10 * log10(a * a + b * b)
}

/// The quietest and loudest summed power over `[from, to]` (51 samples).
private func powerRange(_ out: EditClip, _ into: EditClip, from: Double, to: Double) -> (low: Double, high: Double) {
    let values = (0...50).map { summedPower(out, into, at: from + (to - from) * Double($0) / 50) }
    return (values.min() ?? 0, values.max() ?? 0)
}

private func equalPowerChecks() {
    let (state, a, _) = cutPair()
    guard let done = try? joinSound(state, after: a.id, .crossfade, frames: 6),
          let out = done.outcome.outgoing.flatMap({ done.state.clip(with: $0) }),
          let into = done.outcome.incoming.flatMap({ done.state.clip(with: $0) }) else {
        return check(false, "equal-power crossfade works")
    }
    checkEqual(done.outcome.crossfadeShape, "equal_power", "a crossfade between two different sounds is equal power")
    let range = powerRange(out, into, from: 3.75, to: 4.25)
    check(range.low > -0.5 && range.high < 0.5, "equal power: the summed power stays within 0.5 dB through the crossfade (got \(range))")
    var plain = done.state
    plain.update(out.id) { $0.volumeCurve = KeyframeTrack() }
    plain.update(into.id) { $0.volumeCurve = KeyframeTrack() }
    if let o = plain.clip(with: out.id), let i = plain.clip(with: into.id) {
        checkNear((summedPower(o, i, at: 4) * 10).rounded() / 10, -3, "control: linear fades alone dip 3 dB in the middle")
    }
    checkEqual(out.volumeCurve.keys.count, CutSoundCurves.segments + 1, "equal power: one bump point per segment end")
    checkNear(into.volumeLineDecibels(atTimeline: into.timelineStart), 0,
              "equal power: the next sound's line starts at its body level (edit_clip volume_db reads it there)")
    checkNear(out.volumeLineDecibels(atTimeline: 3.75), 0, "equal power: the bump starts at 0 dB")
    check((out.volumeCurve.keys.map(\.value).max() ?? 0) < 4, "equal power: the bump stays under +4 dB")

    if let again = try? joinSound(done.state, after: a.id, .crossfade, frames: 12),
       let o2 = again.outcome.outgoing.flatMap({ again.state.clip(with: $0) }),
       let i2 = again.outcome.incoming.flatMap({ again.state.clip(with: $0) }) {
        checkEqual(o2.volumeCurve.keys.count, CutSoundCurves.segments + 1, "crossfade again: the old bump is replaced, not stacked")
        let wider = powerRange(o2, i2, from: 3.5, to: 4.5)
        check(wider.low > -0.5 && wider.high < 0.5, "crossfade again: still flat (got \(wider))")
    } else { check(false, "crossfading the same cut twice works") }
    if let hard = try? joinSound(done.state, after: a.id, .cut) {
        let sounds = [hard.outcome.outgoing, hard.outcome.incoming].compactMap { $0 }
        check(sounds.allSatisfy { hard.state.clip(with: $0)?.volumeCurve.isEmpty == true }, "cut after an equal-power crossfade: the bumps are gone")
    } else { check(false, "cut after a crossfade works") }

    var take = TimelineState()
    take.mainClips = [cutShot(cutFileA, 0, 4, source: 10), cutShot(cutFileA, 4, 4, source: 14)]
    guard let linear = try? joinSound(take, after: take.mainClips[0].id, .crossfade, frames: 6),
          let o = linear.outcome.outgoing.flatMap({ linear.state.clip(with: $0) }),
          let i = linear.outcome.incoming.flatMap({ linear.state.clip(with: $0) }) else {
        return check(false, "a crossfade on one continuous take works")
    }
    checkEqual(linear.outcome.crossfadeShape, "linear", "one continuous take: a linear crossfade")
    check(o.volumeCurve.isEmpty && i.volumeCurve.isEmpty, "one continuous take: no curve is drawn")
    checkNear(o.heardGain(atTimeline: 4, trackGain: 1) + i.heardGain(atTimeline: 4, trackGain: 1), 1,
              "one continuous take: the two halves add back up to the original sound")
}

private func bedRaiseChecks() {
    let (base, a, b) = cutPair()
    var state = base
    let music = audioClip(0, 10)
    state.audioTracks = [EditLane(clips: [music])]
    // The bed is 4 dB short of carrying the cut: it is raised 4 dB around the cut, nothing else changes.
    if let done = try? joinSound(state, after: a.id, .bed, material: .init(outgoing: -10, incoming: -30, layer: -20)),
       let bed = done.state.clip(with: music.id) {
        checkNear(done.outcome.bed?.raised, 4, "bed raise: 4 dB short, raised 4 dB")
        checkNear(bed.volumeLineDecibels(atTimeline: 4), 4, "bed raise: full raise at the cut")
        checkNear(bed.volumeLineDecibels(atTimeline: 3.6), 4, "bed raise: …over the measuring window before the cut")
        checkNear(bed.volumeLineDecibels(atTimeline: 3), 0, "bed raise: back to its level 1 s before the cut")
        checkNear(bed.volumeLineDecibels(atTimeline: 5), 0, "bed raise: …and 1 s after")
        checkEqual(done.state.clip(with: a.id)?.volume, 1, "bed raise: the loud side stays when the bed can carry it")
        checkEqual(done.state.clip(with: b.id)?.volume, 1, "bed raise: the quiet side stays")
    } else { check(false, "bed raise works") }
    if let done = try? joinSound(state, after: a.id, .bed, material: .init(outgoing: -10, incoming: -30, layer: -15)) {
        check(done.state.clip(with: music.id)?.volumeCurve.isEmpty == true && done.outcome.bed?.raised == 0,
              "bed: one already carrying the cut is not raised")
    } else { check(false, "bed already carrying works") }
    var ducked = state
    ducked.update(music.id) { $0.volumeCurve = KeyframeTrack(keys: [Keyframe(time: 0, value: -10), Keyframe(time: 10, value: -10)]) }
    if let done = try? joinSound(ducked, after: a.id, .bed, material: .init(outgoing: -10, incoming: -30, layer: -15)),
       let bed = done.state.clip(with: music.id) {
        checkNear(bed.volumeLineDecibels(atTimeline: 4), -1, "bed raise on a ducked bed: -10 dB raised by 9 to -1")
        checkNear(bed.volumeLineDecibels(atTimeline: 2), -10, "bed raise on a ducked bed: the duck stays outside the swell")
        checkEqual(done.state.clip(with: a.id)?.volume, 1, "bed raise on a ducked bed: no side is lowered")
    } else { check(false, "bed raise on a ducked bed works") }
}
