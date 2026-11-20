import AVFoundation
import CoreMedia
import Foundation

// A hover on its own player (docs/architecture/playback-start.md "Hover"). With the engine, the hover's frames come
// from `HoverPreview`'s player, built on the preview item's asset and video composition. The editing picture stays
// placed and primed at the playhead. Play while hovering, or right after a hover, starts at once without a native
// seek. Before 2026-11-20 the hover moved the editing player, and Play waited until the playhead's frame was decoded
// again (0.6-0.8 s at 4K mid-GOP). Real PlayerClock and AVPlayers on the long-GOP clip; nothing is drawn.

private func pumpHover(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

/// The hover's frame at `seconds` is on screen.
private func hoverShows(_ clock: PlayerClock, _ seconds: Double) -> Bool {
    clock.hover.isShowing && abs((clock.hover.shownTime ?? -1) - seconds) < 0.02
}

func checkHoverKeepsTheEditingPicture(clip: URL) {
    let clock = PlayerClock(observationInterval: 0.5)
    clock.player.isMuted = true
    let source = RecordingAudioSource()
    source.player = clock.player
    let item = AVPlayerItem(url: clip)
    clock.attachItem(item)
    clock.attachAudioSource(source)
    clock.seek(to: 2)
    clock.resumeAfterPreviewRebuild(wasPlaying: false)
    settle(clock)
    // Prime the item once (Play primes a new item), then place the playhead: placed and primed as when editing.
    clock.togglePlayback()
    waitForAudioClock { source.isPlaying }
    clock.pause()
    clock.seek(to: 2)
    settle(clock)
    check(clock.hover.player.currentItem == nil && !clock.hover.hasItem, "No hover item before the first hover")

    // Hovering shows the pointer's frame on the hover player and leaves the editing picture on the playhead.
    let jumps = JumpCounter(item)
    clock.peek(at: 10)
    waitForAudioClock { hoverShows(clock, 10) }
    check(hoverShows(clock, 10), "The hover's frame lands on the hover player (shown \(clock.hover.shownTime ?? -1))")
    check(clock.hover.player.currentItem?.asset === item.asset
            && clock.hover.player.currentItem?.videoComposition === item.videoComposition,
          "The hover item is built on the preview item's asset and video composition")
    check(abs((pictureTime(clock) ?? -1) - 2) < 0.05 && clock.time == 2 && clock.displayTime == 10,
          "The editing picture stays on the playhead while hovering: picture \(pictureTime(clock) ?? -1)")
    check(jumps.count == 0, "Hovering does not move the editing picture (\(jumps.count) native jumps)")

    // Play while hovering: the hover hides and both clocks start from the playhead at once.
    clock.togglePlayback()
    check(source.isPlaying && source.playedFrom == 2 && abs((source.pictureAtStart ?? -1) - 2) < 0.05,
          "Play while hovering starts at once from the playhead: picture \(source.pictureAtStart ?? -1)")
    check(!clock.hover.isShowing && clock.peekTime == nil, "Play hides the hover picture")
    pumpHover(0.2)
    check(jumps.count == 0, "Play after a hover does not re-seek the picture (\(jumps.count) native jumps)")
    clock.pause()

    // A hover that ends shows the editing picture again, never moved: the next Play needs no placement.
    clock.seek(to: 4)
    settle(clock)
    let endJumps = JumpCounter(item)
    clock.peek(at: 12)
    waitForAudioClock { hoverShows(clock, 12) }
    clock.endPeek()
    check(!clock.hover.isShowing && clock.hover.hasItem, "Ending a hover hides its picture and keeps its item for a while")
    check(abs((pictureTime(clock) ?? -1) - 4) < 0.05 && !clock.isPositioningPreview,
          "After a hover the editing picture is still placed on the playhead: picture \(pictureTime(clock) ?? -1)")
    clock.togglePlayback()
    check(source.isPlaying && source.playedFrom == 4, "Play right after a hover starts at once from the playhead")
    pumpHover(0.2)
    check(endJumps.count == 0, "A hover and the Play after it do not move the picture (\(endJumps.count) native jumps)")
    clock.pause()

    // A new preview item ends the hover; the next hover is built on the new item.
    clock.peek(at: 6)
    waitForAudioClock { hoverShows(clock, 6) }
    let rebuilt = AVPlayerItem(asset: AVURLAsset(url: clip))
    clock.attachItem(rebuilt)
    check(!clock.hover.isShowing && clock.peekTime == nil, "A new preview item ends the hover")
    clock.seek(to: 4)
    settle(clock)
    clock.peek(at: 8)
    waitForAudioClock { hoverShows(clock, 8) }
    check(clock.hover.player.currentItem?.asset === rebuilt.asset, "The next hover is built on the new preview item")
    clock.endPeek()

    // The hover item goes `releaseDelay` after the hover: its memory is only held around a hover.
    pumpHover(HoverPreview.releaseDelay + 0.3)
    check(clock.hover.player.currentItem == nil && !clock.hover.hasItem,
          "The hover item is released \(HoverPreview.releaseDelay) s after the hover")
    clock.detach()
}
