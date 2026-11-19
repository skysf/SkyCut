import AVFoundation

// MARK: - Picture and sound start together (docs/architecture/playback-start.md)
//
// What it does: the two decisions PlayerClock needs so that the sound never starts ahead of the picture: where a pause
// leaves both (`PausedPictureHold`), and when a just-started output device can start both (`OutputStartWait`).
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

/// After Play on an output device that has just started (the idle stop, a system stop), waits until the device has
/// rendered once, silently: from then on the sound's start is a known host time, the next quantum, and the clock
/// starts the sound and the picture together there. Before 2026-11-19 the picture started at once while the sound
/// waited for the device's first render: on the M1 the picture ran up to 151 ms ahead, and the drift correction then
/// re-seeked it, a stall of up to 183 ms. Checked every 2 ms on the main run loop; after a second the start goes ahead.
final class OutputStartWait {
    private var timer: Timer?

    func cancel() {
        timer?.invalidate()
        timer = nil
    }

    /// `start` runs once, when `ready` holds or the second is over, unless cancelled first.
    func begin(until ready: @escaping () -> Bool, then start: @escaping () -> Void) {
        cancel()
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        let timer = Timer(timeInterval: 0.002, repeats: true) { [weak self] _ in
            guard ready() || ProcessInfo.processInfo.systemUptime > deadline else { return }
            self?.cancel()
            start()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
