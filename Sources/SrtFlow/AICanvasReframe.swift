import CoreGraphics
import Foundation
import SrtFlowMCPKit

// MARK: - What set_canvas tells the AI about the clips, texts and shapes
//
// What: when set_canvas changes the frame's shape, `CanvasReframe` (run by `perform`) keeps every framed clip's shape and every
// text's and shape's size on the frame (`OverlayReframe`). The reply says which items it re-expressed (`reframed`: the stored numbers
// changed so that x, y and scale read the same and nothing is stretched; texts and shapes got new font_size / width / height /
// line_width numbers for the same size on the frame) and what that leaves for the AI: picture clips that covered the old frame but
// not the new one (`no_longer_fill`: default-layout clips included — they letterbox like before), for edit_clips fit=fill; texts and
// shapes that sat inside the old frame and stick out of the new one (`off_frame`), for set_texts / set_shapes. Nothing listed: no
// field, no note.
// Not: the reframing itself (`CanvasReframe`, `OverlayReframe`), the canvas size (`TimelineRenderSize`).
// Cases: docs/bugfixes/2026-11-17-canvas-change-stretches-framed-clips.md, docs/bugfixes/2026-11-17-canvas-change-resizes-texts-and-shapes.md.

enum AICanvasReframe {
    /// The reply's extra fields for a set_canvas that turned `before` into `after`. `ids`: short ids of the project after the change.
    static func fields(before: TimelineState, after: TimelineState, ids: AIShortIDs) -> [String: JSONValue] {
        let old = TimelineRenderSize.size(for: before)
        let new = TimelineRenderSize.size(for: after)
        let was = Dictionary(before.allClips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var reframed: [String] = []
        var unfilled: [String] = []
        for clip in after.mainClips + after.overlayTracks.flatMap(\.clips) where !clip.isAudioOnly {
            guard let previous = was[clip.id] else { continue }
            if previous.placement != clip.placement || previous.animation != clip.animation { reframed.append(ids.short(clip.id)) }
            if AIFrameFit.describe(previous, canvas: old).fillsFrame, !AIFrameFit.describe(clip, canvas: new).fillsFrame {
                unfilled.append(ids.short(clip.id))
            }
        }
        let overlays = Overlays(before: before, after: after, old: old, new: new)
        var fields: [String: JSONValue] = [:]
        var notes: [String] = []
        if !reframed.isEmpty {
            notes.append("Clips keep their shape: reframed clips keep x, y and scale (as get_timeline reports them) on the new frame; nothing is stretched or cropped differently.")
        }
        if !overlays.resized.isEmpty {
            notes.append("Texts and shapes keep their size on the frame: reframed ones have updated font_size, box_width, width, height or line_width values; x and y stay. Preset text wraps still hug their words; other box_width values stay.")
        }
        reframed += overlays.resized.map { ids.short($0) }
        if !reframed.isEmpty { fields["reframed"] = .array(reframed.map { .string($0) }) }
        if !unfilled.isEmpty {
            fields["no_longer_fill"] = .array(unfilled.map { .string($0) })
            notes.append("Clips in no_longer_fill covered the old frame but not this one: edit_clips with fit=fill fills it again.")
        }
        if !overlays.offFrame.isEmpty {
            fields["off_frame"] = .array(overlays.offFrame.map { .string(ids.short($0)) })
            notes.append("Texts and shapes in off_frame sat inside the old frame and stick out of this one: move or resize them with set_texts or set_shapes.")
        }
        if !notes.isEmpty { fields["note"] = .string(notes.joined(separator: " ")) }
        return fields
    }

    /// The texts and shapes the change resized, and the ones it left partly outside the frame.
    private struct Overlays {
        var resized: [UUID] = []
        var offFrame: [UUID] = []

        init(before: TimelineState, after: TimelineState, old: CGSize, new: CGSize) {
            let texts = Dictionary(before.textOverlays.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for text in after.textOverlays {
                guard let previous = texts[text.id] else { continue }
                if previous.style != text.style || previous.boxWidth != text.boxWidth { resized.append(text.id) }
                if !text.isBlank, Self.inside(TextRenderer.layoutFrame(previous, canvas: old), old),
                   !Self.inside(TextRenderer.layoutFrame(text, canvas: new), new) {
                    offFrame.append(text.id)
                }
            }
            let shapes = Dictionary(before.shapes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for shape in after.shapes {
                guard let previous = shapes[shape.id] else { continue }
                if previous != shape { resized.append(shape.id) }
                if Self.inside(Self.extent(previous, old), old), !Self.inside(Self.extent(shape, new), new) { offFrame.append(shape.id) }
            }
        }

        /// Where a shape shows on the canvas: its frame (a line: the rotated stroke's box, `ShapeOutline.visibleBox`).
        private static func extent(_ shape: ShapeAnnotation, _ canvas: CGSize) -> CGRect {
            let frame = shape.frame(in: canvas)
            return ShapeOutline.visibleBox(for: shape, size: frame.size, strokeWidth: shape.strokeWidth(in: canvas))
                .offsetBy(dx: frame.minX, dy: frame.minY)
        }

        /// Inside the canvas to within half a pixel (the same test set_text uses for a text block, `AITextFit`).
        private static func inside(_ rect: CGRect, _ canvas: CGSize) -> Bool {
            AITextFit.overflow(of: rect, canvas: canvas) == nil
        }
    }
}
