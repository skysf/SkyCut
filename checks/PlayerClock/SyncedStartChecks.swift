import AVFoundation
import CoreMedia
import Foundation

// Play starts the sound only with a picture that can move at once (docs/architecture/playback-start.md): a pause
// keeps the picture positioned, a hover sends the picture back to the playhead before Play, and a new item is
// primed while paused. Real PlayerClock and AVPlayer on the ffmpeg clip; the sound source runs on the host clock like
// the engine. The clock ticks every half second, so its drift correction (two late ticks in a row) cannot re-seek
// the picture inside these short windows and every native jump counted comes from starting playback. Before
// 2026-11-19 a resume and a Play after hovering re-seeked the picture after the sound had started
// (docs/bugfixes/2026-11-19-resume-and-hover-froze-the-picture.md).
private final class RecordingAudioSource: PlaybackAudioSource {
    private var position = 0.0
    private var host = ProcessInfo.processInfo.systemUptime
    private(set) var isPlaying = false
    private(set) var playedFrom: Double?
    /// Where the native picture's timebase stood when the sound was told to start.
    private(set) var pictureAtStart: Double?
    /// Moves the sound this far from the picture when it pauses (a picture that stalled behind the sound).
    var pauseOffset = 0.0
    /// A just-started output device renders for the first time at this moment (uptime seconds).
    var renderFrom = 0.0
    var isRendering: Bool { ProcessInfo.processInfo.systemUptime >= renderFrom }
    /// Pinned on the quantum after Play: the sound starts at the moment `play(from:)` is called.
    var startHostTime: UInt64? { isPlaying ? AVAudioTime.hostTime(forSeconds: host) : nil }
    weak var player: AVPlayer?
    let duration = 0.0

    private var picture: Double? { player?.currentItem?.timebase.map { CMTimebaseGetTime($0).seconds } }

    var playhead: Double { position + (isPlaying ? ProcessInfo.processInfo.systemUptime - host : 0) }

    func recoverIfNeeded() throws -> Bool { false }

    func play(from seconds: Double) {
        playedFrom = seconds
        pictureAtStart = picture
        position = seconds
        host = ProcessInfo.processInfo.systemUptime
        isPlaying = true
    }

    /// The engine stops on the picture's moment within milliseconds; this fake stops exactly there plus `pauseOffset`.
    func pause() {
        position = (picture ?? playhead) + pauseOffset
        isPlaying = false
    }

    func seek(to seconds: Double) {
        position = seconds
        host = ProcessInfo.processInfo.systemUptime
    }
}

/// Counts the native picture's discontinuous time changes (seeks, including `setRate(_:time:atHostTime:)` with a time).
private final class JumpCounter {
    private(set) var count = 0
    private var token: NSObjectProtocol?

    init(_ item: AVPlayerItem) {
        token = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.timeJumpedNotification, object: item, queue: .main
        ) { [weak self] _ in self?.count += 1 }
    }

    deinit { if let token { NotificationCenter.default.removeObserver(token) } }
}

private func pictureTime(_ clock: PlayerClock) -> Double? {
    clock.player.currentItem?.timebase.map { CMTimebaseGetTime($0).seconds }
}

/// Where the native picture stopped, once its timebase has (it can run a few milliseconds past `pause()`).
private func stoppedPicture(_ clock: PlayerClock) -> Double? {
    guard let timebase = clock.player.currentItem?.timebase, CMTimebaseGetRate(timebase) == 0 else { return nil }
    return CMTimebaseGetTime(timebase).seconds
}

private func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

private func settle(_ clock: PlayerClock) {
    waitForAudioClock { clock.player.currentItem?.status == .readyToPlay && !clock.isPositioningPreview }
}

