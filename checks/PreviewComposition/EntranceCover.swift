import AVFoundation
import CoreGraphics
import Foundation

// Rise and pop keep a picture that fills the frame covering while they play — turned and keyframed pictures too. 2026-11-18: a clip
// turned 5° at scale 1.2 (fills_frame true) rose in with its top corners bare and look reported them as uncovered, because the old test
// (`placementCoversCanvas`: the static box, any turned clip "does not cover") gave turned clips the picture-in-picture variant with no
// growth. The growth is `ClipMotionCover`; here it is held against the #454 geometry (`PictureCoverage`, which fills_frame and look's
// uncovered read) at every frame of the motion on a 1/120 s grid, and against real frames of the preview compositor (the export
// prerenders animated clips with the same builder; preview against export: checks/ClipAnimation/TurnedEntrances.swift).
// Case: docs/bugfixes/2026-11-18-turned-clip-entrance-bares-edges.md. Rule: docs/architecture/clip-animation.md ("不露边").
// Built by scripts/check-preview-composition.sh.

func checkEntranceCover() async throws {
    checkUnturnedGrowth()
    checkCoveringMotions()
    checkVariantChoice()
    try await checkCoveredFrames()
}

private let wideFrame = CGSize(width: 1920, height: 1080)

/// A 4 s clip of a `size` picture with `edit` applied (placement, rotation, keyframes, motion).
private func pictureClip(size: CGSize = wideFrame, url: URL? = nil, _ edit: (inout EditClip) -> Void) -> EditClip {
    let info = MediaInfo(
        duration: 4, displaySize: size, frameRate: 10, videoCodec: "h264", audioCodec: nil, hasAudio: false,
        audioCanCopyToMP4: false, fileBytes: 1
    )
    var clip = EditClip(
        sourceURL: url ?? URL(fileURLWithPath: "/tmp/srtflow-entrance-cover.mp4"), sourceDuration: 4, timelineStart: 0, info: info
    )
    edit(&clip)
    return clip
}

private func keys(_ values: [(Double, Double)]) -> KeyframeTrack {
    KeyframeTrack(keys: values.map { Keyframe(time: $0.0, value: $0.1) })
}

private func motion(_ clip: EditClip) -> ResolvedClipPreset {
    ClipPreset.effective(clip: clip, hasTransitionBefore: false, hasTransitionAfter: false)
}

/// The rule since 2026-09-18 for a picture that is not turned (moved here from main.swift): scale ≥ 1 + 2 × offset, and never below 1
/// — exactly the curve's own scale or 1 + 2 × offset, whichever is larger.
private func checkUnturnedGrowth() {
    for kind in [ClipPresetKind.rise, .pop, .zoom] {
        let clip = pictureClip {
            $0.presetAnimation.entrance = kind
            $0.videoFadeInDuration = 2
        }
        let resolved = motion(clip)
        for step in 0...20 {
            let time = Double(step) / 10
            let value = clip.presetState(resolved: resolved, atTimeline: time, canvas: wideFrame)
            let curve = ClipAnimator.state(resolved: resolved, local: time, span: 4, coversCanvas: true)
            check(value.scale >= 1 - 0.0001, "\(kind.title) on a picture that fills never goes below 1 (a bare edge), got \(value.scale)")
            check(value.scale >= 1 + 2 * abs(value.offset.y) - 0.0001,
                  "\(kind.title): the move is matched by growth, got scale \(value.scale) / offset \(value.offset.y)")
            let expected = max(curve.scale, 1 + 2 * max(abs(curve.offset.x), abs(curve.offset.y)))
            check(abs(value.scale - expected) < 1e-9, "\(kind.title) at \(time) s: unturned growth is the old rule, \(value.scale) vs \(expected)")
        }
    }
}

