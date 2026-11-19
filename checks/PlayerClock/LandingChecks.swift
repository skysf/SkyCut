import AVFoundation
import CoreMedia
import Foundation

// Picture and sound start together and stay together (docs/architecture/playback-start.md):
// - Play on an output that has just started (after the idle stop) holds both until it renders, then starts both;
// - a click or a drag on the timeline while playing holds the sound until the picture there can move;
// - drift is corrected by running the picture slower or faster, never by a re-seek; too far apart, both land again.
// Real PlayerClock and AVPlayer on the picture-only long-GOP clip; the sound runs on the host clock like the engine.
// Before 2026-11-20 the first started the picture up to 170 ms ahead of the sound, the second let the sound run on
// over a frozen picture and the third re-seeked the picture
// (docs/bugfixes/2026-11-20-idle-start-picture-ahead-and-lost-sound.md).
private final class HostClockAudioSource: PlaybackAudioSource {
    private var position = 0.0
    private var host = ProcessInfo.processInfo.systemUptime
    private(set) var isPlaying = false
    private(set) var plays = 0
    private(set) var playedFrom: Double?
    /// Where the native picture's timebase stood when the sound was told to start.
    private(set) var pictureAtStart: Double?
    /// False: an output stopped by the idle rule or started and not rendered yet.
    var isRendering = true
    weak var player: AVPlayer?
    let duration = 0.0

    private var picture: Double? { player?.currentItem?.timebase.map { CMTimebaseGetTime($0).seconds } }

    var playhead: Double { position + (isPlaying ? ProcessInfo.processInfo.systemUptime - host : 0) }


    func recoverIfNeeded() throws -> Bool { false }

    func play(from seconds: Double) {
        plays += 1
        playedFrom = seconds
        pictureAtStart = picture
        position = seconds
        host = ProcessInfo.processInfo.systemUptime
        isPlaying = true
    }

    func pause() {
        position = playhead
        isPlaying = false
    }

    func seek(to seconds: Double) {
        position = seconds
        host = ProcessInfo.processInfo.systemUptime
    }

    /// The sound's timeline moves by `seconds` while it plays (a device that started late, a clock that drifted).
    func shift(by seconds: Double) { position += seconds }
}

