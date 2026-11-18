import Foundation

// MARK: - Lowering only the voice band of a sound (pure DSP, real-time safe)
//
// Owns (MCP-30, 2026-11-18): the filter behind `EditClip.voiceBandDB` — a three-way split at 300 Hz and 3 kHz whose bands
// add back up to the input at every frequency (Linkwitz–Riley crossovers of the 4th order: each is two Butterworth biquads in
// a row, and the low band goes through the 3 kHz crossover's all-pass so all three stay in phase), so the middle band alone can
// be scaled: out = low + g · mid + high. With g = 1 the three bands sum to an all-pass (flat level, a phase shift only).
// Lows under 300 Hz keep their level (a hit's weight), the voice band 300–3000 Hz goes down by g, the highs stay.
// Double-precision state and coefficients (the 300 Hz sections sit close to the unit circle at 48 kHz). No allocation: the
// renderer owns one per stream per channel pair, resets it when the position jumps (seek, start: like the scene chain) and
// moves g linearly across a block when it changes (no zipper). Started or stopped mid-stream it crossfades with the dry sound
// (`VoiceBandRendering`), so a stream set back to 0 dB plays exactly what the export plays.
// Not here: when the engine runs it (AudioTrackRenderer), what a clip asks for (VoiceBand, EditClip.voiceBandDB).

struct VoiceBandFilter: Sendable {
    /// The band's edges (Hz) and the engine's rate.
    static let low = 300.0
    static let high = 3_000.0
    static let rate = 48_000.0

    /// One biquad, transposed direct form II.
    struct Biquad: Sendable {
        let b0, b1, b2, a1, a2: Double
        var z1 = 0.0, z2 = 0.0

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }

        mutating func reset() { z1 = 0; z2 = 0 }

        enum Kind { case lowPass, highPass, allPass }

        /// RBJ cookbook sections with Q = 1/√2 (Butterworth; the Linkwitz–Riley all-pass has the same Q).
        init(_ kind: Kind, frequency: Double, rate: Double = VoiceBandFilter.rate) {
            let w0 = 2 * Double.pi * frequency / rate
            let cosine = cos(w0), alpha = sin(w0) / (2 * (1 / 2.0.squareRoot()))
            let a0 = 1 + alpha
            switch kind {
            case .lowPass:
                (b0, b1, b2) = ((1 - cosine) / 2 / a0, (1 - cosine) / a0, (1 - cosine) / 2 / a0)
            case .highPass:
                (b0, b1, b2) = ((1 + cosine) / 2 / a0, -(1 + cosine) / a0, (1 + cosine) / 2 / a0)
            case .allPass:
                (b0, b1, b2) = ((1 - alpha) / a0, -2 * cosine / a0, (1 + alpha) / a0)
            }
            a1 = -2 * cosine / a0
            a2 = (1 - alpha) / a0
        }
    }

    /// One channel's nine sections.
    struct Channel: Sendable {
        var lowA = Biquad(.lowPass, frequency: VoiceBandFilter.low)
        var lowB = Biquad(.lowPass, frequency: VoiceBandFilter.low)
        var lowAllPass = Biquad(.allPass, frequency: VoiceBandFilter.high)
        var restA = Biquad(.highPass, frequency: VoiceBandFilter.low)
        var restB = Biquad(.highPass, frequency: VoiceBandFilter.low)
        var midA = Biquad(.lowPass, frequency: VoiceBandFilter.high)
        var midB = Biquad(.lowPass, frequency: VoiceBandFilter.high)
        var highA = Biquad(.highPass, frequency: VoiceBandFilter.high)
        var highB = Biquad(.highPass, frequency: VoiceBandFilter.high)

        mutating func process(_ x: Double, gain: Double) -> Double {
            let low = lowAllPass.process(lowB.process(lowA.process(x)))
            let rest = restB.process(restA.process(x))
            let mid = midB.process(midA.process(rest))
            let high = highB.process(highA.process(rest))
            return low + gain * mid + high
        }

        mutating func reset() {
            lowA.reset(); lowB.reset(); lowAllPass.reset(); restA.reset(); restB.reset()
            midA.reset(); midB.reset(); highA.reset(); highB.reset()
        }
    }

    var left = Channel()
    var right = Channel()

    mutating func reset() {
        left.reset()
        right.reset()
    }

    /// Filters `count` frames in place, the band's gain moving linearly from `from` to `to` (linear amplitudes) across them.
    mutating func process(_ leftSamples: UnsafeMutablePointer<Float>, _ rightSamples: UnsafeMutablePointer<Float>,
                          count: Int, from: Float, to: Float) {
        guard count > 0 else { return }
        let start = Double(from), step = (Double(to) - Double(from)) / Double(count)
        for index in 0..<count {
            let gain = start + step * Double(index + 1)
            leftSamples[index] = Float(left.process(Double(leftSamples[index]), gain: gain))
            rightSamples[index] = Float(right.process(Double(rightSamples[index]), gain: gain))
        }
    }

    /// As `process`, mixed with the dry input: the dry share `dry` (0 = the filter's output alone, 1 = the input alone) moves
    /// by `step` per frame toward `target`, so the filter fades in or out without a jump in phase.
    mutating func process(_ leftSamples: UnsafeMutablePointer<Float>, _ rightSamples: UnsafeMutablePointer<Float>,
                          count: Int, from: Float, to: Float, dry: inout Float, toward target: Float, step: Float) {
        guard count > 0 else { return }
        let start = Double(from), gainStep = (Double(to) - Double(from)) / Double(count)
        for index in 0..<count {
            let gain = start + gainStep * Double(index + 1)
            dry = dry < target ? min(target, dry + step) : max(target, dry - step)
            let share = Double(dry)
            let inLeft = Double(leftSamples[index]), inRight = Double(rightSamples[index])
            let outLeft = left.process(inLeft, gain: gain), outRight = right.process(inRight, gain: gain)
            leftSamples[index] = Float(outLeft + share * (inLeft - outLeft))
            rightSamples[index] = Float(outRight + share * (inRight - outRight))
        }
    }
}

