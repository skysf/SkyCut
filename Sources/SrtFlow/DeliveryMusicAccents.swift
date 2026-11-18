import Accelerate
import Foundation

// MARK: - Where music hits: strong onsets weighted to the low end, the reading the human film's cuts were measured with (pure)
//
// Owns: one channel of music → its accents (time from the first sample, strength). The reading is the research's (human-edit
// tools/music.py `accents`, used for joins-human.md and preview board v1.1): 1024-sample Hann frames every 256 samples; each
// frame's energy = the magnitudes under 200 Hz plus 0.3 × those from 200 Hz to 4 kHz (drums, a bass coming in, a hit); the rise of
// log(1 + energy) from frame to frame, never negative; as a z-score over the whole stretch; an accent is a z above
// `minimumStrength` that is the largest within ±`neighbourhood` frames. MCP-37 counts a music accent within ±3 frames of a
// cut as covering a jump there; 7 of the human film's 23 covered cuts were covered that way.
// Why not AudioBeatTracker's onset strength (listen beats, cut_to_beat): it is built to find a beat — six bands weighted
// equally, a local mean taken off, and nothing at all when the music has no clear onsets — so orchestral music with soft
// attacks came back without a single accent where the human film's cuts sit on them.
// Not here: which music and where it is heard (AIDeliverySoundLevels), the cut rule (AIDeliveryCutJumps).

enum DeliveryMusicAccents {
    static let frameSize = 1024
    static let hop = 256
    static let lowEdge = 200.0
    static let highEdge = 4_000.0
    static let upperWeight = 0.3
    /// A z-score this high (and the largest around it) is an accent.
    static let minimumStrength = 3.0
    static let neighbourhood = 4

    static func accents(_ samples: [Float], sampleRate: Double) -> [(time: Double, strength: Double)] {
        let flux = rise(samples, sampleRate: sampleRate)
        guard flux.count > 2 * neighbourhood + 1 else { return [] }
        let mean = flux.reduce(0, +) / Double(flux.count)
        let spread = (flux.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(flux.count)).squareRoot()
        guard spread > 0 else { return [] }
        let z = flux.map { ($0 - mean) / spread }
        var found: [(time: Double, strength: Double)] = []
        for index in neighbourhood ..< z.count - neighbourhood where z[index] > minimumStrength {
            guard z[index] == z[(index - neighbourhood) ... (index + neighbourhood)].max() else { continue }
            found.append((Double(index * hop) / sampleRate + Double(frameSize) / sampleRate / 2, z[index]))
        }
        return found
    }

    /// Frame to frame, how much log(1 + low-weighted magnitude) grows (0 when it falls).
    static func rise(_ samples: [Float], sampleRate: Double) -> [Double] {
        guard samples.count >= frameSize * 2 else { return [] }
        let log2n = vDSP_Length(log2(Double(frameSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        let half = frameSize / 2
        // numpy's hanning(M): symmetric, 0.5 − 0.5 cos(2πn / (M − 1)).
        let window = (0 ..< frameSize).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(frameSize - 1))) }
        let binWidth = sampleRate / Double(frameSize)
        var windowed = [Float](repeating: 0, count: frameSize)
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var energies: [Double] = []
        var start = 0
        while start + frameSize <= samples.count {
            samples.withUnsafeBufferPointer { vDSP_vmul($0.baseAddress! + start, 1, window, 1, &windowed, 1, vDSP_Length(frameSize)) }
            var energy = 0.0
            real.withUnsafeMutableBufferPointer { realBuffer in
                imag.withUnsafeMutableBufferPointer { imagBuffer in
                    var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imagBuffer.baseAddress!)
                    windowed.withUnsafeBufferPointer { input in
                        input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half)) }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    // zrip returns twice the DFT and packs the Nyquist bin into imagp[0] (above 4 kHz: not used).
                    for bin in 0 ..< half {
                        let frequency = Double(bin) * binWidth
                        guard frequency < highEdge else { break }
                        let re = Double(split.realp[bin]) / 2, im = bin == 0 ? 0 : Double(split.imagp[bin]) / 2
                        let magnitude = (re * re + im * im).squareRoot()
                        energy += frequency < lowEdge ? magnitude : upperWeight * magnitude
                    }
                }
            }
            energies.append(log1p(energy))
            start += hop
        }
        return zip(energies.dropFirst(), energies).map { max(0, $0 - $1) }
    }
}
