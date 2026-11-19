import Foundation

// MARK: - Ducking under speech: drawing the dip into one clip's volume curve (pure)
//
// Owns (MCP-29): what a window does to a clip's line (`EditClip.volumeCurve`, dB, source-time keys) — under the window the
// layer sits `depth` dB under its own level next to the line. "Its own level" is the edge line: a straight line between the
// clip's line at the window's two ends (an end beyond the clip takes the other end's level).
// - The dip already there is measured, not assumed: the deepest the line goes under the edge line through the window's hold
//   (an earlier duck, or one drawn by hand with volume_curve); where only a ramp reaches the clip, read on the deeper half of
//   the ramp it covers. The window then moves the line by the difference times the window's shape, so ducking again sets the
//   dip instead of stacking it, and depth 0 takes it out.
// - Everything else keeps its shape, moved with the dip: a cut's equal-power bump or a bed's swell (CutSoundCurves) rises
//   above the dip's floor and never counts as the dip, whether it was drawn before or after the duck.
// A clip lying wholly inside one window (a sound placed on a line) is left alone: its own level next to the line is unknown,
// and a sound effect on a word is moved or lowered on purpose, not ducked. The caller lists it.
// Exact: the existing keys move by the offset at their time and keys are set at the window's corners, so between keys both the
// line and the window's shape are dB-linear, which is how the curve interpolates (docs/architecture/audio-volume-curve.md).
// Values stay within AudioGain's limits (the −60 dB floor is silence).
// Not here: the windows (SpeechDuck), which clips (SpeechDuckPlanner).

enum SpeechDuckCurve {
    enum Result: Equatable, Sendable {
        /// Drawn under `windows` windows. `reached` is the shallowest dip under a hold (dB, ≤ 0): the depth asked for, or less
        /// where the volume floor stopped it; nil when no hold reaches the clip (only a ramp does).
        case ducked(windows: Int, reached: Double?)
        /// The clip lies inside one window: left as it is.
        case insideLine
        /// No window reaches the clip.
        case untouched
    }

    static let epsilon = 1e-6
    /// Points per window where the line is read (measuring the dip already there, and what the dip reached).
    static let samples = 64
    /// A window reaching less than this into a clip (seconds) leaves it alone: the dip's two corner keys there would merge
    /// into one (VolumeCurveEditing keeps keys half a millisecond apart), so it could not be drawn exactly nor read back, and
    /// it would be under 0.1 dB anyway.
    static let minimumReach = 2 * VolumeCurveEditing.timelineTolerance

    /// Draws the dip of `windows` (timeline seconds) into `clip`'s curve.
    static func duck(_ clip: inout EditClip, under windows: [SpeechDuck.Window], depth: Double) -> Result {
        let start = clip.timelineStart, end = clip.timelineEnd
        guard end - start > epsilon else { return .untouched }
        let touching = windows.filter { $0.from < end - minimumReach && $0.to > start + minimumReach }
        guard !touching.isEmpty else { return .untouched }
        if touching.contains(where: { $0.from <= start + epsilon && $0.to >= end - epsilon }) { return .insideLine }
        let before = clip
        let existing = touching.map { existingDip(of: $0, in: before) }
        let shifts = zip(touching, existing).map { (window: $0, by: $1 + depth) }.filter { abs($0.by) > 1e-9 }
        if !shifts.isEmpty { clip.volumeCurve = shifted(before, by: shifts) }
        var reached: Double?
        for (window, dip) in zip(touching, existing) {
            for time in holdTimes(window, in: before) {
                let undocked = before.volumeLineDecibels(atTimeline: time) + dip
                reached = max(reached ?? -.infinity, clip.volumeLineDecibels(atTimeline: time) - undocked)
            }
        }
        return .ducked(windows: touching.count, reached: reached)
    }