/// Pictures that fill the frame at rest — turned, flipped, off centre, keyframed — with rise, pop and zoom in and out: at every grid
/// frame of the motion the moving picture covers the canvas and its own resting place.
private func checkCoveringMotions() {
    let pictures: [(String, EditClip)] = [
        ("turned 5° at 1.2", pictureClip { $0.placement = ClipPlacement(centerX: 0.5, centerY: 0.5, width: 1.2, height: 1.2); $0.rotationDegrees = 5 }),
        ("turned −12° at 1.6 off centre", pictureClip {
            $0.placement = ClipPlacement(centerX: 0.53, centerY: 0.47, width: 1.6, height: 1.6)
            $0.rotationDegrees = -12
        }),
        ("flipped, turned −5° at 1.25", pictureClip {
            $0.placement = ClipPlacement(centerX: 0.5, centerY: 0.5, width: 1.25, height: 1.25)
            $0.rotationDegrees = -5
            $0.flippedHorizontally = true
            $0.flippedVertically = true
        }),
        ("a 9:16 picture filled across 16:9, turned 3°", pictureClip(size: CGSize(width: 1080, height: 1920)) {
            $0.placement = ClipPlacement(centerX: 0.5, centerY: 0.5, width: 1.15, height: 1.15 * 1920 / 1080 * 1920 / 1080)
            $0.rotationDegrees = 3
        }),
        ("unturned, off centre at 1.1", pictureClip { $0.placement = ClipPlacement(centerX: 0.52, centerY: 0.49, width: 1.1, height: 1.1) }),
        ("turned 4°, scale keys 1.2 → 1.35", pictureClip {
            $0.rotationDegrees = 4
            var animation = ClipAnimation()
            animation.width = keys([(0, 1.2), (4, 1.35)])
            animation.height = keys([(0, 1.2), (4, 1.35)])
            $0.animation = animation
        }),
        ("turning 2° → 7° at 1.4", pictureClip {
            $0.placement = ClipPlacement(centerX: 0.5, centerY: 0.5, width: 1.4, height: 1.4)
            var animation = ClipAnimation()
            animation.rotation = keys([(0, 2), (4, 7)])
            $0.animation = animation
        }),
        ("turned 3°, drifting x 0.47 → 0.53 at 1.3", pictureClip {
            $0.placement = ClipPlacement(centerX: 0.5, centerY: 0.5, width: 1.3, height: 1.3)
            $0.rotationDegrees = 3
            var animation = ClipAnimation()
            animation.centerX = keys([(0, 0.47), (4, 0.53)])
            $0.animation = animation
        }),
        ("placed small, scale keys 1.2 → 1.3 fill", pictureClip {
            $0.placement = ClipPlacement(centerX: 0.5, centerY: 0.5, width: 0.9, height: 0.9)
            var animation = ClipAnimation()
            animation.width = keys([(0, 1.2), (4, 1.3)])
            animation.height = keys([(0, 1.2), (4, 1.3)])
            $0.animation = animation
        })
    ]
    let grid = Double(ClipCoverage.framesPerSecondGrid)
    for (label, picture) in pictures {
        check(ClipCoverage.fill(picture, canvas: wideFrame).fillsFrame, "\(label): fills the frame at rest (the premise)")
        for kind in [ClipPresetKind.rise, .pop, .zoom] {
            for intensity in [0.6, 1.0] {
                var clip = picture
                clip.presetAnimation = ClipPresetAnimation(entrance: kind, exit: kind, intensity: intensity)
                clip.videoFadeInDuration = 1
                clip.videoFadeOutDuration = 1
                let resolved = motion(clip)
                let times = (0..<120).map { Double($0) / grid } + (361..<480).map { Double($0) / grid }
                let bare = times.filter { time in
                    let moving = ClipCoverage.picture(clip, atTimeline: time, canvas: wideFrame, motion: resolved)
                    let rest = ClipCoverage.picture(clip, atTimeline: time, canvas: wideFrame)
                    return !PictureCoverage.covers(moving, canvas: wideFrame) || PictureCoverage.growth(moving, toCover: rest) > 1 + 1e-9
                }
                check(bare.isEmpty, "\(label), \(kind.title) at \(intensity): covers the frame and its resting place at every frame of "
                      + "the motion; bare at \(bare.count) frames from \(bare.first ?? -1) s")
                let start = clip.presetState(resolved: resolved, atTimeline: 0, canvas: wideFrame)
                check(start.offset != .zero || start.scale != 1, "\(label), \(kind.title): the motion moves (the check is not empty)")
            }
        }
    }
}

