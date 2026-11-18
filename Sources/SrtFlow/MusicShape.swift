import Accelerate
import Foundation

// MARK: - Music: where it hits, where it stops by itself, where it ends (pure)
//
// What this owns: one piece of music read as mono samples → its accents (MusicAccents), the stretches where it stops by itself
// and comes back, and where its own sound ends (MusicStops), with the 0.1 s levels both use (MusicLevels). listen beats=true
// reports it next to the beats, add_clips uses the strongest accent as the default hit for hit_at, and a generated music job's
// get_job carries it (production feedback MCP-43; docs/architecture/listening-engine.md section 9).
// What it does not own: reading the samples and caching (AIBeats, on MediaReadQueue.analysis), the beat (AudioBeatTracker),
// what the AI reads (AIMusicShapeReport), placing a clip by its hit (AIClipHit).
//
// Times are seconds from the first sample handed in; AIBeats shifts them by the read's first timestamp (`shifted(by:)`).

enum MusicShape {
    /// One accent: when it hits and how far it stands out (the onset strength in standard deviations above this piece's
    /// average; about 3 is barely, 10 and more a big hit). Strengths compare within one piece, not between pieces.
    struct Accent: Equatable, Sendable {
        var time: Double
        var strength: Double
    }

    /// Where the piece stops by itself: from where it falls quiet to where it comes back (the accent that brings it back
    /// when there is one).
    struct Stop: Equatable, Sendable {
        var from: Double
        var to: Double
    }

    struct Analysis: Equatable, Sendable {
        /// Every audible accent, in time order.
        var accents: [Accent]
        var stops: [Stop]
        /// Where the piece's own sound is over (it stays 20 dB under its playing level from here on); the end of the samples
        /// when it plays to the end. nil = silent.
        var end: Double?
        var duration: Double

        static let silent = Analysis(accents: [], stops: [], end: nil, duration: 0)

        func shifted(by offset: Double) -> Analysis {
            Analysis(
                accents: accents.map { Accent(time: $0.time + offset, strength: $0.strength) },
                stops: stops.map { Stop(from: $0.from + offset, to: $0.to + offset) },
                end: end.map { $0 + offset },
                duration: duration
            )
        }
    }

    static func analyze(_ samples: [Float], sampleRate: Double) -> Analysis {
        guard sampleRate > 0, !samples.isEmpty else { return .silent }
        let levels = MusicLevels(samples, sampleRate: sampleRate)
        guard levels.playing != nil else {
            return Analysis(accents: [], stops: [], end: nil, duration: Double(samples.count) / sampleRate)
        }
        let duration = Double(samples.count) / sampleRate
        let accents = MusicAccents.find(samples, sampleRate: sampleRate, levels: levels)
        let (stops, end) = MusicStops.find(levels, accents: accents)
        return Analysis(accents: accents, stops: stops, end: end.map { min($0, duration) }, duration: duration)
    }
}

// MARK: - Levels every 0.1 s

/// RMS levels (dBFS) of consecutive 0.1 s steps and the piece's playing level. A step is exact (its edges are rounded sample
/// positions, so steps do not drift over a long piece).
struct MusicLevels: Equatable, Sendable {
    static let step = 0.1
    /// Steps more than this under the loudest one do not count towards the playing level (silence, a fade's last steps).
    /// Relative, so the same piece 30 dB quieter has the same playing level minus 30.
    static let audibleRange = 60.0
    /// A piece whose loudest step is under this is silent.
    static let silentBelow = -90.0
    /// Which loud step is "playing": the 90th percentile of the audible steps (a quiet intro and the stops don't pull it down).
    static let playingPercentile = 0.9

    /// Step i covers [i × step, (i + 1) × step) of the samples.
    var decibels: [Double]
    /// nil when the piece is silent.
    var playing: Double?

    init(_ samples: [Float], sampleRate: Double) {
        let count = Int((Double(samples.count) / sampleRate / Self.step).rounded(.up))
        var levels = [Double](repeating: -100, count: count)
        samples.withUnsafeBufferPointer { buffer in
            for index in 0..<count {
                let first = Int((Double(index) * Self.step * sampleRate).rounded())
                let last = min(buffer.count, Int((Double(index + 1) * Self.step * sampleRate).rounded()))
                guard last > first, let base = buffer.baseAddress else { continue }
                var meanSquare: Float = 0
                vDSP_measqv(base + first, 1, &meanSquare, vDSP_Length(last - first))
                levels[index] = max(-100, 10 * log10(Double(meanSquare) + 1e-12))
            }
        }
        decibels = levels
        guard let loudest = levels.max(), loudest >= Self.silentBelow else { return }
        let audible = levels.filter { $0 > loudest - Self.audibleRange }.sorted()
        playing = audible[min(audible.count - 1, Int(Double(audible.count) * Self.playingPercentile))]
    }

    /// The louder of the step holding `time` and the next one: a hit at the end of a step still counts as heard.
    func level(at time: Double) -> Double {
        let index = Int((time / Self.step).rounded(.down))
        let here = decibels.indices.contains(index) ? decibels[index] : -100
        let next = decibels.indices.contains(index + 1) ? decibels[index + 1] : -100
        return max(here, next)
    }
}
