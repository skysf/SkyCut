import CoreGraphics
import Foundation

// MARK: - Entrance / exit motion keeps a covering picture covering (the no-bare-edge growth)
//
// What: rise moves a clip's picture and pop shrinks it (the back curve dips below 1); on a picture that fills the frame that bares what
// is below (black on V1, V1 under V2). Such a motion uses the full-frame variant (smaller rise, pop from big: `ClipAnimator`), and the
// moving picture grows about its centre just enough to keep covering the place it rests at that moment — so the motion never shows more
// of what is below than the clip at rest does. For a picture that is not turned that is the rule since 2026-09-18
// (scale ≥ 1 + 2 × offset); a turned picture is measured along its own sides and a keyframed one around its keyframed resting place,
// both with the geometry behind fills_frame (`PictureCoverage`).
// Which motions: those of a clip whose picture at rest covers the canvas on the clip's first frame (entrance) or last frame (exit) —
// placement or default fit, crop, flips, rotation and keyframes included (`ClipCoverage.picture`). Before 2026-11-18 the test was the
// static box and any turned clip counted as not covering: rise and pop bared its edges during the motion.
// Used by `EditClip.presetState` only, so the preview, the export (its animated clips are prerendered by the same builder) and look's
// `uncovered` get the same answer.
// Not: the motion curves and amplitudes (`ClipAnimator`), fills_frame (`ClipCoverage.fill`), opacity, wipes (a wipe bares on purpose).
// Rule: docs/architecture/clip-animation.md ("不露边"); case: docs/bugfixes/2026-11-18-turned-clip-entrance-bares-edges.md.

enum ClipMotionCover {
    /// The motion on `edge` uses the full-frame variant and keeps covering: the clip's picture at rest covers the whole canvas on the
    /// clip's first frame (entrance) or its last (exit).
    static func coversCanvas(_ clip: EditClip, edge: FadeEdge, canvas: CGSize) -> Bool {
        guard canvas.width > 0, canvas.height > 0 else { return false }
        let moment = edge == .fadeIn ? clip.timelineStart : clip.timelineEnd
        return PictureCoverage.covers(ClipCoverage.picture(clip, atTimeline: moment, canvas: canvas), canvas: canvas)
    }

    /// `motion` grown about the picture's centre just enough that the moved picture covers `rest` (the same clip's picture without the
    /// motion, at the same moment); unchanged when it already does. A motion that neither moves nor shrinks the picture covers its
    /// resting place already (zoom only grows it, fade and wipe do not move it).
    static func keepingCovered(_ motion: ClipAnimationState, rest: PictureCoverage.Picture) -> ClipAnimationState {
        guard motion.offset != .zero || motion.scale < 1 else { return motion }
        let moved = PictureCoverage.Picture(frame: motion.apply(to: rest.frame), rotationDegrees: rest.rotationDegrees)
        let growth = PictureCoverage.growth(moved, toCover: rest)
        guard growth > 1, growth.isFinite else { return motion }
        var covering = motion
        covering.scale *= growth
        return covering
    }
}
