import Foundation

// MARK: - When the playing picture has drifted from the sound, and how to bring it back
//
// What it does: on each time-observer tick compares the playing picture's time with the audio engine's playhead and
// says what to do: nothing; run the picture a little slower or faster until it is back on the sound (`.rate`), then at
// normal speed again; or, beyond `replaceBeyond`, place the picture again with the sound held (`.replace`). It acts on
// the second tick in a row that is more than a frame apart (one stray tick is ignored) and counts corrections for
// smoke results (docs/architecture/audio-engine.md 第三节).
// Why a rate and not a seek: before 2026-11-20 every correction re-seeked the picture (`setRate(_:time:atHostTime:)`),
// which decodes from the keyframe: on a long GOP the picture froze for 0.1–0.4 s under the running sound
// (docs/bugfixes/2026-11-20-idle-start-picture-ahead-and-lost-sound.md). Changing `AVPlayer.rate` keeps the decoded
// frames flowing (probe of 2026-11-20: no time jump, longest frame 44 ms at 0.8×).
// Split out of VideoPreviewView.swift on 2026-11-19.
// What it does not do: touch the player or log (PlayerClock).
struct VideoDriftCheck {
    enum Action: Equatable {
        case none
        /// Set the picture's rate (1 ends a correction).
        case rate(Float)
        /// Too far apart to run back in step: hold the sound, place the picture at it, start both.
        case replace
    }

    /// Further apart than this on one tick is drift (a frame at 25 fps).
    static let threshold: TimeInterval = 0.04
    /// A correction aims to close the gap in this long...
    static let catchUp: TimeInterval = 0.5
    /// ...running the picture at most this much slower or faster (0.75–1.25×).
    static let maxRateChange = 0.25
    /// Beyond this a rate change would take over a second: place the picture again instead.
    static let replaceBeyond: TimeInterval = 0.25

    private var ticks = 0
    /// While a rate correction runs: when it ends (host seconds).
    private var correctingUntil: TimeInterval?
    private(set) var corrections = 0
    /// When the last correction went into the stall log: of a run of corrections only the first is written.
    private var lastNote: TimeInterval = 0

    /// A rate correction is running: the picture is not at normal speed.
    var isCorrecting: Bool { correctingUntil != nil }

    mutating func reset() {
        ticks = 0
        correctingUntil = nil
    }

    /// The stall log's line for a correction that started (`.rate(1)` ends one), at most one a second.
    mutating func note(_ action: Action, video: TimeInterval, audio: TimeInterval, now: TimeInterval) -> String? {
        guard action != .none, action != .rate(1), now - lastNote > 1 else { return nil }
        lastNote = now
        return String(format: "Picture %.3f s, sound %.3f s (%.0f ms apart): %@", video, audio, abs(video - audio) * 1000,
                      action == .replace ? "both land again" : "the picture runs to the sound")
    }

    /// The picture (`video`) against the sound (`audio`), both read at host time `now`.
    mutating func observe(video: TimeInterval, audio: TimeInterval, now: TimeInterval) -> Action {
        if let end = correctingUntil {
            guard now >= end else { return .none }
            reset()
            return .rate(1)
        }
        let offset = video - audio
        guard abs(offset) > Self.threshold else {
            ticks = 0
            return .none
        }
        ticks += 1
        guard ticks >= 2 else { return .none }
        ticks = 0
        corrections += 1
        guard abs(offset) <= Self.replaceBeyond else { return .replace }
        let change = min(Self.maxRateChange, abs(offset) / Self.catchUp)
        correctingUntil = now + abs(offset) / change
        return .rate(Float(offset > 0 ? 1 - change : 1 + change))
    }
}
