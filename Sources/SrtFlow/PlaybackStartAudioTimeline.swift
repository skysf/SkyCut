#if DEBUG
// MARK: - Where the sound stood at a host time (playback-start benchmark)
//
// What it does: reads the sound's timeline position at a host time from the audible blocks the benchmark's audio probe
// recorded, one block per render quantum from its first audible sample. Consecutive blocks can leave a sliver between
// them (a block starts at its first audible sample; device timestamps jitter): a moment up to 5 ms past a block reads
// that block, a longer gap is missing sound. On 2026-11-19 three of 24 hosted runs failed because no block covered the
// first picture (docs/architecture/playback-start.md).
// What it does not do: record the blocks (PlaybackStartAudioProbe) or score them (checks/PlaybackStart/compare.py).
struct PlaybackStartAudioBlock {
    let host: Double
    let renderedAt: Double
    let timeline: Double
    let duration: Double

    var onset: Double { max(renderedAt, host) }
}

enum PlaybackStartAudioTimeline {
    static let gapTolerance = 0.005

    /// The timeline at `host`; before the first block, extrapolated from it when asked.
    static func timeline<Blocks: RandomAccessCollection>(
        of blocks: Blocks, at host: Double, extrapolateFirst: Bool = false
    ) -> Double? where Blocks.Element == PlaybackStartAudioBlock {
        if extrapolateFirst, let first = blocks.first, host < first.host {
            return first.timeline + host - first.host
        }
        var previous: PlaybackStartAudioBlock?
        for block in blocks {
            if host < block.host { break }
            if host < block.host + block.duration { return block.timeline + host - block.host }
            previous = block
        }
        guard let previous, host < previous.host + previous.duration + gapTolerance else { return nil }
        return previous.timeline + host - previous.host
    }

    /// How far `host` lies past the end of the last block before it, for a failure message.
    static func gap<Blocks: RandomAccessCollection>(
        of blocks: Blocks, at host: Double
    ) -> Double? where Blocks.Element == PlaybackStartAudioBlock {
        blocks.last { $0.host <= host }.map { host - ($0.host + $0.duration) }
    }
}
#endif
