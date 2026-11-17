import Foundation

// MARK: - listen: the project's frames over a window (pure value)
//
// What: listen reports `loudest_at` and `peak_at` to the frame (docs/architecture/project-frame-rate.md: the rate comes
// from the project, never written down). A window [from, to) is cut at the project's frame starts: a file's frames count
// from the file's start, a clip's from the timeline's (its first and last frame may be cut short by the clip's edges).
// `clip(_:window:trackGain:)` maps a clip's timeline frames to the source seconds the read needs, with when each frame
// starts and the gain heard in it (EditClip.heardGain: clip volume / curve, fades, track fader — what listen has always
// applied).
// Not here: reading (AIListenAudioWindow), the per-frame numbers (AIListenSampleFrames), the result (AIListenPeaks).

struct AIListenFrameGrid: Sendable {
    let fps: Int

    /// Boundaries covering [from, to): `from`, every frame start strictly inside, `to`.
    func bounds(from: Double, to: Double) -> [Double] {
        guard fps > 0, to > from else { return [from, max(from, to)] }
        var result = [from]
        var frame = Int((from * Double(fps) + 1e-6).rounded(.down)) + 1
        while Double(frame) / Double(fps) < to - 1e-9 {
            result.append(Double(frame) / Double(fps))
            frame += 1
        }
        result.append(to)
        return result
    }

    /// A clip heard over `window` (timeline seconds): the frames' source boundaries for the read, when each frame starts on
    /// the timeline and the gain heard in it.
    struct Clip: Sendable {
        let sourceBounds: [Double]
        let starts: [Double]
        let gains: [Double]
    }

    func clip(_ clip: EditClip, window: (from: Double, to: Double), trackGain: Double) -> Clip {
        let timeline = bounds(from: window.from, to: window.to)
        let starts = Array(timeline.dropLast())
        let gains = zip(timeline, timeline.dropFirst()).map { clip.heardGain(atTimeline: ($0 + $1) / 2, trackGain: trackGain) }
        return Clip(sourceBounds: timeline.map { clip.sourceTime(atTimeline: $0) }, starts: starts, gains: gains)
    }
}
