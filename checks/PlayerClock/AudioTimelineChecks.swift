import Foundation

// The playback-start benchmark reads where the sound stood at the first picture from the audible blocks its probe
// recorded (Sources/SrtFlow/PlaybackStartAudioTimeline.swift). Before 2026-11-19 a picture that landed in the sliver
// between two consecutive blocks had no sound to compare with, and the hosted run failed on that alone.
func checkAudioTimeline() {
    let quantum = 512.0 / 48_000
    // Two consecutive quanta, the second starting 0.2 ms late (its first audible sample, or a jittered timestamp).
    let blocks = [
        PlaybackStartAudioBlock(host: 10, renderedAt: 10, timeline: 2, duration: quantum),
        PlaybackStartAudioBlock(host: 10 + quantum + 0.0002, renderedAt: 10, timeline: 2 + quantum + 0.0002,
                                duration: quantum),
        PlaybackStartAudioBlock(host: 10.2, renderedAt: 10.2, timeline: 2.2, duration: quantum),
    ]
    let inside = PlaybackStartAudioTimeline.timeline(of: blocks, at: 10.004)
    check(inside.map { abs($0 - 2.004) < 1e-9 } == true, "A moment inside a block reads that block: \(String(describing: inside))")
    let sliver = PlaybackStartAudioTimeline.timeline(of: blocks, at: 10 + quantum + 0.0001)
    check(sliver.map { abs($0 - (2 + quantum + 0.0001)) < 1e-9 } == true,
          "A moment in the sliver between two blocks reads the block before it: \(String(describing: sliver))")
    check(PlaybackStartAudioTimeline.timeline(of: blocks, at: 10.15) == nil,
          "A moment in a long gap has no sound to compare with")
    check(PlaybackStartAudioTimeline.timeline(of: blocks, at: 9.99) == nil,
          "A moment before the first block reads nothing unless asked to extrapolate")
    let early = PlaybackStartAudioTimeline.timeline(of: blocks, at: 9.99, extrapolateFirst: true)
    check(early.map { abs($0 - 1.99) < 1e-9 } == true, "Before the first block the timeline extrapolates back from it")
    let gap = PlaybackStartAudioTimeline.gap(of: blocks, at: 10.15)
    check(gap.map { abs($0 - (0.15 - 2 * quantum - 0.0002)) < 1e-9 } == true,
          "The failure message gives the gap after the last block: \(String(describing: gap))")
}
