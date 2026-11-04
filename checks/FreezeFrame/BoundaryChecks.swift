import CoreGraphics
import Foundation
import SrtFlowCore

// 首帧与半开边界的纯值回归；真实取帧和一步撤销由后台 MCP 场景验收。
// 同时钉住普通 split 的旧边缘保护，防止为定格放宽全局剪辑准入。
func checkFreezeBoundaries() {
    checkFreezeRange()
    checkFreezePrefix()
    checkFreezeNearEdges()
    checkFreezePrefixLinkage()
}

private func richClip(start: Double, duration: Double = 10, speed: Double = 1) -> EditClip {
    var clip = EditClip(sourceURL: media, sourceStart: 0.5, sourceDuration: duration, speed: speed,
                        timelineStart: start, volume: 0.7, linkGroup: UUID(), rotationDegrees: 15,
                        opacity: 0.8, flippedHorizontally: true, remoteKey: "fixture-key")
    clip.videoFadeInDuration = 0.2
    clip.videoFadeOutDuration = 0.3
    clip.markers = [ClipMarker(sourceTime: 0.75, text: "kept")]
    clip.soundScene = SoundScene(kind: .room)
    clip.upscale = .init(originalURL: media, sourceOffset: 0.5, tier: "fixture", madeAt: Date(timeIntervalSince1970: 1))
    clip.info = MediaInfo(duration: 20, displaySize: canvas, frameRate: 24, videoCodec: "h264",
                          audioCodec: "aac", hasAudio: true, audioCanCopyToMP4: true, fileBytes: 1)
    return clip
}

private func exact(_ actual: Double, _ expected: Double, _ message: String) {
    check(actual.isFinite && abs(actual - expected) < 1e-12, message)
}

private func checkFreezeRange() {
    let clip = richClip(start: 3, duration: 2, speed: 2)
    check(FreezeFrame.contains(clip, at: 3), "freeze includes exact clip start")
    check(FreezeFrame.contains(clip, at: 3.00025), "freeze includes first grid sample inside the former 1ms margin")
    check(FreezeFrame.contains(clip, at: 3.99975), "freeze includes last sample inside the former 1ms margin")
    for time in [2.99975, 4, 4.00025, Double.nan, Double.infinity, -Double.infinity] {
        check(!FreezeFrame.contains(clip, at: time), "freeze excludes outside/nonfinite time \(time)")
        var state = TimelineState(mainClips: [clip])
        let before = state
        state.insertFreeze(freeze(of: clip, at: 3), splitting: clip.id, at: time)
        check(state == before, "invalid freeze time has no timeline mutation: \(time)")
    }
    for time in [3, 3.00025, 3.99975, 4] {
        var state = TimelineState(mainClips: [clip])
        let before = state
        state.split(clipID: clip.id, at: time)
        check(state == before, "ordinary split retains its original 1ms edge protection: \(time)")
    }
    var corrupt = clip
    corrupt.sourceDuration = .infinity
    check(!FreezeFrame.contains(corrupt, at: 3), "freeze refuses a nonfinite used range")
    check(TimelineClipSplit.make(clip, at: 3) == nil, "shared split never creates a zero-length left piece")
    check(TimelineClipSplit.make(clip, at: 4) == nil, "shared split never creates a zero-length right piece")
}

private func checkFreezePrefix() {
    for magnet in [false, true] {
        let target = richClip(start: 10)
        var state = TimelineState(mainClips: [videoClip(start: 0, duration: 10), target,
                                             videoClip(start: 20, duration: 10)])
        let frozen = freeze(of: target, at: 10)
        state.insertFreeze(frozen, splitting: target.id, at: 10)
        if magnet { state.packMain() }
        check(state.mainClips.count == 4, "prefix adds only one clip, magnet=\(magnet)")
        guard state.mainClips.count == 4 else { continue }
        var expected = target
        expected.timelineStart = 12
        check(state.mainClips[1].id == frozen.id, "prefix still precedes the complete original")
        check(state.mainClips[2] == expected, "prefix preserves original identity and every field except placement")
        exact(state.mainClips[3].timelineStart, 22, "prefix ripples later same-track video once")
        check(state.mainClips.allSatisfy { $0.sourceDuration > 0 }, "prefix creates no zero-length clip")
    }
    // FreezeSliver applies only to a newly split remainder, never the entire short original.
    let tiny = richClip(start: 0, duration: 0.01)
    var state = TimelineState(mainClips: [tiny])
    state.insertFreeze(freeze(of: tiny, at: 0), splitting: tiny.id, at: 0)
    check(state.mainClips.count == 2, "prefix preserves a complete clip shorter than one source frame")
    var expected = tiny
    expected.timelineStart = 2
    check(state.clip(with: tiny.id) == expected, "short original survives with its exact identity and source range")
}

