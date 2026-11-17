import Foundation

// MARK: - True peak (ITU-R BS.1770-4 Annex 2): 4× oversampling with the Recommendation's interpolator (pure value, streaming)
//
// What: the peak of the waveform the samples describe, not only of the samples. Between two samples the sound can swing
// higher than either (a sine at a quarter of the sample rate read 45° off its crest shows samples 3 dB under its real
// peak); a decoder, a resampler or the AAC encoder reproduces that swing, so a mix whose samples stop at −1 dBFS can still
// leave a player above it. BS.1770 measures it by oversampling four times with a fixed 48-tap interpolating filter and
// taking absolute values; the unit is dBTP.
// Why here: since 2026-11-17 every peak SkyCut reports to the AI (listen, get_job after an export) is this measure, and
// the export limiter holds it at −1 dBTP (ExportPeakLimiter), so "peak" means one thing everywhere
// (docs/architecture/export-audio-mixdown.md, section 2 item 3).
// How: the 48 taps are four phases of 12 (tap j of the filter is phase j % 4, position j / 4). Every new sample shifts a
// 12-sample register and gives the four interpolated points between the samples six and five back (the filter is
// symmetric; its delay is 23.5 oversampled samples = 5.875 input samples). A sample's span = max(|the sample|, the four
// points after it). BS.1770 itself takes only the oversampled points; adding the sample keeps "true peak ≥ sample peak"
// exact (the filter's ripple reads some phases up to 0.24 dB under) and lets the limiter keep every sample under its ceiling.
// Every value depends only on the 12 samples in the register, so feeding in any chunks gives bit-identical spans.
// Not here: limiting (ExportPeakLimiter), loudness (ExportLoudnessMeter), reading files.

enum TruePeak {
    /// A sample's span is known this many samples after it (the interpolator needs six samples after a point).
    static let lag = 6

    /// The Recommendation's 48 coefficients by phase: `coefficients[p][k]` multiplies the sample k back for phase p.
    static let coefficients: [[Float]] = [
        [0.0017089843750, 0.0109863281250, -0.0196533203125, 0.0332031250000, -0.0594482421875, 0.1373291015625,
         0.9721679687500, -0.1022949218750, 0.0476074218750, -0.0266113281250, 0.0148925781250, -0.0083007812500],
        [-0.0291748046875, 0.0292968750000, -0.0517578125000, 0.0891113281250, -0.1665039062500, 0.4650878906250,
         0.7797851562500, -0.2003173828125, 0.1015625000000, -0.0582275390625, 0.0330810546875, -0.0189208984375],
        [-0.0189208984375, 0.0330810546875, -0.0582275390625, 0.1015625000000, -0.2003173828125, 0.7797851562500,
         0.4650878906250, -0.1665039062500, 0.0891113281250, -0.0517578125000, 0.0292968750000, -0.0291748046875],
        [-0.0083007812500, 0.0148925781250, -0.0266113281250, 0.0476074218750, -0.1022949218750, 0.9721679687500,
         0.1373291015625, -0.0594482421875, 0.0332031250000, -0.0196533203125, 0.0109863281250, 0.0017089843750]
    ]

    /// Linear → dBTP (or dBFS for a sample peak): not capped above (several hot layers can go over 0), −60 for silence,
    /// the floor every listen level uses (`AudioGain.minimumDB`).
    static func decibels(_ linear: Float) -> Double {
        linear > 0 ? max(-60, 20 * log10(Double(linear))) : -60
    }

    /// The largest span among samples `range` of a stereo signal held as two arrays (index 0 = sample `origin`), with the
    /// real samples around it: anything outside `valid` (before the timeline, after its end, not rendered) is silence.
    /// Returns the peak and the sample it belongs to (nil when the range is empty or silent).
    static func peak(left: [Float], right: [Float], origin: Int64, range: Range<Int64>, valid: Range<Int64>) -> (peak: Float, sample: Int64?) {
        guard !range.isEmpty else { return (0, nil) }
        // A span needs the 5 samples before it and the 6 after: feed from range − 5 to range + 6, keep the spans in range.
        let first = range.lowerBound - Int64(lag) + 1, last = range.upperBound + Int64(lag)
        var interleaved = [Float](repeating: 0, count: Int(last - first) * 2)
        for sample in max(first, valid.lowerBound) ..< min(last, valid.upperBound) {
            let index = Int(sample - origin), slot = Int(sample - first) * 2
            interleaved[slot] = left[index]
            interleaved[slot + 1] = right[index]
        }
        var stream = Stream(channels: 2)
        var best: Float = 0, at: Int64?
        var sample = first
        interleaved.withUnsafeBufferPointer { buffer in
            stream.feed(buffer, frames: Int(last - first)) { span in
                defer { sample += 1 }
                if range.contains(sample), span.peak > best {
                    best = span.peak
                    at = sample
                }
            }
        }
        return (best, at)
    }