    /// The layer's own level next to `window`, as a straight line across it (dB at a timeline time): the clip's line at the
    /// window's two ends; an end beyond the clip takes the other end's level (the caller never passes a window covering it).
    static func edgeLine(of window: SpeechDuck.Window, in clip: EditClip) -> (Double) -> Double {
        let leftInside = window.from > clip.timelineStart + epsilon
        let rightInside = window.to < clip.timelineEnd - epsilon
        let leftLevel = clip.volumeLineDecibels(atTimeline: window.from)
        let rightLevel = clip.volumeLineDecibels(atTimeline: window.to)
        let left = leftInside ? leftLevel : rightLevel
        let right = rightInside ? rightLevel : leftLevel
        let span = window.to - window.from
        return { time in span > epsilon ? left + (right - left) * (time - window.from) / span : left }
    }

    /// How deep (dB, ≥ 0) the clip already dips under the edge line through the window's hold: the deepest point, so a bump
    /// or a swell above the dip's floor never reads as the dip. Where only a ramp reaches the clip (it ends in the attack or
    /// starts in the release), the dip is read on the deeper half of the ramp the clip covers, each point divided by how far
    /// down the ramp is there: a dip drawn there is exactly that share of its depth, however shallow the ramp is at the clip's
    /// edge. (CXR2 R9, 2026-11-19: reading only points at least half way down found nothing on a clip ending a quarter of the
    /// way down, so every call stacked another dip and 0 never took it out.)
    static func existingDip(of window: SpeechDuck.Window, in clip: EditClip) -> Double {
        let edge = edgeLine(of: window, in: clip)
        let dip = { (time: Double) in edge(time) - clip.volumeLineDecibels(atTimeline: time) }
        let hold = holdTimes(window, in: clip)
        if !hold.isEmpty { return max(0, hold.map(dip).max() ?? 0) }
        let ramp = sampleTimes(window, in: clip).map { (time: $0, fraction: window.fraction(at: $0)) }
        guard let deepest = ramp.map(\.fraction).max(), deepest > 0 else { return 0 }
        let dips = ramp.filter { $0.fraction >= deepest / 2 }.map { dip($0.time) / $0.fraction }
        return max(0, dips.max() ?? 0)
    }

    /// Points through the part of the window's hold inside the clip, with the clip's keys there.
    private static func holdTimes(_ window: SpeechDuck.Window, in clip: EditClip) -> [Double] {
        let low = max(window.holdFrom, clip.timelineStart), high = min(window.holdTo, clip.timelineEnd)
        guard high >= low else { return [] }
        let keys = clip.volumeCurve.keys.map { clip.timelineTime(atSource: $0.time) }.filter { $0 >= low && $0 <= high }
        return (0...samples).map { low + (high - low) * Double($0) / Double(samples) } + keys
    }

    /// Points through the part of the window inside the clip.
    private static func sampleTimes(_ window: SpeechDuck.Window, in clip: EditClip) -> [Double] {
        let low = max(window.from, clip.timelineStart), high = min(window.to, clip.timelineEnd)
        guard high > low else { return [] }
        return (0...samples).map { low + (high - low) * Double($0) / Double(samples) }
    }

    /// The clip's line moved by `shifts` (each window's dB change at full depth, times the window's shape): the keys it has
    /// move by the offset at their time, and keys go at the windows' corners inside the clip.
    private static func shifted(_ clip: EditClip, by shifts: [(window: SpeechDuck.Window, by: Double)]) -> KeyframeTrack {
        let offset = { (time: Double) -> Double in shifts.reduce(0) { $0 + $1.by * $1.window.fraction(at: time) } }
        let moved = clip.volumeCurve.keys.map { key -> Keyframe in
            var copy = key
            copy.value = AudioGain.clampedDecibels(key.value + offset(clip.timelineTime(atSource: key.time)))
            return copy
        }
        var track = KeyframeTrack(keys: moved)
        let tolerance = VolumeCurveEditing.sourceTolerance(speed: clip.speed)
        let start = clip.timelineStart, end = clip.timelineEnd
        for (window, _) in shifts {
            let corners = [max(window.from, start), window.holdFrom, window.holdTo, min(window.to, end)]
            for time in corners where time >= start - epsilon && time <= end + epsilon {
                let value = AudioGain.clampedDecibels(clip.volumeLineDecibels(atTimeline: time) + offset(time))
                track.set(value, atSourceTime: clip.sourceTime(atTimeline: time), tolerance: tolerance)
            }
        }
        return track
    }
}
