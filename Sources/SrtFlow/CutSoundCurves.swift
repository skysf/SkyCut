import Foundation

// MARK: - Sound across a cut: level shapes drawn into volume curves (pure)
//
// Owns: the two level shapes a sound join draws into a clip's volume curve (`EditClip.volumeCurve`, dB, source-time keys) —
// - the equal-power crossfade: the engine's fades are linear (docs/architecture/audio-fades.md rule 4), so two different sounds
//   crossfaded with them dip about 3 dB in the middle. The join keeps the linear fade and adds a compensating bump, so
//   linear fade x bump = cos (outgoing) / sin (incoming): the summed power stays flat. The bump is 0 dB at both ends of the
//   window, so the clip's first key still reads its body level (edit_clip volume_db reads the curve at the clip start);
// - the bed swell: a trapezoid that raises a bed around the cut so it carries the jump (2026-11-16 decision);
// and clearing a join's window before the edge is set again (the join owns the level shape inside its window).
// Existing keys inside a window are shaped as well, so a curve already drawn there (ducking) is multiplied, not replaced.
// Not here: which join moves which edge (CutSoundPlanner), measuring (CutSoundMeasure). Rules: docs/architecture/cut-sound.md.

enum CutSoundCurves {
    /// Points across a crossfade window (8 segments: the summed power stays within about 0.1 dB of flat).
    static let segments = 8

    /// Multiplier that turns the linear fade into the equal-power one at `u` (0 = window start, 1 = window end).
    /// Fade-in: sin(pi u / 2) / u. Fade-out: cos(pi u / 2) / (1 - u). Exactly 1 at both ends (the fade is 0 or 1 there anyway).
    static func equalPowerBoost(_ u: Double, incoming: Bool) -> Double {
        if incoming {
            guard u > 1e-9, u < 1 else { return 1 }
            return sin(Double.pi / 2 * u) / u
        }
        guard u > 0, u < 1 - 1e-9 else { return 1 }
        return cos(Double.pi / 2 * u) / (1 - u)
    }

    /// Draws the equal-power bump over the timeline window `[from, to]` of a sound whose linear fade spans that window.
    static func shapeCrossfade(_ id: UUID, from: Double, to: Double, incoming: Bool, in state: inout TimelineState) {
        guard to - from > 1e-6 else { return }
        reshape(id, from: from, to: to, in: &state) { time in
            20 * log10(equalPowerBoost((time - from) / (to - from), incoming: incoming))
        } samples: { (0...segments).map { from + (to - from) * Double($0) / Double(segments) } }
    }

    /// Raises a bed by `delta` dB around `time`: full raise over `time ± half`, ramps of `half` on each side. Returns the raise
    /// actually applied at `time` (less when the clip's line reaches the volume limit).
    @discardableResult
    static func swell(_ id: UUID, at time: Double, by delta: Double, half: Double, in state: inout TimelineState) -> Double {
        guard delta > 0, half > 1e-6, let clip = state.clip(with: id) else { return 0 }
        let before = clip.volumeLineDecibels(atTimeline: time)
        let envelope = { (t: Double) -> Double in
            let distance = abs(t - time)
            if distance <= half { return 1 }
            return max(0, 1 - (distance - half) / half)
        }
        reshape(id, from: time - 2 * half, to: time + 2 * half, in: &state) { delta * envelope($0) } samples: {
            [time - 2 * half, time - half, time + half, time + 2 * half]
        }
        return (state.clip(with: id)?.volumeLineDecibels(atTimeline: time) ?? before) - before
    }

    /// Removes the curve keys inside the timeline window `[from, to]` (the join's own shape; see the file header).
    static func clear(_ id: UUID, from: Double, to: Double, in state: inout TimelineState) {
        state.update(id) { clip in
            let kept = clip.volumeCurve.keys.filter { key in
                let time = clip.timelineTime(atSource: key.time)
                return time < from - 1e-6 || time > to + 1e-6
            }
            clip.volumeCurve = KeyframeTrack(keys: kept)
        }
    }

    /// Adds `offset(t)` dB to the clip's line over `(from, to)`: existing keys inside are raised by it, and keys are set at the
    /// `samples` times to the line's old value there plus the offset. Values stay within the volume limits.
    private static func reshape(
        _ id: UUID, from: Double, to: Double, in state: inout TimelineState,
        offset: (Double) -> Double, samples: () -> [Double]
    ) {
        guard let clip = state.clip(with: id) else { return }
        let points = samples().map { time in (time, clip.volumeLineDecibels(atTimeline: time) + offset(time)) }
        var keys = clip.volumeCurve.keys.map { key -> Keyframe in
            let time = clip.timelineTime(atSource: key.time)
            guard time > from + 1e-6, time < to - 1e-6 else { return key }
            var raised = key
            raised.value = AudioGain.clampedDecibels(key.value + offset(time))
            return raised
        }
        keys.sort { $0.time < $1.time }
        var track = KeyframeTrack(keys: keys)
        let tolerance = VolumeCurveEditing.sourceTolerance(speed: clip.speed)
        for (time, value) in points {
            track.set(AudioGain.clampedDecibels(value), atSourceTime: clip.sourceTime(atTimeline: time), tolerance: tolerance)
        }
        state.update(id) { $0.volumeCurve = track }
    }
}