private func checkFreezeNearEdges() {
    // The first absolute 24fps frame is only 0.25ms after a fractional start.
    let time = 1.0 / 24
    let target = richClip(start: time - 0.00025, duration: 1.2, speed: 2)
    let later = videoClip(start: target.timelineEnd, duration: 1)
    var state = TimelineState()
    state.mainClips = [videoClip(start: 0, duration: 5)]
    state.overlayTracks = [EditLane(clips: [target, later])]
    let beforeMain = state.mainClips
    state.insertFreeze(freeze(of: target, at: time), splitting: target.id, at: time)
    let pieces = state.overlayTracks[0].clips
    check(pieces.count == 4, "fractional first frame splits two positive source pieces around the still")
    if pieces.count == 4 {
        exact(pieces[0].timelineStart, target.timelineStart, "ripple never moves the retained near-start left piece")
        exact(pieces[0].sourceDuration, (time - target.timelineStart) * 2, "near-start left duration keeps source-space speed")
        exact(pieces[1].timelineStart, time, "near-start still stays at the exact requested project frame")
        exact(pieces[2].timelineStart, time + 2, "near-start right piece resumes after the still")
        exact(pieces[2].sourceStart, target.sourceStart + pieces[0].sourceDuration, "split source windows remain contiguous")
        exact(pieces[3].timelineStart, later.timelineStart + 2, "later overlay clip moves exactly once")
        check(pieces[0].id == target.id && pieces[2].id != target.id, "interior split preserves old-left/new-right identities")
        check(pieces[2].markers == target.markers && pieces[2].upscale == target.upscale &&
              pieces[2].soundScene == target.soundScene && pieces[2].remoteKey == target.remoteKey,
              "shared split carries markers, upscale, sound and remote identity to the right")
        check(pieces.allSatisfy { $0.sourceDuration > 0 }, "near-start creates no zero-length fragments")
    }
    check(state.mainClips == beforeMain, "overlay prefix leaves main track unchanged")

    let tailTime = target.timelineEnd - 0.00025
    var tail = TimelineState(mainClips: [target, later])
    tail.insertFreeze(freeze(of: target, at: tailTime), splitting: target.id, at: tailTime)
    check(tail.mainClips.count == 3, "near-end freeze drops the actual subframe right remainder")
    if tail.mainClips.count == 3 {
        exact(tail.mainClips[0].timelineStart, target.timelineStart, "near-end retained left stays fixed")
        exact(tail.mainClips[1].timelineStart, tailTime, "near-end still begins at requested time")
        exact(tail.mainClips[2].timelineStart, tailTime + 2, "later clip follows the still without the discarded sliver gap")
    }
}

private func checkFreezePrefixLinkage() {
    let target = richClip(start: 0)
    let audio = EditClip(sourceURL: media, isAudioOnly: true, sourceDuration: 1, timelineStart: 2)
    let overlay = videoClip(start: 2, duration: 1)
    let cue = SubtitleCue(start: 2, end: 3, text: "follow the same source")
    var before = TimelineState(mainClips: [target])
    before.audioTracks = [EditLane(clips: [audio])]
    before.overlayTracks = [EditLane(clips: [overlay])]
    var document = SubtitleDocumentModel(format: .srt)
    document.cues = [cue]
    before.subtitle = document
    var after = before
    after.insertFreeze(freeze(of: target, at: 0), splitting: target.id, at: 0)
    check(after.audioTracks == before.audioTracks && after.overlayTracks == before.overlayTracks &&
          after.subtitle == before.subtitle, "pure prefix insertion changes only its target track")
    TimelineLinkage.follow(from: before, to: &after, deletesContent: false)
    check(after.clip(with: audio.id)?.timelineStart == 4, "existing linkage follows the moved same-ID source audio")
    check(after.clip(with: overlay.id)?.timelineStart == 4, "existing linkage follows the moved source overlay")
    check(after.subtitleCue(cue.id)?.start == 4 && after.subtitleCue(cue.id)?.end == 5,
          "existing linkage follows source-attached subtitles without changing their length")

    var transitions = mainTimeline()
    transitions.mainClips[0].transitionAfter = .crossFade
    transitions.mainClips[0].transitionDuration = 1
    transitions.mainClips[1].sourceStart = 1
    check(transitions.isInsideMainTransition(time: 10), "incoming transition still protects the exact next-clip start")
}
