import CoreGraphics
import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// A clip's coverage over its time on screen (`ClipCoverage.fill` → get_timeline's fills_frame / fill_scale / fills_except) and look's
// per-frame `uncovered` (`AIPictureCoverage.uncovered`). The P5 walkthrough's two cases first: rotation 5 at scale 1.1 on a 16:9 clip
// in a 16:9 frame said fills_frame true; a keyframed drift (x 0.5 → 0.53 at scale 1) bared the left edge and nothing said so.
// Case: docs/bugfixes/2026-11-17-fills-frame-ignores-rotation-and-motion.md. Geometry against a bitmap: PictureCoverageChecks.swift.

func runClipCoverageChecks() {
    checkWalkthroughRotation()
    checkWalkthroughDrift()
    checkCropAndFlips()
    checkRotationAndScaleKeys()
    checkSampling()
    checkLookUncovered()
    checkLookMotionAndTransitions()
}

private let wide = CGSize(width: 1920, height: 1080)

/// A 16:9 clip framed with edit_clip's own placement at `scale`, turned `degrees`.
private func turned(_ degrees: Double, scale: Double, start: Double = 0) -> EditClip {
    var clip = videoClip(start, 4)
    clip.placement = AIFrameFit.place(clip, canvas: wide, crop: nil, x: nil, y: nil, scale: scale).placement
    clip.rotationDegrees = degrees
    return clip
}

private func track(_ values: [(Double, Double)], easing: KeyframeEasing = .linear) -> KeyframeTrack {
    KeyframeTrack(keys: values.map { Keyframe(time: $0.0, value: $0.1, easing: easing) })
}

private func state(_ main: [EditClip], over: [EditClip] = []) -> TimelineState {
    var state = TimelineState()
    state.mainClips = main
    if !over.isEmpty { state.overlayTracks = [EditLane(clips: over)] }
    return state
}

private func checkWalkthroughRotation() {
    let clip = turned(5, scale: 1.1)
    let summary = AIFrameFit.describe(clip, canvas: wide)
    check(!summary.fillsFrame, "5° at scale 1.1 does not fill a 16:9 frame (fills_frame said true before 2026-11-17)")
    // "5° needs about 1.15" (the walkthrough): 1.1501 covers the corner pixels' centres, 1.1511 the canvas's own corners.
    checkEqual(summary.fill.fillScale, 1.152, "5° at 1.1: fill_scale is the smallest steady scale that covers, corner pixels whole")
    check(!summary.fill.isPartial, "a static turn fails all the time: no fills_except")
    let picture = AITimelineSummary.picture(clip, canvas: wide, always: false)
    checkEqual(picture?["fills_frame"], .bool(false), "picture reports fills_frame false")
    checkEqual(picture?["fill_scale"], .number(1.152), "picture reports fill_scale")
    check(picture?["fills_except"] == nil, "picture has no fills_except when it never fills")
    check(AIFrameFit.describe(turned(5, scale: 1.152), canvas: wide).fillsFrame, "at fill_scale (1.152) the turned clip fills")
    check(!AIFrameFit.describe(turned(5, scale: 1.15), canvas: wide).fillsFrame, "just under fill_scale it does not")
    check(AIFrameFit.describe(turned(0, scale: 1), canvas: wide).fillsFrame, "an unturned 16:9 clip fills a 16:9 frame")
    check(AITimelineSummary.picture(videoClip(0, 4), canvas: wide, always: false) == nil, "a default clip that fills writes no picture")
    // set_canvas's no_longer_fill reads the same answer: a turned clip that fills 16:9 at 1.2 does not fill 9:16.
    check(AIFrameFit.describe(turned(5, scale: 1.2), canvas: wide).fillsFrame, "5° at 1.2 fills 16:9")
}

private func checkWalkthroughDrift() {
    var drift = videoClip(0, 2)
    var animation = ClipAnimation()
    animation.centerX = track([(0, 0.5), (2, 0.53)])
    animation.centerY = track([(0, 0.5), (2, 0.5)])
    drift.animation = animation
    let fill = AIFrameFit.describe(drift, canvas: wide).fill
    check(!fill.fillsFrame && fill.isPartial, "the drift fills at first and then not: partial")
    checkEqual(fill.unfilled, [0.025...2.0], "the drift fails from its first frame past half a pixel to the clip's end")
    checkEqual(fill.fillScale, 1.06, "the drift needs scale 1.06 to cover throughout")
    let picture = AITimelineSummary.picture(drift, canvas: wide, always: false)
    checkEqual(picture?["fills_except"], .array([.array([.number(0.025), .number(2)])]), "picture reports fills_except as timeline seconds")
    checkEqual(picture?["fill_scale"], .number(1.06), "picture reports the drift's fill_scale")
    // look at 1.99 s (the walkthrough looked near the end): a strip along the left edge, as deep as the picture moved.
    let near = AIPictureCoverage.uncovered(state([drift]), at: 1.99)
    let moved = (0.5 + 0.03 * 1.99 / 2) * 1920 - 960
    checkEqual(near, .object(["left": .number(moved.rounded())]), "look at 1.99 s: a strip along the left edge \(moved) px deep")
    check(AIPictureCoverage.uncovered(state([drift]), at: 0) == nil, "look at 0 s: the drift has not moved yet")
}

