import Foundation

// MARK: - listen voice=…: render the layers, cut each voice clip into lines, measure who covers each line (blocking)
//
// What: the plan's layers rendered offline with the export's engine and configuration (AudioStemRender: each layer as it
// enters the master bus, before the limiter, so the layers add up to the mix — MaskerAttribution's "remove a layer" is then
// "don't add it"). Each voice clip's stretch (plus `VoiceLines.margin` both sides) is collected from every layer, one channel
// ((L + R) / 2, as ESTOI wants); when the render has passed it, its own voice layer is cut into lines at the voice's pauses
// (VoiceLines), and every line gets `MaskerAttribution.rank`: ESTOI against the whole mix, each other layer removed / lowered
// 6 dB, and the 20–150 Hz level next to the voice's. Then the stretch's samples are dropped: memory stays a few seconds of
// a few layers, however long the timeline.
// Rendering starts `MixMeasurement.preroll` before the first stretch on the engine's quantum (scene tails and stretched clips
// come in as the export plays them) and stops at the last stretch.
// Not here: which layers and clips (AIListenVoicePlan), the verdict and the result (VoiceClarity, AIListenVoiceReport), the job.
// Only on a MediaReadQueue queue (the engine reads files on the calling thread, docs/architecture/blocking-media-reads.md).

enum AIListenVoiceMeasure {
    struct Line: Sendable {
        let clip: AIListenVoicePlan.Clip
        /// Where the voice speaks (timeline seconds, without the padding).
        let from: Double
        let to: Double
        /// nil: too little speech for ESTOI (under about 0.4 s once silence is dropped).
        let result: MaskerAttribution.Result?
    }

    /// One clip's stretch being collected: every layer's samples (one channel) from `start` (timeline sample).
    private final class Stretch {
        let clip: AIListenVoicePlan.Clip
        let start: Int64
        let end: Int64
        var layers: [[Float]]

        init(clip: AIListenVoicePlan.Clip, start: Int64, end: Int64, layers: Int) {
            self.clip = clip
            self.start = start
            self.end = end
            self.layers = Array(repeating: [], count: layers)
            for index in self.layers.indices { self.layers[index].reserveCapacity(Int(end - start)) }
        }
    }

    static let sampleRate = 48_000

    /// Blocking. `progress` gets the fraction rendered; `isCancelled` is asked every block (true → CancellationError).
    static func measure(
        _ plan: AIListenVoicePlan, config: AudioEngineConfig, isCancelled: () -> Bool = { false }, progress: (Double) -> Void = { _ in }
    ) throws -> [Line] {
        let rate = Double(sampleRate)
        let limit = Int64((config.duration * rate).rounded())
        let margin = Int64((VoiceLines.margin * rate).rounded())
        var waiting = plan.clips.map { clip in
            Stretch(clip: clip, start: max(0, Int64((clip.from * rate).rounded()) - margin),
                    end: min(limit, Int64((clip.to * rate).rounded()) + margin), layers: plan.layers.count)
        }.sorted { $0.start < $1.start }
        guard let first = waiting.first?.start, let last = waiting.map(\.end).max(), last > first else { return [] }
        let quantum = Int64(TimelineAudioEngine.offlineQuantum)
        let early = first - Int64((MixMeasurement.preroll(config) * rate).rounded(.up))
        let start = early > 0 ? early / quantum * quantum : 0
        var active: [Stretch] = []
        var lines: [Line] = []
        var cancelled = false
        try AudioStemRender.render(config, layers: plan.layers.map(\.stem), from: start, to: last) { block in
            if isCancelled() {
                cancelled = true
                return false
            }
            let blockEnd = block.position + Int64(block.frames)
            while let next = waiting.first, next.start < blockEnd { active.append(waiting.removeFirst()) }
            for stretch in active { collect(block, into: stretch) }
            for stretch in active where stretch.end <= blockEnd { lines += measureLines(stretch, plan: plan) }
            active.removeAll { $0.end <= blockEnd }
            progress(Double(blockEnd - start) / Double(max(1, last - start)))
            return true
        }
        if cancelled { throw CancellationError() }
        for stretch in active { lines += measureLines(stretch, plan: plan) }
        return lines.sorted { ($0.from, $0.clip.layer) < ($1.from, $1.clip.layer) }
    }

    /// The part of `block` inside the stretch, every layer down to one channel.
    private static func collect(_ block: AudioStemRender.Block, into stretch: Stretch) {
        let from = max(block.position, stretch.start), to = min(block.position + Int64(block.frames), stretch.end)
        guard to > from else { return }
        for (index, samples) in block.layers.enumerated() {
            for sample in from ..< to {
                let offset = Int(sample - block.position) * 2
                stretch.layers[index].append((samples[offset] + samples[offset + 1]) / 2)
            }
        }
    }

    /// The stretch's lines (its own voice layer's pauses), each measured against the other layers.
    private static func measureLines(_ stretch: Stretch, plan: AIListenVoicePlan) -> [Line] {
        let rate = Double(sampleRate)
        let voice = stretch.layers[stretch.clip.layer]
        // Lines come from the clip's own seconds; the padding on both sides is only ESTOI's window.
        let margin = Int((VoiceLines.margin * rate).rounded())
        let ownStart = min(voice.count, max(0, Int((stretch.clip.from * rate).rounded()) - Int(stretch.start)))
        let ownEnd = max(ownStart, min(voice.count, Int((stretch.clip.to * rate).rounded()) - Int(stretch.start)))
        let spoken = VoiceLines.split(Array(voice[ownStart ..< ownEnd]), rate: rate)
        return spoken.map { piece in
            let window = max(0, ownStart + piece.lowerBound - margin) ..< min(voice.count, ownStart + piece.upperBound + margin)
            let others = plan.layers.indices.filter { $0 != stretch.clip.layer }.map {
                MaskerAttribution.Layer(id: plan.layers[$0].stem.name, samples: Array(stretch.layers[$0][window]))
            }
            let result = MaskerAttribution.rank(clean: Array(voice[window]), others: others, sampleRate: rate)
            let seconds = { (index: Int) in Double(stretch.start + Int64(index)) / rate }
            return Line(clip: stretch.clip, from: seconds(ownStart + piece.lowerBound), to: seconds(ownStart + piece.upperBound), result: result)
        }
    }
}