    /// One sample's span: its own magnitude and the largest of the four interpolated points between it and the next sample
    /// (over all channels). The limiter needs the two apart; a meter wants `peak`.
    struct Span: Equatable, Sendable {
        var sample: Float
        var after: Float
        var peak: Float { max(sample, after) }
    }

    /// One channel's interpolator: a 12-sample shift register.
    struct Channel: Sendable {
        // Oldest first: r0 = x[n−11] … x[n−8], r1 = x[n−7] … x[n−4], r2 = x[n−3] … x[n].
        private var r0 = SIMD4<Float>(repeating: 0), r1 = SIMD4<Float>(repeating: 0), r2 = SIMD4<Float>(repeating: 0)

        /// Taps lined up with the register, per phase (oldest sample first).
        private static let taps: [(SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)] = coefficients.map { h in
            (SIMD4(h[11], h[10], h[9], h[8]), SIMD4(h[7], h[6], h[5], h[4]), SIMD4(h[3], h[2], h[1], h[0]))
        }

        init() {}

        /// Push sample n; returns the largest |value| of the four interpolated points between samples n − 6 and n − 5.
        mutating func push(_ x: Float) -> Float {
            r0 = SIMD4(r0[1], r0[2], r0[3], r1[0])
            r1 = SIMD4(r1[1], r1[2], r1[3], r2[0])
            r2 = SIMD4(r2[1], r2[2], r2[3], x)
            var largest: Float = 0
            for phase in Self.taps {
                let value = (r0 * phase.0 + r1 * phase.1 + r2 * phase.2).sum()
                largest = max(largest, abs(value))
            }
            return largest
        }
    }

    /// Interleaved frames in, one span per frame out (`lag` frames late). Frames before the stream count as silence;
    /// `finish` pads silence so the last frames get their spans too (the sound after the end is silence).
    struct Stream: Sendable {
        let channels: Int
        private var interpolators: [Channel]
        /// |sample| of the last `lag + 1` frames (max over channels), so frame n − 6's own magnitude is at hand at frame n.
        private var recent: [Float]
        /// Frames fed (padding included).
        private var fed = 0
        /// Real frames fed (`finish` stops emitting at this many).
        private(set) var received = 0
        /// Spans emitted so far (= the index of the next frame whose span comes out).
        private(set) var emitted = 0

        init(channels: Int) {
            precondition(channels > 0)
            self.channels = channels
            interpolators = [Channel](repeating: Channel(), count: channels)
            recent = [Float](repeating: 0, count: TruePeak.lag + 1)
        }

        /// Feed `frames` interleaved frames; `emit` gets every span that became known, in frame order.
        mutating func feed(_ samples: UnsafeBufferPointer<Float>, frames: Int, _ emit: (Span) -> Void) {
            precondition(samples.count >= frames * channels)
            for frame in 0 ..< frames {
                if let span = push(samples, base: frame * channels) { emit(span) }
            }
        }

        /// The stream ended: pad silence until every real frame has its span.
        mutating func finish(_ emit: (Span) -> Void) {
            while let span = pad() { emit(span) }
        }

        /// Feed one real frame (the `channels` samples from `base`); returns the span that became known (the frame
        /// `lag` back), if any.
        mutating func push(_ samples: UnsafeBufferPointer<Float>, base: Int) -> Span? {
            received += 1
            return shift { samples[base + $0] }
        }

        /// After the last real frame: one frame of silence; returns the next real frame's span, nil once all have one.
        mutating func pad() -> Span? {
            // A stream shorter than `lag` needs a few silent frames before its first span comes out.
            while emitted < received {
                if let span = shift({ _ in 0 }) { return span }
            }
            return nil
        }

        private mutating func shift(_ sample: (Int) -> Float) -> Span? {
            var magnitude: Float = 0, after: Float = 0
            for channel in 0 ..< channels {
                let value = sample(channel)
                magnitude = max(magnitude, abs(value))
                after = max(after, interpolators[channel].push(value))
            }
            recent[fed % recent.count] = magnitude
            fed += 1
            // The points that came out lie after frame fed − 1 − lag; frames before the stream have no span.
            let frame = fed - 1 - TruePeak.lag
            guard frame >= 0, emitted < received else { return nil }
            emitted += 1
            return Span(sample: recent[frame % recent.count], after: after)
        }
    }
}