private func checkCropAndFlips() {
    // Flips mirror inside the box: same answer.
    for (horizontal, vertical) in [(true, false), (false, true), (true, true)] {
        var clip = turned(5, scale: 1.1)
        clip.flippedHorizontally = horizontal
        clip.flippedVertically = vertical
        checkEqual(AIFrameFit.describe(clip, canvas: wide).fill, AIFrameFit.describe(turned(5, scale: 1.1), canvas: wide).fill,
                   "flips do not change coverage (h \(horizontal), v \(vertical))")
    }
    // A crop changes the default fit's shape: 10 % off the top letterboxes a 16:9 clip in a 16:9 frame.
    var cropped = videoClip(0, 4)
    cropped.crop = ClipCrop(top: 0.1, bottom: 0, leading: 0, trailing: 0)
    let fill = AIFrameFit.describe(cropped, canvas: wide).fill
    check(!fill.fillsFrame, "a cropped clip at the default fit no longer fills")
    checkEqual(fill.fillScale, 1.112, "the cropped clip needs scale 1.112 (1080 / 972, rounded up)")
    checkEqual(AIPictureCoverage.uncovered(state([cropped]), at: 1), .object(["top": 54, "bottom": 54]),
               "look: 54 px bars at the top and the bottom")
}

private func checkRotationAndScaleKeys() {
    // Rotation keys 0 → 10° at scale 1.1: fills while the turn is small, then not.
    var turning = turned(0, scale: 1.1)
    turning.sourceDuration = 2
    var animation = ClipAnimation()
    animation.rotation = track([(0, 0), (2, 10)])
    turning.animation = animation
    let fill = AIFrameFit.describe(turning, canvas: wide).fill
    check(!fill.fillsFrame && fill.isPartial && fill.unfilled.count == 1, "a growing turn fails part of the time")
    check(fill.unfilled.first.map { $0.lowerBound > 0.6 && $0.lowerBound < 0.7 && $0.upperBound == 2 } ?? false,
          "fails from about 3.3° (0.66 s) to the end: \(fill.unfilled)")
    check(fill.fillScale.map { $0 > 1.28 && $0 < 1.3 } ?? false, "fill_scale covers the 10° end: \(String(describing: fill.fillScale))")

    // Scale keys 1.2 → 1.0: linear always covers; spring dips below 1 between the keys (both keys cover on their own).
    for (easing, fills) in [(KeyframeEasing.linear, true), (.spring, false)] {
        var zoom = videoClip(0, 2)
        var keys = ClipAnimation()
        keys.width = track([(0, 1.2), (2, 1.0)], easing: easing)
        keys.height = track([(0, 1.2), (2, 1.0)], easing: easing)
        zoom.animation = keys
        let fill = AIFrameFit.describe(zoom, canvas: wide).fill
        checkEqual(fill.fillsFrame, fills, "scale 1.2 → 1.0 with \(easing): fills_frame \(fills)")
        if !fills {
            // Centred and unturned, any steady scale from 1 up covers: the dip is the spring's, and fill_scale says so.
            check(fill.isPartial && fill.fillScale == 1, "the spring's dip is reported part of the time, fill_scale 1: \(fill)")
        }
    }
}

private func checkSampling() {
    checkEqual(ClipCoverage.framesPerSecondGrid, 120, "the frame grid holds 24, 30 and 60 fps")
    check(ProjectFrameRate.allCases.allSatisfy { ClipCoverage.framesPerSecondGrid % $0.fps == 0 }, "every project frame rate lands on the grid")
    checkEqual(ClipCoverage.sampleTimes(turned(5, scale: 1.1)).count, 1, "a clip that does not move is tested once")
    var moving = videoClip(1.5, 2)
    var animation = ClipAnimation()
    animation.centerX = track([(0, 0.5), (2, 0.6)])
    moving.animation = animation
    let times = ClipCoverage.sampleTimes(moving)
    check(times.count == 240 && times.first == 1.5 && abs((times.last ?? 0) - (3.5 - 1.0 / 120)) < 1e-9,
          "a moving clip is tested at every grid frame in [start, end): \(times.count), \(times.first ?? -1)…\(times.last ?? -1)")
    animation.centerX = track([(1, 0.6)])
    moving.animation = animation
    checkEqual(ClipCoverage.sampleTimes(moving).count, 1, "one keyframe holds one value: tested once")
}

