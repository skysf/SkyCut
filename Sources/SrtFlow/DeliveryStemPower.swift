import Foundation

// MARK: - Each stem's power per project frame and nothing else (blocking; only on a MediaReadQueue queue)
//
// Owns: rendering a split configuration (DeliveryStemSplit) over some project frames with AudioStemRender and adding up each
// layer's mean square per frame — the two channels averaged, only the part of a frame inside the timeline: MixBandMeter's
// overall level — and handing every block to `observe` for whoever needs the samples (the music's band meter and accents, the
// cut windows above 200 Hz). It starts early only for a sound scene's tail and half a frame. MixMeasurement would also preroll
// 3 s and run the bus meter (short-term loudness, true peak, the limiter): the report reads those from its own first-tier
// measurement, and here they doubled every inspection's render (2026-11-18: the inspection check's debug build ran past its
// deadline on CI).
// Not here: what the layers are (AIDeliverySoundLevels, AIDeliveryLinger), bands (MixBandMeter), the rules.

enum DeliveryStemPower {
    /// Each layer's mean square for every frame in `frames` (same order as `layers`). Blocking; `isCancelled` is asked every block.
    static func measure(
        _ config: AudioEngineConfig, layers: [AudioStemLayer], grid: MixFrameGrid, frames: Range<Int>, isCancelled: () -> Bool,
        observe: (AudioStemRender.Block) -> Void = { _ in }
    ) throws -> [[Double]] {
        let rate = Double(grid.sampleRate)
        let limit = Int64((config.duration * rate).rounded())
        let first = grid.start(ofFrame: frames.lowerBound), last = min(grid.start(ofFrame: frames.upperBound), limit)
        var sums = layers.map { _ in [Double](repeating: 0, count: frames.count) }
        guard last > first, !layers.isEmpty else { return sums }
        let tail = config.tracks.contains { $0.segments.contains { $0.scene != nil } } ? SceneRecipe.maximumTail : 0
        let quantum = Int64(TimelineAudioEngine.offlineQuantum)
        let early = first - max(grid.halfFrame, Int64((tail * rate).rounded(.up)))
        let start = early > 0 ? early / quantum * quantum : 0
        let end = min(limit, last + grid.halfFrame + 1)
        var counts = [Int](repeating: 0, count: frames.count)
        var cancelled = false
        try AudioStemRender.render(config, layers: layers, from: start, to: end) { block in
            if isCancelled() {
                cancelled = true
                return false
            }
            observe(block)
            var frame = grid.frame(ofSample: block.position)
            var next = grid.start(ofFrame: frame + 1)
            for index in 0 ..< block.frames {
                let sample = block.position + Int64(index)
                while sample >= next {
                    frame += 1
                    next = grid.start(ofFrame: frame + 1)
                }
                guard sample < limit, frames.contains(frame) else { continue }
                let slot = frame - frames.lowerBound
                counts[slot] += 1
                for layer in layers.indices {
                    let left = Double(block.layers[layer][index * 2]), right = Double(block.layers[layer][index * 2 + 1])
                    sums[layer][slot] += (left * left + right * right) / 2
                }
            }
            return true
        }
        if cancelled { throw CancellationError() }
        return sums.map { layer in zip(layer, counts).map { $1 > 0 ? $0 / Double($1) : 0 } }
    }
}
