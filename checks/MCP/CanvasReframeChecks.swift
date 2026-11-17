import CoreGraphics
import Foundation
import SrtFlowCore
import SrtFlowMCPKit

// A canvas change keeps every clip's shape (`CanvasReframe`, run at the end of `perform`) and set_canvas says what it reframed
// (`AICanvasReframe`). P5 walkthrough to-do 4 (2026-11-17): after edit_clip fit=fill focus_x=0.62 on a 9:16 canvas, set_canvas 16:9
// left the placement's canvas fractions as they were, so get_timeline said "stretched": true, scale 3.16, and look showed the face
// squashed. Case: docs/bugfixes/2026-11-17-canvas-change-stretches-framed-clips.md.

func runCanvasReframeChecks() {
    filledClipChecks()
    otherFramingChecks()
    autoCanvasChecks()
}

private let tall = CGSize(width: 1080, height: 1920)
private let wide = CGSize(width: 1920, height: 1080)

/// `perform` with the canvas changing: the edit, then the reframe.
private func changed(_ state: TimelineState, _ edit: (inout TimelineState) -> Void) -> TimelineState {
    var next = state
    edit(&next)
    CanvasReframe.keepShapes(&next, after: state)
    return next
}

/// The picture's frame on the canvas has the cropped picture's own shape (not stretched).
private func keepsShape(_ clip: EditClip?, canvas: CGSize) -> Bool {
    guard let clip, let picture = clip.croppedDisplaySize else { return false }
    let frame = clip.resolvedPlacement(canvas: canvas).frame(in: canvas)
    return abs(frame.width / frame.height - picture.width / picture.height) < 1e-6
}

private func close(_ a: Double?, _ b: Double?) -> Bool {
    guard let a, let b else { return false }
    return abs(a - b) < 1e-9
}

private func filledClipChecks() {
    // edit_clip fit=fill focus_x=0.62 on a 9:16 canvas (a 16:9 source).
    var clip = videoClip(0, 5)
    guard let fill = AIFrameFit.fill(clip, canvas: tall, active: AIFrameFit.wholePicture, focus: CGPoint(x: 0.62, y: 0.5)) else {
        return check(false, "a 16:9 clip fills a 9:16 canvas")
    }
    clip.crop = fill.crop
    clip.placement = fill.placement
    var state = TimelineState()
    state.canvasRatio = .tall9x16
    state.mainClips = [clip]
    let framed = AIFrameFit.describe(clip, canvas: tall)
    check(framed.fillsFrame && !framed.stretched, "the walkthrough's clip fills the 9:16 frame unstretched")

    // set_canvas ratio=16:9.
    let widened = changed(state) { $0.canvasRatio = .wide16x9 }
    let after = widened.clip(with: clip.id)
    let summary = after.map { AIFrameFit.describe($0, canvas: wide) }
    check(summary?.stretched == false, "16:9: the clip is not stretched (it was 3.16× wide before the fix)")
    check(keepsShape(after, canvas: wide), "16:9: the frame keeps the cropped picture's shape")
    check(close(summary?.x, framed.x) && close(summary?.y, framed.y), "16:9: x and y stay as get_timeline reported them")
    check(close(summary?.scale, framed.scale), "16:9: scale stays as get_timeline reported it")
    check(after?.crop == clip.crop, "16:9: nothing is cropped differently")
    check(summary?.fillsFrame == false, "16:9: a 9:16 window no longer fills a 16:9 frame (pillarboxed, not re-cropped)")

    // The reply: which clip was reframed, which no longer fills.
    let fields = AICanvasReframe.fields(before: state, after: widened, ids: AIShortIDs(state: widened))
    let short = AIShortIDs(state: widened).short(clip.id)
    checkEqual(fields["reframed"], .array([.string(short)]), "set_canvas reply lists the reframed clip")
    checkEqual(fields["no_longer_fill"], .array([.string(short)]), "set_canvas reply lists the clip that no longer fills")
    check(fields["note"] != nil, "set_canvas reply explains reframed / no_longer_fill")

    // Back to 9:16: the original numbers return exactly.
    let back = changed(widened) { $0.canvasRatio = .tall9x16 }
    let restored = back.clip(with: clip.id)?.placement
    check(close(restored?.centerX, clip.placement?.centerX) && close(restored?.width, clip.placement?.width)
          && close(restored?.height, clip.placement?.height), "back to 9:16: the fill comes back exactly")

    // Frame rate only: nothing to report.
    var faster = state
    faster.frameRate = .fps30
    check(AICanvasReframe.fields(before: state, after: faster, ids: AIShortIDs(state: faster)).isEmpty, "fps only: no reframe fields")
}

