import Foundation

// MARK: - When the playing picture has drifted from the sound
//
// What it does: on each time-observer tick compares the playing picture's time with the audio engine's playhead and
// says when to put the picture back on the sound's timeline: the second tick in a row that is more than a frame
// apart (one stray tick is ignored). Counts corrections for smoke results (docs/architecture/audio-engine.md 第三节).
// Split out of VideoPreviewView.swift on 2026-11-19.
// What it does not do: re-anchor the picture or log (PlayerClock).
struct VideoDriftCheck {
    /// Further apart than this on one tick is drift (a frame at 25 fps).
    static let threshold: TimeInterval = 0.04
    private var ticks = 0
    private(set) var corrections = 0

    mutating func reset() { ticks = 0 }

    /// True on the tick that makes two in a row: the caller re-anchors the picture now.
    mutating func observe(video: TimeInterval, audio: TimeInterval) -> Bool {
        guard abs(video - audio) > Self.threshold else {
            ticks = 0
            return false
        }
        ticks += 1
        guard ticks >= 2 else { return false }
        ticks = 0
        corrections += 1
        return true
    }
}
