#if DEBUG
import Foundation

// What the playback-start benchmark reports about the picture after it starts moving: the longest time one frame
// stayed on screen while playing (a stall) and the worst audio-minus-picture timeline difference at any displayed
// frame. Pure values over the probes' samples; the check script owns the limits (docs/architecture/playback-start.md).
enum PlaybackStartContinuity {
    struct Result {
        /// Longest host-time gap between consecutive advancing frames inside the window, including the gap from the
        /// last frame to the end of the window. A healthy 30 fps start on a 60 Hz display shows a new frame every 33 ms.
        let stallMs: Double
        /// Largest |audio timeline − picture timeline| over the window's frames that had audio at the same host time.
        let maxSkewMs: Double
        let frames: Int
        let skewSamples: Int
    }

    /// The window starts at the first advancing frame and lasts `seconds`.
    static func measure(
        frames: [PlaybackStartVideoProbe.Frame], from start: Double, seconds: Double, audio: (Double) -> Double?
    ) -> Result? {
        let end = start + seconds
        let window = frames.filter { $0.host >= start && $0.host <= end }
        guard var previous = window.first?.host else { return nil }
        var longest = 0.0
        for frame in window.dropFirst() {
            longest = max(longest, frame.host - previous)
            previous = frame.host
        }
        longest = max(longest, end - previous)
        var skew = 0.0
        var sampled = 0
        for frame in window {
            guard let time = audio(frame.host) else { continue }
            skew = max(skew, abs(time - frame.timeline))
            sampled += 1
        }
        return Result(stallMs: longest * 1_000, maxSkewMs: skew * 1_000, frames: window.count, skewSamples: sampled)
    }
}
#endif