private func otherFramingChecks() {
    // A small picture in the top-right corner of a 16:9 frame, a default-layout clip, size keyframes, and a clip the edit itself frames.
    var corner = videoClip(0, 5)
    corner.placement = ClipPlacement(centerX: 0.85, centerY: 0.15, width: 0.25, height: 0.25)
    var plain = videoClip(0, 5)
    var keyed = videoClip(5, 5)
    var animation = ClipAnimation()
    animation.width = KeyframeTrack(keys: [Keyframe(time: 0, value: 1), Keyframe(time: 5, value: 1.3)])
    animation.height = KeyframeTrack(keys: [Keyframe(time: 0, value: 1), Keyframe(time: 5, value: 1.3)])
    keyed.animation = animation
    var state = TimelineState()
    state.canvasRatio = .wide16x9
    plain.timelineStart = 10
    state.mainClips = [videoClip(0, 5), keyed, plain]
    state.overlayTracks = [EditLane(clips: [corner])]
    let narrowed = changed(state) { $0.canvasRatio = .tall9x16 }

    let before = AIFrameFit.describe(corner, canvas: wide)
    let cornerAfter = narrowed.clip(with: corner.id)
    let after = cornerAfter.map { AIFrameFit.describe($0, canvas: tall) }
    check(close(after?.x, 0.85) && close(after?.y, 0.15), "corner picture: stays in its corner")
    check(close(after?.scale, before.scale) && after?.stretched == false, "corner picture: same scale, not stretched")
    check(narrowed.clip(with: plain.id) == plain, "default layout: untouched (it follows the canvas by itself)")
    for time in [0.0, 2.5, 5.0] {
        let placement = narrowed.clip(with: keyed.id)?.animatedPlacement(atTimeline: 5 + time, canvas: tall)
        let frame = placement?.frame(in: tall)
        check(frame.map { abs($0.width / $0.height - 16.0 / 9) < 1e-6 } ?? false, "size keyframes keep the picture's shape at \(time) s")
    }

    let framedByEdit = ClipPlacement(centerX: 0.3, centerY: 0.5, width: 0.4, height: 0.4)
    let both = changed(state) { next in
        next.canvasRatio = .tall9x16
        next.update(corner.id) { $0.placement = framedByEdit }
    }
    check(both.clip(with: corner.id)?.placement == framedByEdit, "a clip this edit framed is left as the edit set it")
}

private func autoCanvasChecks() {
    // Auto canvas: deleting the 16:9 first clip makes the 9:16 one first, and the frame turns tall; the framed overlay keeps its shape.
    var first = videoClip(0, 5)
    var phone = videoClip(5, 5)
    phone.info?.displaySize = CGSize(width: 1080, height: 1920)
    first.info?.displaySize = CGSize(width: 1920, height: 1080)
    var logo = videoClip(0, 10)
    logo.placement = ClipPlacement(centerX: 0.2, centerY: 0.8, width: 0.3, height: 0.3)
    var state = TimelineState()
    state.mainClips = [first, phone]
    state.overlayTracks = [EditLane(clips: [logo])]
    let deleted = changed(state) { $0.remove(first.id) }
    check(TimelineRenderSize.size(for: deleted) == tall, "auto: the frame follows the new first clip")
    check(keepsShape(deleted.clip(with: logo.id), canvas: tall), "auto: the framed overlay keeps its shape on the new frame")
    check(close(deleted.clip(with: logo.id)?.placement?.centerX, 0.2), "auto: the overlay stays where it was on the frame")

    // Same shape, other size (auto from a 1920×1080 clip to a fixed 16:9): nothing changes.
    let same = changed(state) { $0.canvasRatio = .wide16x9 }
    check(same == { var s = state; s.canvasRatio = .wide16x9; return s }(), "same shape: nothing is reframed")
}