/// One stream's voice band as the renderer runs it: the filter, the gain it last applied, the dry sound's share while the
/// filter fades in or out, and where it last rendered. After a jump (seek, start) it starts settled, like the export starts
/// every stream: the filter from rest when `asked` < 1, the dry sound when not. Mid-stream a new gain moves linearly across
/// the block; the filter started (`asked` drops below 1) fades in from the dry sound, and back at gain 1 (an all-pass then:
/// flat level, shifted phase) it fades out to the dry sound, each over `fadeFrames`, then stops and forgets its state. So a
/// stream set back to 0 dB plays exactly the export's samples (review CXR2 R10, 2026-11-19: it used to keep running as an
/// all-pass, and two layers of related sound summed 17 dB apart at 300 Hz live and in the export), and starting it mid-stream
/// no longer jumps by half the signal. Only the renderer touches it.
struct VoiceBandRendering: Sendable {
    /// How long the filter fades in or out against the dry sound mid-stream (frames at the engine's 48 kHz: about 21 ms).
    static let fadeFrames = 1_024
    var filter = VoiceBandFilter()
    var gain: Float = 1
    var active = false
    /// The dry sound's share of the output while the filter fades in or out (0 = the filter's output alone).
    var dry: Float = 0
    var renderedUpTo: Int64 = -1

    /// Filters the `count` frames rendered at `[from, from + count)` in place when the stream needs it (`asked` < 1, or
    /// still fading out).
    mutating func render(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, count: Int, from: Int64,
                         asked: Float) {
        if renderedUpTo != from {
            filter.reset()
            active = asked < 1
            gain = asked
            dry = 0
        } else if !active, asked < 1 {
            filter.reset()
            active = true
            gain = 1
            dry = 1
        }
        if active {
            let target: Float = asked < 1 ? 0 : 1
            if dry == 0, target == 0 {
                filter.process(left, right, count: count, from: gain, to: asked)
            } else {
                filter.process(left, right, count: count, from: gain, to: asked, dry: &dry, toward: target,
                               step: 1 / Float(Self.fadeFrames))
            }
            gain = asked
            if dry >= 1 {
                filter.reset()
                active = false
                dry = 0
            }
        }
        renderedUpTo = from + Int64(count)
    }
}