private func pumpRunLoop(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

/// A clock on `clip` with the fake sound, its new item placed at `start` and played once (a new item primes on Play).
private func playingClock(_ clip: URL, interval: Double, start: Double) -> (PlayerClock, HostClockAudioSource, AVPlayerItem) {
    let clock = PlayerClock(observationInterval: interval)
    clock.player.isMuted = true
    let source = HostClockAudioSource()
    source.player = clock.player
    let item = AVPlayerItem(url: clip)
    clock.attachItem(item)
    clock.attachAudioSource(source)
    clock.seek(to: start)
    clock.resumeAfterPreviewRebuild(wasPlaying: false)
    settle(clock)
    clock.togglePlayback()
    waitForAudioClock { source.isPlaying && clock.player.rate > 0 }
    pumpRunLoop(0.3)
    return (clock, source, item)
}

/// Pauses and waits until the pause holds the stopped picture (playhead and sound on its frame), as a person would.
private func pauseAndHold(_ clock: PlayerClock) {
    clock.togglePlayback()
    waitForAudioClock {
        guard let timebase = clock.player.currentItem?.timebase, CMTimebaseGetRate(timebase) == 0 else { return false }
        return abs(CMTimebaseGetTime(timebase).seconds - clock.time) < 0.0005 && !clock.isPositioningPreview
    }
}

private func startedTogether(_ source: HostClockAudioSource, at seconds: Double) -> Bool {
    guard let sound = source.playedFrom, let picture = source.pictureAtStart else { return false }
    return abs(sound - seconds) < 0.001 && abs(picture - sound) < 0.05
}

func checkOutputStartWaits(clip: URL) {
    let (clock, source, item) = playingClock(clip, interval: 0.5, start: 3)
    pauseAndHold(clock)

    // After the idle stop the output starts at Play and renders some milliseconds later: both wait for it.
    source.isRendering = false
    let jumps = JumpCounter(item)
    let plays = source.plays
    let paused = clock.time
    clock.togglePlayback()
    pumpRunLoop(0.2)
    check(source.plays == plays && clock.player.rate == 0,
          "Play on an output that has not rendered holds sound and picture (sound started \(source.plays - plays), picture rate \(clock.player.rate))")
    source.isRendering = true
    waitForAudioClock { source.isPlaying && clock.player.rate > 0 }
    check(source.isPlaying && clock.player.rate > 0 && startedTogether(source, at: paused),
          "Once the output renders both start from the playhead: sound \(source.playedFrom ?? -1), picture \(source.pictureAtStart ?? -1)")
    pumpRunLoop(0.2)
    check(jumps.count == 0, "The start after the wait does not re-seek the picture (\(jumps.count) native jumps)")

    // A second press while the output starts cancels the Play.
    pauseAndHold(clock)
    source.isRendering = false
    let cancelled = source.plays
    clock.togglePlayback()
    clock.togglePlayback()
    source.isRendering = true
    pumpRunLoop(0.2)
    check(source.plays == cancelled && !source.isPlaying && clock.player.rate == 0,
          "A second press while the output starts cancels the Play")

    // An output that never renders does not keep Play pending: after the wait's limit both start.
    source.isRendering = false
    clock.togglePlayback()
    waitForAudioClock { source.isPlaying && clock.player.rate > 0 }
    check(source.isPlaying && clock.player.rate > 0, "An output that never renders lets both start after \(OutputStartWait.limit) s")
    source.isRendering = true
    clock.detach()
}

/// A start that stalled inside `playImmediately` pins the sound to the picture's own start; one that returned at once
/// keeps the output's next quantum (`PictureStart`).
func checkStalledStartPinsTheSound() {
    let now = mach_absolute_time()
    check(PictureStart.host(moved: 0.004, now: now) == nil, "A start that returned at once keeps the output's next quantum")
    check(PictureStart.host(moved: .nan, now: now) == nil, "No timebase reading, no pin")
    let pinned = PictureStart.host(moved: 0.05, now: now).map { AVAudioTime.seconds(forHostTime: now) - AVAudioTime.seconds(forHostTime: $0) }
    check(pinned.map { abs($0 - 0.05) < 0.0001 } ?? false,
          "A start that moved the picture 50 ms before returning pins the sound 50 ms back (\(pinned ?? -1))")
}

func checkSeekWhilePlayingLandsTogether(clip: URL) {
    let (clock, source, item) = playingClock(clip, interval: 0.5, start: 2)

    // A click two seconds into a later GOP while playing: the sound waits for the picture there.
    let plays = source.plays
    clock.seek(to: 12)
    check(!source.isPlaying && clock.player.rate == 0,
          "A click while playing holds the sound with the picture (sound playing \(source.isPlaying), picture rate \(clock.player.rate))")
    waitForAudioClock { source.isPlaying && clock.player.rate > 0 }
    check(source.plays == plays + 1 && startedTogether(source, at: 12),
          "Both start together at the click: sound \(source.playedFrom ?? -1), picture \(source.pictureAtStart ?? -1)")
    let jumps = JumpCounter(item)
    pumpRunLoop(0.3)
    check(jumps.count == 0, "Nothing re-seeks the picture after the sound started (\(jumps.count) native jumps)")

    // A drag while playing: the sound is held until the scrub settles, then both start there.
    clock.seek(to: 6, precise: false)
    check(!source.isPlaying, "A drag while playing holds the sound")
    waitForAudioClock { source.isPlaying && clock.player.rate > 0 }
    check(startedTogether(source, at: 6), "After a drag both start there: sound \(source.playedFrom ?? -1), picture \(source.pictureAtStart ?? -1)")
    clock.detach()
}

func checkDriftCorrectionKeepsThePictureMoving(clip: URL) {
    let (clock, source, item) = playingClock(clip, interval: 0.05, start: 2)
    func offset() -> Double { (pictureTime(clock) ?? 0) - source.playhead }

    /// Shifts the sound and watches 1.5 s: the slowest and fastest picture rate, the native jumps, the corrections.
    func drift(by seconds: Double) -> (slowest: Float, fastest: Float, jumps: Int, corrections: Int) {
        let jumps = JumpCounter(item)
        let corrections = clock.driftCorrections
        var slowest: Float = 1, fastest: Float = 1
        source.shift(by: seconds)
        let end = ProcessInfo.processInfo.systemUptime + 1.5
        while ProcessInfo.processInfo.systemUptime < end {
            pumpRunLoop(0.01)
            if clock.player.rate > 0 {
                slowest = min(slowest, clock.player.rate)
                fastest = max(fastest, clock.player.rate)
            }
        }
        return (slowest, fastest, jumps.count, clock.driftCorrections - corrections)
    }

    // The sound falls 120 ms behind the picture (as after a late output start): the picture slows down to it.
    var run = drift(by: -0.12)
    check(run.corrections == 1 && run.slowest < 1 && run.slowest >= 0.74 && run.fastest == 1,
          "Picture ahead: it runs slower until it meets the sound (\(run.corrections) corrections, rates \(run.slowest)-\(run.fastest))")
    check(run.jumps == 0, "Correcting a picture ahead does not re-seek it (\(run.jumps) native jumps)")
    check(abs(offset()) < 0.03 && clock.player.rate == 1, "Then picture and sound are together at normal speed (\(offset()) s apart)")

    // The sound runs 100 ms ahead: the picture speeds up.
    run = drift(by: 0.1)
    check(run.corrections == 1 && run.fastest > 1 && run.fastest <= 1.26 && run.slowest == 1,
          "Picture behind: it runs faster until it meets the sound (\(run.corrections) corrections, rates \(run.slowest)-\(run.fastest))")
    check(run.jumps == 0, "Correcting a picture behind does not re-seek it (\(run.jumps) native jumps)")
    check(abs(offset()) < 0.03 && clock.player.rate == 1, "Then picture and sound are together at normal speed (\(offset()) s apart)")

    // Half a second apart is too far to run back: the sound is held, the picture placed at it, both start together.
    let plays = source.plays
    source.shift(by: -0.5)
    waitForAudioClock { source.plays == plays + 1 && clock.player.rate > 0 }
    check(source.plays == plays + 1 && abs((source.pictureAtStart ?? -1) - (source.playedFrom ?? -2)) < 0.05,
          "Far apart: both land again together (sound \(source.playedFrom ?? -1), picture \(source.pictureAtStart ?? -1))")
    pumpRunLoop(0.3)
    check(abs(offset()) < 0.03, "After landing again picture and sound are together (\(offset()) s apart)")
    clock.detach()
}