func checkSyncedStarts(clip: URL) {
    let clock = PlayerClock(observationInterval: 0.5)
    clock.player.isMuted = true
    let source = RecordingAudioSource()
    source.player = clock.player
    let item = AVPlayerItem(url: clip)
    clock.attachItem(item)
    clock.attachAudioSource(source)
    clock.seek(to: 3)
    clock.resumeAfterPreviewRebuild(wasPlaying: false)
    settle(clock)
    check(!clock.isPositioningPreview, "The new item's paused placement finishes, priming included")

    // A new item is primed while paused: Play starts both clocks inside the call.
    clock.togglePlayback()
    check(source.isPlaying && source.playedFrom == 3, "A new item primed while paused starts at once from the playhead")

    // Pause, then Play: the sound continues from the paused picture and the picture continues without a native seek.
    pump(0.4)
    clock.togglePlayback()
    waitForAudioClock { stoppedPicture(clock).map { abs(clock.time - $0) < 0.0005 } ?? false }
    let paused = stoppedPicture(clock) ?? -1
    check(abs(clock.time - paused) < 0.0005 && abs(source.playhead - paused) < 0.0005 && !clock.isPositioningPreview,
          "Pausing puts the playhead and the sound on the paused picture: clock \(clock.time), sound \(source.playhead), picture \(paused)")
    pump(0.3)
    let resumeJumps = JumpCounter(item)
    clock.togglePlayback()
    check(source.isPlaying && source.playedFrom == clock.time, "Resuming starts at once from the paused picture")
    pump(0.2)
    check(resumeJumps.count == 0, "Resuming does not re-seek the picture (\(resumeJumps.count) native jumps)")

    // After the idle stop the device renders for the first time a while after Play: neither clock starts before it,
    // then both start on the same quantum.
    clock.pause()
    clock.seek(to: 5)
    settle(clock)
    source.renderFrom = ProcessInfo.processInfo.systemUptime + 0.15
    clock.togglePlayback()
    pump(0.05)
    check(!source.isPlaying && clock.player.rate == 0,
          "Neither sound nor picture starts before a just-started device renders (rate \(clock.player.rate))")
    waitForAudioClock { source.isPlaying }
    check(source.isPlaying && clock.player.rate > 0 && source.playedFrom == 5, "Both start once the device renders")
    pump(0.2)
    let together = abs((pictureTime(clock) ?? -1) - source.playhead)
    check(together < 0.03, "Picture and sound started on the same quantum: \(Int(together * 1000)) ms apart")

    // A picture that did not stop where the sound did is placed again at the sound, before the next Play.
    source.pauseOffset = 0.5
    clock.togglePlayback()
    source.pauseOffset = 0
    let sound = source.playhead
    waitForAudioClock { abs(clock.time - sound) < 0.0005 }
    check(abs(clock.time - sound) < 0.0005, "A pause with the picture elsewhere keeps the sound's position: \(clock.time), sound \(sound)")
    settle(clock)
    check(abs((pictureTime(clock) ?? -1) - sound) < 0.05, "The picture is placed at the sound before the next Play")

    // Play while the pointer hovers elsewhere: the sound waits until the picture is back on the playhead.
    clock.seek(to: 2)
    settle(clock)
    clock.peek(at: 10)
    waitForAudioClock { abs((pictureTime(clock) ?? 0) - 10) < 0.05 }
    clock.togglePlayback()
    check(!source.isPlaying, "Play while hovering does not start the sound before the picture returns to the playhead")
    waitForAudioClock { source.isPlaying }
    check(source.playedFrom == 2 && abs((source.pictureAtStart ?? -1) - 2) < 0.05,
          "The sound starts from the playhead with the picture there: picture \(source.pictureAtStart ?? -1)")
    clock.pause()

    // A hover that ends puts the picture back on the playhead, primed: the next Play needs no native seek.
    clock.seek(to: 4)
    settle(clock)
    clock.peek(at: 12)
    waitForAudioClock { abs((pictureTime(clock) ?? 0) - 12) < 0.05 }
    clock.endPeek()
    settle(clock)
    check(abs((pictureTime(clock) ?? -1) - 4) < 0.05, "Ending a hover places the picture back on the playhead")
    let hoverJumps = JumpCounter(item)
    clock.togglePlayback()
    check(source.isPlaying && source.playedFrom == 4, "Play after a hover starts at once from the playhead")
    pump(0.2)
    check(hoverJumps.count == 0, "Play after a hover does not re-seek the picture (\(hoverJumps.count) native jumps)")
    clock.detach()
}
