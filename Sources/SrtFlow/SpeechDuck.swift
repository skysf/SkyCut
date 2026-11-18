import Foundation

// MARK: - Ducking under speech: the rule as numbers, and the dip windows (pure)
//
// Owns (MCP-29, 2026-11-18): the shared rule "under speech, dip the music about 10 dB only while words are spoken (down
// 0.3–0.5 s before a line, back 0.5 s after, not between words)" (Resources/recipes-shared-rules.md, Voice and music 1) as
// numbers, and turning the speech's lines (timeline seconds) into dip windows. Each line's window starts `attack` before it
// (the layer is fully down when the line starts) and ends `release` after it; a line is a sentence (transcript) or a stretch
// between pauses of 0.6 s (VoiceLines), so the layer never comes up between words. Lines so close that the layer would be up
// for less than `minimumUp` share one window: it stays down across the pause instead of pumping.
// Not here: where the lines come from (SpeechDuckLines), drawing a dip into a clip's volume curve (SpeechDuckCurve), which
// clips dip (SpeechDuckPlanner). Rules: docs/architecture/audio-volume-curve.md section 5.

enum SpeechDuck {
    /// How deep a dip may go (dB under the layer's own level next to the line). The shared rule asks for about −10.
    static let depthRange: ClosedRange<Double> = -30...0
    /// Down: the dip starts this long before a line and is full when the line starts (the rule says 0.3–0.5 s).
    static let attack = 0.4
    /// Back: the layer is at its own level again this long after a line ends.
    static let release = 0.5
    /// Lines whose windows would leave the layer fully up for less than this share one window.
    static let minimumUp = 1.0

    /// One dip on the timeline (seconds): down over [from, holdFrom], down through [holdFrom, holdTo], back up by `to`.
    struct Window: Equatable, Sendable {
        var from: Double
        var holdFrom: Double
        var holdTo: Double
        var to: Double

        /// How far down the dip is at `time`: 0 outside, 1 through the hold, linear on the ramps.
        func fraction(at time: Double) -> Double {
            guard time > from, time < to else { return 0 }
            if time < holdFrom { return holdFrom - from > 1e-9 ? (time - from) / (holdFrom - from) : 1 }
            if time <= holdTo { return 1 }
            return to - holdTo > 1e-9 ? (to - time) / (to - holdTo) : 1
        }
    }

    /// The dip windows of `lines` (timeline seconds, any order; empty or reversed lines are dropped), in time order.
    static func windows(_ lines: [ClosedRange<Double>]) -> [Window] {
        let sorted = lines.filter { $0.upperBound > $0.lowerBound && $0.lowerBound.isFinite && $0.upperBound.isFinite }
            .sorted { $0.lowerBound < $1.lowerBound }
        var result: [Window] = []
        for line in sorted {
            let window = Window(from: line.lowerBound - attack, holdFrom: line.lowerBound,
                                holdTo: line.upperBound, to: line.upperBound + release)
            if var last = result.last, window.from - last.to < minimumUp {
                last.holdTo = max(last.holdTo, window.holdTo)
                last.to = max(last.to, window.to)
                result[result.count - 1] = last
            } else {
                result.append(window)
            }
        }
        return result
    }
}
