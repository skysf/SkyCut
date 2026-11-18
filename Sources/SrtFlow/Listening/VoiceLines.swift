import Foundation

/// Where the lines of a clean voice are: its own pauses (pure).
///
/// What: a voice clip's clean sound (one channel, its rate) → the stretches where it speaks, split wherever it is quiet for
/// at least `pause` seconds. The caller pads each by `margin` on both sides for ESTOI's window (docs/architecture/
/// listening-engine.md section 2 item 3: "取人声起止前后各多 0.2 秒"). A voice-over clip is usually one line already
/// (add_voiceover puts one line per clip); a long narration file splits into its sentences this way without a transcript.
/// Quiet = 20 ms frames more than `rangeDB` under the loudest frame of the clip (the same 40 dB ESTOI drops as silence),
/// and never above −60 dBFS.
/// Not here: ESTOI and who covers the line (MaskerAttribution), the verdict (VoiceClarity).
enum VoiceLines {
    static let frameSeconds = 0.02
    /// A pause this long ends a line: longer than a breath or a comma inside a sentence (0.2–0.5 s), shorter than the gap
    /// between sentences.
    static let pause = 0.6
    /// Padding on both sides of a line for ESTOI's window (the caller adds it).
    static let margin = 0.2
    /// Quieter than the loudest frame by this much counts as a pause.
    static let rangeDB = 40.0
    /// …and anything under this is quiet whatever the loudest frame is.
    static let floorDBFS = -60.0

    /// Where the voice in `samples` speaks, as sample ranges (whole 20 ms frames, not padded), in order.
    static func split(_ samples: [Float], rate: Double) -> [Range<Int>] {
        let size = max(1, Int((frameSeconds * rate).rounded()))
        let frames = samples.count / size
        guard frames > 0 else { return [] }
        var levels = [Double](repeating: 0, count: frames)
        for frame in 0 ..< frames {
            var sum = 0.0
            for index in frame * size ..< (frame + 1) * size { sum += Double(samples[index]) * Double(samples[index]) }
            levels[frame] = 10 * log10(sum / Double(size) + 1e-24)
        }
        return stretches(levels: levels, frameSeconds: frameSeconds).map { $0.lowerBound * size ..< $0.upperBound * size }
    }

    /// The same rule on levels a caller already has (dB of each frame's mean square, frames `frameSeconds` long): where the
    /// voice speaks, as frame ranges. Ducking under speech reads a narration's lines this way from the waveform's windows
    /// (SpeechDuckLines) instead of decoding the file again.
    static func stretches(levels: [Double], frameSeconds: Double) -> [Range<Int>] {
        guard !levels.isEmpty, frameSeconds > 0 else { return [] }
        let loudest = levels.max() ?? -240
        let threshold = max(loudest - rangeDB, floorDBFS)
        guard loudest > threshold else { return [] }
        let gap = max(1, Int((pause / frameSeconds).rounded()))
        var lines: [Range<Int>] = []
        var start: Int?, lastLoud = 0
        for frame in levels.indices where levels[frame] > threshold {
            if let begun = start, frame - lastLoud - 1 >= gap {
                lines.append(begun ..< lastLoud + 1)
                start = frame
            } else if start == nil {
                start = frame
            }
            lastLoud = frame
        }
        if let begun = start { lines.append(begun ..< lastLoud + 1) }
        return lines
    }
}