private func checkLookUncovered() {
    let canvas = wide
    // The walkthrough's turn: two bare corners, as the bitmap shows them.
    let rotated = turned(5, scale: 1.1)
    let pictures = ClipCoverage.coveringPictures(in: state([rotated]), at: 1, canvas: canvas)
    let gaps = PictureCoverage.gaps(pictures, canvas: canvas)
    check(gapsAgree(gaps, CoverageRaster(pictures, canvas: canvas).gaps()), "look's corners agree with the bitmap")
    if case .object(let object)? = AIPictureCoverage.uncovered(state([rotated]), at: 1) {
        checkEqual(Set(object.keys), ["top_right", "bottom_left"], "look reports the two bare corners")
        check(object["top_right"] == .array([.number(311), .number(28)]), "top_right is 311 px along the top, 28 px down: \(object)")
    } else {
        check(false, "look reports the turned clip's bare corners")
    }
    let full = videoClip(0, 4)
    check(AIPictureCoverage.uncovered(state([rotated], over: [full]), at: 1) == nil, "an opaque picture on V2 covers V1's corners")
    var hidden = full
    hidden.isHidden = true
    check(AIPictureCoverage.uncovered(state([rotated], over: [hidden]), at: 1) != nil, "a hidden V2 clip covers nothing")
    var hiddenTrack = state([rotated], over: [full])
    hiddenTrack.overlayTracks[0].isHidden = true
    check(AIPictureCoverage.uncovered(hiddenTrack, at: 1) != nil, "a hidden V2 track covers nothing")
    var logo = full
    logo.stillImageURL = URL(fileURLWithPath: "/tmp/srtflow-mcp-check/logo.png")
    logo.sourceURL = URL(fileURLWithPath: "/tmp/srtflow-mcp-check/abc-alpha-v1.mov")
    check(AIPictureCoverage.uncovered(state([rotated], over: [logo]), at: 1) != nil,
          "a picture with transparency does not count as covering (what is under its clear parts shows)")
    // A gap on V1: nothing covers the canvas.
    checkEqual(AIPictureCoverage.uncovered(state([videoClip(0, 1), videoClip(2, 1)]), at: 1.5),
               .object(["left": 1920, "right": 1920, "top": 1080, "bottom": 1080]), "between two clips the whole frame is bare")
    // Black content is not uncovered: a covering clip never reports anything, whatever it shows.
    check(AIPictureCoverage.uncovered(state([full]), at: 1) == nil, "a clip that fills reports nothing")
}

private func checkLookMotionAndTransitions() {
    // A wipe half-way in: the right half (flipped: the left half) is still bare.
    var wipe = videoClip(0, 4)
    wipe.presetAnimation.entrance = .wipe
    wipe.videoFadeInDuration = 1
    checkEqual(AIPictureCoverage.uncovered(state([wipe]), at: 0.5), .object(["right": 960]), "a half-way wipe bares the right half")
    wipe.flippedHorizontally = true
    checkEqual(AIPictureCoverage.uncovered(state([wipe]), at: 0.5), .object(["left": 960]), "flipped, it bares the left half")
    check(AIPictureCoverage.uncovered(state([wipe]), at: 1.5) == nil, "after the wipe the frame is covered")
    // The same wipe on the clip after a transition: the transition takes that edge (ClipPreset.effective), nothing is bare.
    var before = videoClip(0, 4)
    before.transitionAfter = .crossFade
    before.transitionDuration = 1
    var after = videoClip(4, 4)
    after.presetAnimation.entrance = .wipe
    after.videoFadeInDuration = 1
    check(AIPictureCoverage.uncovered(state([videoClip(0, 4), after]), at: 4.5) != nil, "a wipe after a hard cut is bare half-way")
    check(AIPictureCoverage.uncovered(state([before, after]), at: 4.5) == nil, "a transition replaces the wipe on its edge")
    // Rise on a clip that fills without a turn: the builder grows it to keep the edges covered.
    var rise = videoClip(0, 4)
    rise.presetAnimation.entrance = .rise
    rise.videoFadeInDuration = 1
    check(AIPictureCoverage.uncovered(state([rise]), at: 0.2) == nil, "rise on a clip that fills keeps the edges covered")
    // A turned clip gets no such compensation (`placementCoversCanvas`): look shows the bare edge during the entrance.
    var turnedRise = turned(5, scale: 1.2)
    turnedRise.presetAnimation.entrance = .rise
    turnedRise.videoFadeInDuration = 1
    check(AIFrameFit.describe(turnedRise, canvas: wide).fillsFrame, "at rest the turned clip fills (fills_frame is about framing)")
    check(AIPictureCoverage.uncovered(state([turnedRise]), at: 0.1) != nil, "during its rise the turned clip leaves the frame bare")
    check(AIPictureCoverage.uncovered(state([turnedRise]), at: 2) == nil, "after the rise it covers again")
}
