import Foundation

// MARK: - listen: each frame's level and true peak, from the samples of one bounded read (pure value, streaming)
//
// What: while AIListenAudioWindow decodes a window, every sample also comes through here. The window is cut into the
// project's frames (boundaries handed in as source seconds: a clip's timeline frames mapped through its speed, or a file's
// frames counted from its start) and each frame gets its mean square (channels averaged, like listen's level_db) and its
// true peak (TruePeak) with the sample it is at. AIListenPeaks turns that into `peak_db` (the true peak, dBTP), `peak_at`
// and `loudest_at` (the start of the loudest frame) — to the frame, not the centre of a 0.5–600 s curve step
// (docs/bugfixes/2026-11-17-export-peak-before-limiter-and-binned-loudest.md).
// Edges: a window starts and stops where it was asked to, not where the sound does, so the interpolated points of its first
// five and last six samples (which would read past the window) are left out; those samples' own magnitudes count.
// Not here: decoding (AIListenAudioWindow), gains and timeline seconds (AIListenPeaks), the rest of listen's numbers (AIAudioLevels).

struct AIListenSampleFrames: Sendable {
    struct Frame: Sendable, Equatable {
        /// Mean square, channels averaged (0 for a frame no sample landed in).
        var meanSquare: Double = 0
        /// True peak (linear).
        var peak: Float = 0
        /// The sample (counted from the window's first) `peak` belongs to; nil while silent.
        var peakSample: Int?
    }

    /// Frame k covers window samples [bounds[k], bounds[k + 1]); samples past the last bound belong to the last frame.
    let bounds: [Int]
    let channels: Int
    private(set) var frames: [Frame]
    private var sums: [Double]
    private var counts: [Int]
    private var meter: TruePeak.Stream
    /// Samples taken so far, and the next sample whose span is due.
    private var taken = 0
    private var spanned = 0
    private var energyFrame = 0
    private var spanFrame = 0

    /// `seconds`: the frame boundaries in source seconds (first = the window start, last = its end); `start`: the source
    /// second of the window's first sample; `rate`: its sample rate.
    init(seconds: [Double], start: Double, rate: Double, channels: Int) {
        var bounds = seconds.map { max(0, Int((($0 - start) * rate).rounded())) }
        for index in bounds.indices.dropFirst() where bounds[index] < bounds[index - 1] { bounds[index] = bounds[index - 1] }
        self.bounds = bounds.count >= 2 ? bounds : [0, Int.max]
        self.channels = max(1, channels)
        let count = max(1, self.bounds.count - 1)
        frames = [Frame](repeating: Frame(), count: count)
        sums = [Double](repeating: 0, count: count)
        counts = [Int](repeating: 0, count: count)
        meter = TruePeak.Stream(channels: self.channels)
    }

    /// `frames` interleaved frames, the next ones of the window.
    mutating func append(_ samples: UnsafeBufferPointer<Float>, frames count: Int) {
        for frame in 0 ..< count {
            let base = frame * channels
            var power = 0.0
            for channel in 0 ..< channels { power += Double(samples[base + channel]) * Double(samples[base + channel]) }
            energyFrame = Self.advance(energyFrame, to: taken, bounds: bounds, last: frames.count - 1)
            sums[energyFrame] += power / Double(channels)
            counts[energyFrame] += 1
            taken += 1
            // A span that comes out while samples still arrive has six real samples after it; the first five lack the
            // samples before.
            if let span = meter.push(samples, base: base) { take(span, interior: spanned >= TruePeak.lag - 1) }
        }
    }

    /// The window ended: the last six samples' spans (their own magnitudes only), then the mean squares.
    mutating func finish() {
        var tail: [TruePeak.Span] = []
        meter.finish { tail.append($0) }
        for span in tail { take(span, interior: false) }
        for index in frames.indices where counts[index] > 0 { frames[index].meanSquare = sums[index] / Double(counts[index]) }
    }

    /// The window's true peak and its sample (nil when silent).
    var peak: (value: Float, sample: Int?) {
        var best = (value: Float(0), sample: Int?.none)
        for frame in frames where frame.peak > best.value { best = (frame.peak, frame.peakSample) }
        return best
    }

    private mutating func take(_ span: TruePeak.Span, interior: Bool) {
        let value = interior ? span.peak : span.sample
        spanFrame = Self.advance(spanFrame, to: spanned, bounds: bounds, last: frames.count - 1)
        if value > frames[spanFrame].peak {
            frames[spanFrame].peak = value
            frames[spanFrame].peakSample = spanned
        }
        spanned += 1
    }

    /// The frame holding window sample `sample`, searching on from `frame` (samples only move forward).
    private static func advance(_ frame: Int, to sample: Int, bounds: [Int], last: Int) -> Int {
        var frame = frame
        while frame < last, sample >= bounds[frame + 1] { frame += 1 }
        return frame
    }
}

/// What listen says about a clip's or a file's peaks, from its frames: the true peak (dBTP) heard, when it happens, and the
/// start of the loudest frame (by mean square) — on the timeline for a clip (its gains applied), in file seconds for a file.
struct AIListenPeaks: Equatable {
    /// dBTP, −60 for silence (not capped above).
    var truePeakDB: Double
    var peakAt: Double?
    var loudestAt: Double?

    /// `starts[k]`: when frame k starts; `gains[k]`: the linear gain heard in frame k (1 for a file); `time(sample)`: when a
    /// window sample plays (same seconds as `starts`).
    static func measure(_ frames: AIListenSampleFrames, starts: [Double], gains: [Double], time: (Int) -> Double) -> AIListenPeaks {
        var peak: Float = 0, peakSample: Int?
        var loudest: (index: Int, power: Double)?
        for (index, frame) in frames.frames.enumerated() where index < starts.count {
            let gain = index < gains.count ? gains[index] : 1
            let heard = frame.peak * Float(gain)
            if heard > peak {
                peak = heard
                peakSample = frame.peakSample
            }
            let power = frame.meanSquare * gain * gain
            if power > 0, power > (loudest?.power ?? 0) { loudest = (index, power) }
        }
        return AIListenPeaks(
            truePeakDB: TruePeak.decibels(peak), peakAt: peakSample.map(time), loudestAt: loudest.map { starts[$0.index] }
        )
    }
}