/// The full-frame variant (smaller rise, pop from big) follows the picture at rest on the clip's first frame (entrance) and its last
/// (exit), rotation and keyframes included; a picture that does not fill keeps the picture-in-picture variant (no growth).
private func checkVariantChoice() {
    func start(_ clip: EditClip, _ kind: ClipPresetKind, at time: Double = 0) -> ClipAnimationState {
        var clip = clip
        clip.presetAnimation = ClipPresetAnimation(entrance: kind, exit: kind, intensity: 0.6)
        clip.videoFadeInDuration = 1
        clip.videoFadeOutDuration = 1
        return clip.presetState(resolved: motion(clip), atTimeline: time, canvas: wideFrame)
    }
    let fills = pictureClip { $0.placement = ClipPlacement(centerX: 0.5, centerY: 0.5, width: 1.2, height: 1.2); $0.rotationDegrees = 5 }
    let short = pictureClip { $0.placement = ClipPlacement(centerX: 0.5, centerY: 0.5, width: 1.1, height: 1.1); $0.rotationDegrees = 5 }
    check(start(fills, .pop).scale > 1.1, "5° at 1.2 fills: pop comes down from big, got \(start(fills, .pop).scale)")
    check(abs(start(fills, .rise).offset.y - 0.03) < 1e-9, "5° at 1.2 fills: the smaller rise (0.05 × 0.6), got \(start(fills, .rise).offset.y)")
    check(start(short, .pop).scale < 0.9, "5° at 1.1 does not fill: pop springs up from small, got \(start(short, .pop).scale)")
    check(abs(start(short, .rise).offset.y - 0.096) < 1e-9 && start(short, .rise).scale == 1,
          "5° at 1.1 does not fill: the larger rise (0.16 × 0.6) and no growth, got \(start(short, .rise))")
    // Scale keys 0.8 → 1.2: small on the first frame (entrance from small), filling on the last (exit to big).
    let zoomIn = pictureClip {
        var animation = ClipAnimation()
        animation.width = keys([(0, 0.8), (4, 1.2)])
        animation.height = keys([(0, 0.8), (4, 1.2)])
        $0.animation = animation
    }
    check(start(zoomIn, .pop).scale < 0.9, "keys 0.8 → 1.2: the entrance starts small, got \(start(zoomIn, .pop).scale)")
    check(start(zoomIn, .pop, at: 3.99).scale > 1.05, "keys 0.8 → 1.2: the exit grows from a filling picture, got "
          + "\(start(zoomIn, .pop, at: 3.99).scale)")
}

/// Real preview frames of a white 640×360 clip on its own frame: no dark pixel along the frame's edges while it moves. The picture fades
/// with the motion, so dark is below half its brightness at that moment.
private func checkCoveredFrames() async throws {
    let size = CGSize(width: 640, height: 360)
    let white = try await makeSolidVideo(white: 1, seconds: 4, name: "entrance-cover-white.mp4", size: size)
    func state(_ edit: (inout EditClip) -> Void) -> TimelineState {
        var state = TimelineState()
        state.mainClips = [pictureClip(size: size, url: white, edit)]
        return state
    }
    func turned(_ scale: Double) -> (inout EditClip) -> Void {
        { $0.placement = ClipPlacement(centerX: 0.5, centerY: 0.5, width: scale, height: scale); $0.rotationDegrees = 5 }
    }
    let rise = state { turned(1.2)(&$0); $0.presetAnimation = ClipPresetAnimation(entrance: .rise, intensity: 1); $0.videoFadeInDuration = 2 }
    let pop = state { turned(1.2)(&$0); $0.presetAnimation = ClipPresetAnimation(entrance: .pop, intensity: 1); $0.videoFadeInDuration = 2 }
    // Scale keys 1.17 → 1.25 at 5° (1.152 fills): little room, so a rise out without growth bares the bottom corners.
    let keyed = state {
        turned(1.17)(&$0)
        var animation = ClipAnimation()
        animation.width = keys([(0, 1.17), (4, 1.25)])
        animation.height = keys([(0, 1.17), (4, 1.25)])
        $0.animation = animation
        $0.presetAnimation = ClipPresetAnimation(exit: .rise, intensity: 1)
        $0.videoFadeOutDuration = 1.5
    }
    for (label, timeline, times) in [("turned 5° at 1.2, rise in", rise, [0.3, 0.5, 0.8, 1.2]),
                                     ("turned 5° at 1.2, pop in", pop, [0.3, 0.8, 1.3, 1.6]),
                                     ("turned 5°, scale keys 1.17 → 1.25, rise out", keyed, [3.2, 3.6, 3.8])] {
        for time in times {
            let dark = await darkEdgePixels(timeline, at: time)
            check(dark >= 0 && dark <= 2, "\(label) at \(time) s: the frame's edges stay covered (\(dark) dark edge pixels)")
        }
    }
    // The probe sees a bare edge when there is one: 5° at 1.1 does not fill, and its rise bares the top.
    let short = state { turned(1.1)(&$0); $0.presetAnimation = ClipPresetAnimation(entrance: .rise, intensity: 1); $0.videoFadeInDuration = 2 }
    let bare = await darkEdgePixels(short, at: 0.5)
    check(bare > 20, "5° at 1.1 (does not fill) rising: the probe sees its bare edges (\(bare) dark edge pixels)")
}

/// Dark pixels along the frame's edges at `time`, dark meaning below half the brightness the picture has then (it fades with the
/// motion); -1 when the frame does not render.
private func darkEdgePixels(_ state: TimelineState, at time: Double) async -> Int {
    guard let clip = state.mainClips.first else { return -1 }
    let canvas = VideoEditCompositionBuilder.renderSize(for: state)
    let opacity = clip.presetState(resolved: motion(clip), atTimeline: time, canvas: canvas).opacity
    guard let frame = await coverageFrame(state, at: time, darkBelow: Int((128 * opacity).rounded())) else { return -1 }
    return frame.darkEdgePixels
}
