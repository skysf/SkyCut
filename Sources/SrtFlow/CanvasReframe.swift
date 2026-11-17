import CoreGraphics
import Foundation

// MARK: - A canvas change keeps every clip's shape
//
// What: a clip's placement (`ClipPlacement`) and its position / size keyframes are fractions of the canvas, so the same numbers on a
// canvas of another shape stretch the picture: a clip filled into 9:16 came out squashed 3.16× after set_canvas 16:9 (P5 walkthrough,
// docs/bugfixes/2026-11-17-canvas-change-stretches-framed-clips.md). When an edit changes the canvas's shape — set_canvas, the canvas
// menu, auto following a new first V1 clip, a screen recording setting the ratio — every picture clip whose framing this edit did not
// set keeps what the inspector and the AI read: its centre (x, y on the canvas) and its size relative to the default layout (scale),
// per axis. So its shape stays and nothing is cropped differently; a clip that filled the old frame may not fill the new one, the same
// way the default layout letterboxes (the AI is told which: `AICanvasReframe`). Switching back restores the old numbers exactly.
// Texts and shapes keep their size on the frame by the same rule (`OverlayReframe`, called from here).
// Not: the default layout (`EditClip.defaultPlacement`), the canvas size (`TimelineRenderSize`), subtitles.
// Runs at the end of `VideoEditProject.perform`. Pure value: scripts/check-mcp.sh compiles it (checks/MCP/CanvasReframeChecks.swift).

enum CanvasReframe {
    /// When `state`'s canvas has another shape than `before`'s, re-expresses the framing of every picture clip whose framing this
    /// edit left as it was, and the size of every text and shape it left as it was. Returns the clips, texts and shapes it changed.
    @discardableResult
    static func keepShapes(_ state: inout TimelineState, after before: TimelineState) -> [UUID] {
        let old = TimelineRenderSize.size(for: before)
        let new = TimelineRenderSize.size(for: state)
        guard old.width > 0, old.height > 0, new.width > 0, new.height > 0,
              abs(old.width / old.height - new.width / new.height) > 1e-9 else { return [] }
        let was = Dictionary(before.allClips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var changed: [UUID] = []
        for clip in state.mainClips + state.overlayTracks.flatMap(\.clips) {
            guard let previous = was[clip.id], sameFraming(previous, clip),
                  let kept = reframed(clip, from: old, to: new), kept != clip else { continue }
            state.update(clip.id) { $0 = kept }
            changed.append(clip.id)
        }
        return changed + OverlayReframe.keepSizes(&state, after: before, from: old, to: new)
    }

    /// `clip`, framed for a canvas of size `old`, re-expressed for `new`: same centre, same size relative to the default layout on
    /// each axis. nil when there is nothing to keep (default layout and no size keys, audio, picture size unknown).
    static func reframed(_ clip: EditClip, from old: CGSize, to new: CGSize) -> EditClip? {
        let sizeKeys = clip.animation.map { !$0.width.isEmpty || !$0.height.isEmpty } ?? false
        guard !clip.isAudioOnly, clip.croppedDisplaySize != nil, clip.placement != nil || sizeKeys else { return nil }
        let was = clip.defaultPlacement(canvas: old)
        let now = clip.defaultPlacement(canvas: new)
        guard was.width > 0, was.height > 0 else { return nil }
        let scaleX = now.width / was.width
        let scaleY = now.height / was.height
        var result = clip
        if let placement = clip.placement {
            let kept = ClipPlacement(
                centerX: placement.centerX, centerY: placement.centerY,
                width: placement.width * scaleX, height: placement.height * scaleY
            )
            result.placement = PlacementDefault.normalized(kept, fallback: now, canvas: new)
        }
        if var animation = clip.animation, sizeKeys {
            animation.width = scaled(animation.width, by: scaleX)
            animation.height = scaled(animation.height, by: scaleY)
            result.animation = animation
        }
        return result
    }

    /// The edit did not frame this clip: placement, crop, position / size keys and picture size are as they were.
    private static func sameFraming(_ a: EditClip, _ b: EditClip) -> Bool {
        a.placement == b.placement && a.crop == b.crop && a.info?.displaySize == b.info?.displaySize
            && a.animation?.centerX == b.animation?.centerX && a.animation?.centerY == b.animation?.centerY
            && a.animation?.width == b.animation?.width && a.animation?.height == b.animation?.height
    }

    private static func scaled(_ track: KeyframeTrack, by factor: Double) -> KeyframeTrack {
        KeyframeTrack(keys: track.keys.map { Keyframe(time: $0.time, value: $0.value * factor, easing: $0.easing) })
    }
}
