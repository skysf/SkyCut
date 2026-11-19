import AVFoundation

// MARK: - Picture and sound start together (docs/architecture/playback-start.md)
//
// What it does: where a pause leaves the playhead, the sound and the picture (`PausedPictureHold`), so that the next Play
// starts the sound with a picture that moves at once; and the wait for an output that has just started to render
// (`OutputStartWait`), so that Play does not start the picture ahead of a sound still waiting for the device.
// Split out of VideoPreviewView.swift on 2026-11-19.
// What it does not do: seek, preroll or start the player (PlayerClock).

/// Where a pause leaves the playhead: on the frame the picture stopped on, when picture and sound stopped together. The
/// sound moves there too (a few milliseconds), so the next Play continues the picture without a native seek. Before
/// 2026-11-19 the next Play sent the sound from the clock's last tick and re-seeked the picture there; on a long-GOP
/// source the picture stayed frozen for 0.8 s while the sound played
/// (docs/bugfixes/2026-11-19-resume-and-hover-froze-the-picture.md).
/// The stopped time comes from the item's timebase once it has stopped (usually inside `pause()`), or else from the time
/// observer, which AVFoundation also calls when playback stops. A stopped `CMTimebase` is read without the player's
/// queue (`currentTime()` waits on it: checks/player-time-no-sync-read.sh). A picture that did not stop where the sound
/// did (a stall, a drift correction still seeking) is placed precisely at the sound instead, and a Play pressed
/// meanwhile waits for it.
enum PausedPictureHold {
    /// Picture and sound this close at a pause are the same moment; beyond it (1.5 frames at 30 fps) the picture is
    /// placed again at the sound. Drift correction acts beyond 40 ms.
    static let tolerance: TimeInterval = 0.05

    /// The position to hold: the stopped picture's time, or nil when the picture is not where the sound stopped (a
    /// stall, a drift correction still seeking) and has to be placed at the sound instead.
    static func position(picture: CMTime, sound: TimeInterval) -> TimeInterval? {
        guard picture.isNumeric, abs(picture.seconds - sound) <= tolerance else { return nil }
        return max(0, picture.seconds)
    }
}

/// Play on an output that is not rendering (stopped by the two-minute idle rule, or restarted after a system stop): the
/// device starts inside Play and renders some milliseconds after the start returns, and a device start slows every
/// thread of the process for a while. Before 2026-11-20 the picture started at once and ran up to 170 ms ahead of the
/// sound, and the drift correction then re-seeked it (docs/bugfixes/2026-11-20-idle-start-picture-ahead-and-lost-sound.md).
/// Now the clock holds both until the output renders, checked every 2 ms on the main run loop, so the start also waits
/// for the main thread to come back from the device's start (started in the same turn, `playImmediately` took 11–111 ms
/// in 3 of 8 cold starts on the M1). After `limit` it starts regardless: an output that never renders must not keep
/// Play pending.
/// Not a scheduled start: `setRate(_:time:atHostTime:)` with any host time but the present re-seeks the picture (a
/// 0.35–0.42 s freeze seven seconds into a 1080p GOP, probe of 2026-11-20).
final class OutputStartWait {
    static let limit: TimeInterval = 1.5
    private var timer: Timer?
    /// The wait is over (the output rendered or the limit passed) and its Play has not started yet.
    private(set) var ended = false

    var isWaiting: Bool { timer != nil }

    func cancel() {
        timer?.invalidate()
        timer = nil
        ended = false
    }

    /// `start` runs once, when `ready` holds or the limit is over, unless cancelled first.
    func begin(until ready: @escaping () -> Bool, then start: @escaping () -> Void) {
        cancel()
        let deadline = ProcessInfo.processInfo.systemUptime + Self.limit
        let timer = Timer(timeInterval: 0.002, repeats: true) { [weak self] _ in
            guard let self, ready() || ProcessInfo.processInfo.systemUptime > deadline else { return }
            self.timer?.invalidate()
            self.timer = nil
            self.ended = true
            start()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}

/// A start that stalled inside `playImmediately`: the picture's timebase already moved when the call returned (46–70 ms
/// in 2 of 10 cold starts on the M1 after the wait above while the rate observation's subscribers still ran inside the
/// call; none in 10 since they run after both starts, `PlayerClock.startClocks`). The sound would then start that much
/// behind the picture on the output's next quantum; instead it is pinned to the picture's own start
/// (`play(from:alignedToHostTime:)`) and loses that much of its beginning, in step. A start that returned at once keeps
/// the next quantum: no sound lost, the picture 10–25 ms ahead as usual.
enum PictureStart {
    /// Moved further than this when the start returned: pin the sound to the picture.
    static let stallTolerance: TimeInterval = 0.01

    /// Starts the picture from its placed, primed `start`, then the sound from the same position: on the output's next
    /// quantum, or pinned to the picture's own start when the call stalled after the picture had begun to move.
    static func begin(_ player: AVPlayer, with source: PlaybackAudioSource, from start: TimeInterval) {
        player.playImmediately(atRate: 1)
        if let host = stalled(player.currentItem, from: start) {
            source.play(from: start, alignedToHostTime: host)
        } else {
            source.play(from: start)
        }
    }

    /// The host time at which `item`'s picture left `start`, if it has moved more than `stallTolerance` by now.
    static func stalled(_ item: AVPlayerItem?, from start: TimeInterval) -> UInt64? {
        guard let timebase = item?.timebase else { return nil }
        return host(moved: CMTimebaseGetTime(timebase).seconds - start, now: mach_absolute_time())
    }

    /// `now` less how far the picture has moved, if that is more than `stallTolerance`.
    static func host(moved: TimeInterval, now: UInt64) -> UInt64? {
        guard moved.isFinite, moved > stallTolerance else { return nil }
        return AVAudioTime.hostTime(forSeconds: max(0, AVAudioTime.seconds(forHostTime: now) - moved))
    }
}
