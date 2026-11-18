import Accelerate
import Foundation

// MARK: - Music accents: every hit that stands out, and how much (pure)
//
// What this owns: mono samples → the moments the music hits (a drum, an orchestra hit, the music coming back after a stop),
// each with a strength. Used by MusicShape (listen beats=true, add_clips hit_at, a generated music job's get_job; MCP-43).
// What it does not own: the beat (AudioBeatTracker: a regular grid, not every hit), levels and stops (MusicLevels, MusicStops).
//
// How (the method of the production research's own music measurement, V2-W15, rewritten here; docs/architecture/listening-engine.md
// section 9):
// - Frames of 512 samples every 128 (at 11025 Hz: 46 ms every 11.6 ms, AudioBeatTracker's grid), Hann window.
// - A frame's energy is its magnitude below 200 Hz plus 0.3 × its magnitude from 200 Hz to 4 kHz: hits that carry the music are
//   low (kick, timpani, a bass hit); the mids still count so a hit without a low end is heard too.
// - The rise of its log (`log(e + floor)`, floor 50 dB under the loud frames: the same piece 30 dB quieter gives the same
//   accents), only upward, in standard deviations above the piece's average = the strength. A peak higher than 3 and the highest
//   within ±4 frames (±46 ms) is an accent, if it is heard: the 0.1 s level there is within 30 dB of the playing level.
//   The floor sets how much a rise out of silence counts: at 60 dB under, music1_box's first note (out of the file's start)
//   tied with the hit after its 2 s stop (both 21.8); at 40 dB the attack was found up to 35 ms late. 50 dB: 18.6 against 16.6,
//   and the times stay on the attacks.
// - The samples start after 512 zeros, so music that starts with a hit has an accent at its start.
// - Time: the frame where the rise peaks + one hop + half a frame, so on the hop's grid: on the synthetic kicks of
//   MusicShapeChecks it lands 4 ms before to 7 ms after the attack (the beat tracker's plain frame centre was a hop earlier).
//   A frame is 33–42 ms, so this is well inside one.

enum MusicAccents {
    static let frameSize = 512
    static let hop = 128
    static let lowCutoff = 200.0
    static let highCutoff = 4000.0
    static let midWeight: Float = 0.3
    /// Strength from which a rise is an accent.
    static let threshold = 3.0
    /// An accent is the highest rise within this many frames each side.
    static let neighbourhood = 4
    /// The level at an accent must be within this many dB of the piece's playing level.
    static let audibleRange = 30.0
    /// The log floor, as a fraction of the loud frames' energy (−50 dB; the energy is a magnitude sum).
    static let floorFraction: Float = 0.003

    static func find(_ samples: [Float], sampleRate: Double, levels: MusicLevels) -> [MusicShape.Accent] {
        guard let playing = levels.playing else { return [] }
        let energy = frameEnergy([Float](repeating: 0, count: frameSize) + samples, sampleRate: sampleRate)
        guard energy.count > 2 else { return [] }
        let loud = energy.sorted()[min(energy.count - 1, energy.count * 9 / 10)]
        guard loud > 0 else { return [] }
        let floor = loud * floorFraction
        let logs = energy.map { log(Double($0 + floor)) }
        var rise = [Double](repeating: 0, count: logs.count)
        for index in 1..<logs.count { rise[index] = max(0, logs[index] - logs[index - 1]) }
        let mean = rise.reduce(0, +) / Double(rise.count)
        let deviation = (rise.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(rise.count)).squareRoot()
        guard deviation > 0 else { return [] }
        let strength = rise.map { ($0 - mean) / deviation }
        let padding = Double(frameSize) / sampleRate
        var accents: [MusicShape.Accent] = []
        for index in strength.indices where strength[index] > threshold {
            let low = max(0, index - neighbourhood)
            let high = min(strength.count - 1, index + neighbourhood)
            guard strength[low...high].max() == strength[index], !strength[low..<index].contains(strength[index]) else { continue }
            let time = (Double((index + 1) * hop) + Double(frameSize) / 2) / sampleRate - padding
            guard time >= 0, levels.level(at: time) >= playing - audibleRange else { continue }
            accents.append(MusicShape.Accent(time: time, strength: strength[index]))
        }
        return accents
    }

    /// Each frame's weighted magnitude: below `lowCutoff` in full, `lowCutoff`–`highCutoff` × `midWeight`.
    static func frameEnergy(_ samples: [Float], sampleRate: Double) -> [Float] {
        guard samples.count >= frameSize else { return [] }
        let log2n = vDSP_Length(log2(Double(frameSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        let half = frameSize / 2
        let binHz = sampleRate / Double(frameSize)
        let lowBins = min(half, Int((lowCutoff / binHz).rounded(.up)))
        let highBins = min(half, Int((highCutoff / binHz).rounded(.up)))
        var window = [Float](repeating: 0, count: frameSize)
        vDSP_hann_window(&window, vDSP_Length(frameSize), Int32(vDSP_HANN_DENORM))
        var windowed = [Float](repeating: 0, count: frameSize)
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)
        var energy: [Float] = []
        energy.reserveCapacity((samples.count - frameSize) / hop + 1)
        var start = 0
        while start + frameSize <= samples.count {
            samples.withUnsafeBufferPointer { buffer in
                vDSP_vmul(buffer.baseAddress! + start, 1, window, 1, &windowed, 1, vDSP_Length(frameSize))
            }
            real.withUnsafeMutableBufferPointer { realBuffer in
                imag.withUnsafeMutableBufferPointer { imagBuffer in
                    var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imagBuffer.baseAddress!)
                    windowed.withUnsafeBufferPointer { input in
                        input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    // Bin 0 holds DC and Nyquist (zrip's packing): an accent never comes from them.
                    split.realp[0] = 0
                    split.imagp[0] = 0
                    vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(half))
                }
            }
            var low: Float = 0
            var mid: Float = 0
            magnitudes.withUnsafeBufferPointer { buffer in
                vDSP_sve(buffer.baseAddress!, 1, &low, vDSP_Length(lowBins))
                if highBins > lowBins { vDSP_sve(buffer.baseAddress! + lowBins, 1, &mid, vDSP_Length(highBins - lowBins)) }
            }
            energy.append(low + midWeight * mid)
            start += hop
        }
        return energy
    }
}
