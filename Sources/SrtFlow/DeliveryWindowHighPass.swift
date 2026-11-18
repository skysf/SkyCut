import Foundation

// MARK: - How loud a stretch of a rendered stem is above a frequency, the research's way (collection blocking, maths pure)
//
// Owns: keeping a rendered stem's stereo samples for a few short windows (the 0.3 s on each side of every picture cut) while the
// render streams past (`DeliveryWindowCollector`), and the power above a cutoff of one window: every frequency below it removed
// over the window as a whole, nothing tapered (FFT, bins under the cutoff set to zero, Parseval) — exactly how the human-film
// and preview-board measurements took "the sound of the place above 200 Hz" (joins-human.md; MCP-37's "or above 200 Hz"). The
// engine's band meter splits at 300 Hz with a two-frame window; at 200 Hz a rumble under both shots still hides most of a jump.
// Power is the mean of the two channels' mean squares, like MixBandMeter's. A window is measured and its samples dropped as soon
// as the render has passed it, so memory stays at a window or two however many cuts there are.
// Not here: which windows (AIDeliveryCutJumps.windows), the render (AIDeliverySoundLevels.measure).

final class DeliveryWindowCollector {
    let windows: [ClosedRange<Double>]
    let sampleRate: Double
    let cutoff: Double
    /// Each complete window's power above `cutoff` (mean square). A window the render did not reach in full is not here.
    private(set) var powers: [ClosedRange<Double>: Double] = [:]
    private let ranges: [Range<Int64>]
    private var left: [[Float]]
    private var right: [[Float]]
    private var transforms: [Int: ListeningDFT] = [:]

    init(windows: [ClosedRange<Double>], sampleRate: Double, cutoff: Double) {
        self.windows = windows
        self.sampleRate = sampleRate
        self.cutoff = cutoff
        ranges = windows.map { Int64(($0.lowerBound * sampleRate).rounded()) ..< Int64(($0.upperBound * sampleRate).rounded()) }
        left = ranges.map { _ in [] }
        right = left
    }

    /// One rendered block of the stem (interleaved stereo) starting at timeline sample `position`.
    func add(_ block: UnsafeBufferPointer<Float>, at position: Int64, frames: Int) {
        let end = position + Int64(frames)
        for (index, range) in ranges.enumerated() where range.lowerBound < end && range.upperBound > position {
            if left[index].isEmpty { left[index].reserveCapacity(range.count); right[index].reserveCapacity(range.count) }
            for sample in max(range.lowerBound, position) ..< min(range.upperBound, end) {
                let offset = Int(sample - position) * 2
                left[index].append(block[offset])
                right[index].append(block[offset + 1])
            }
            if left[index].count == range.count { finish(index) }
        }
    }

    private func finish(_ index: Int) {
        let count = left[index].count
        guard count > 1 else { return }
        let dft = transforms[count] ?? ListeningDFT(length: count)
        transforms[count] = dft
        let power = [left[index], right[index]].map {
            Self.power(above: cutoff, samples: $0.map(Double.init), sampleRate: sampleRate, dft: dft)
        }
        powers[windows[index]] = (power[0] + power[1]) / 2
        left[index] = []
        right[index] = []
    }

    /// Mean square of `samples` with every frequency under `cutoff` removed over the whole stretch.
    static func power(above cutoff: Double, samples: [Double], sampleRate: Double, dft: ListeningDFT) -> Double {
        let n = samples.count
        guard n > 1 else { return 0 }
        let spectrum = dft.realForward(samples)
        var energy = 0.0
        for bin in spectrum.re.indices where Double(bin) * sampleRate / Double(n) >= cutoff {
            let magnitude = spectrum.re[bin] * spectrum.re[bin] + spectrum.im[bin] * spectrum.im[bin]
            // Parseval for a real signal: the bins between DC and the highest count twice.
            energy += (bin == 0 || (n % 2 == 0 && bin == n / 2)) ? magnitude : 2 * magnitude
        }
        return energy / Double(n) / Double(n)
    }
}
