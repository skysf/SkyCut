import CoreGraphics
import Foundation

// MARK: - A canvas change keeps every text's and shape's size on the frame
//
// What: texts and shapes store their sizes against two different edges of the canvas. Font size, stroke, shadow, plate, letter
// spacing and a shape's line width and cover strength are pixels of a 1080-high frame (they grow with the frame's height); a
// shape's width (a line's length, a circle's diameter) is a fraction of the frame's width, a rectangle's height one of its
// height. So when the canvas changes shape the same numbers came out mismatched: on 16:9 → 9:16 a 0.3 × 0.22 rectangle turned
// from 2.4:1 into 0.8:1, a ring's stroke grew 1.78× while the ring shrank to 0.56×, and every text grew 1.78× against a frame
// 0.56× as wide — the "9:16 numbers are 1.78× too big" of the style cards (docs/bugfixes/2026-11-17-canvas-change-resizes-texts-and-shapes.md).
// Rule (the clips' rule, `CanvasReframe`: keep x and y, never stretch): every text and shape the edit did not size itself keeps
// its centre (x, y on the frame) and its size against the frame's short side — all its lengths are multiplied by one factor,
// so nothing is stretched and its parts keep their proportions. Every preset frame is 1080 on its short side, so on those
// switches a text or shape keeps its pixels; switching back restores the numbers (except where a range clamps a text value).
// A text's wrap width stays the same share of the frame's width: it is where lines wrap, like x and y, not the size of the
// letters; a line that no longer fits wraps. Rotation, opacity, timing and animation are untouched.
// Not: clips (`CanvasReframe`), subtitles (their size follows the subtitle style), the canvas size (`TimelineRenderSize`).
// Called by `CanvasReframe.keepShapes` (run at the end of `VideoEditProject.perform`). Pure value: scripts/check-mcp.sh compiles it
// (checks/MCP/CanvasOverlayChecks.swift).

enum OverlayReframe {
    /// What each kind of stored number is multiplied by when the canvas goes from `old` to `new`.
    struct Factors: Equatable {
        /// Pixels of a 1080-high frame and fractions of the frame's height.
        var height: Double
        /// Fractions of the frame's width.
        var width: Double

        init(from old: CGSize, to new: CGSize) {
            // The size in pixels changes with the frame's short side.
            let pixels = min(new.width, new.height) / min(old.width, old.height)
            height = pixels * old.height / new.height
            width = pixels * old.width / new.width
        }
    }

    /// Re-expresses the texts and shapes of `state` (which had `before`'s canvas, `old`) for the canvas `new`, leaving the ones
    /// this edit sized itself. Returns the ones it changed.
    @discardableResult
    static func keepSizes(_ state: inout TimelineState, after before: TimelineState, from old: CGSize, to new: CGSize) -> [UUID] {
        let factors = Factors(from: old, to: new)
        var changed: [UUID] = []
        let oldTexts = Dictionary(before.textOverlays.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for text in state.textOverlays {
            guard let was = oldTexts[text.id], sameSize(was, text) else { continue }
            state.updateTextOverlay(text.id) { $0.style = scaled($0.style, by: factors.height) }
            if state.textOverlays.first(where: { $0.id == text.id }) != text { changed.append(text.id) }
        }
        let oldShapes = Dictionary(before.shapes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for shape in state.shapes {
            guard let was = oldShapes[shape.id], sameSize(was, shape) else { continue }
            state.updateShape(shape.id) { $0 = scaled($0, by: factors) }
            if state.shapes.first(where: { $0.id == shape.id }) != shape { changed.append(shape.id) }
        }
        return changed
    }

    /// Every length of a text's look, in pixels of a 1080-high frame, times `factor` (clamped to the style's ranges when the
    /// text is stored: `TimelineState.updateTextOverlay`).
    static func scaled(_ style: TextStyle, by factor: Double) -> TextStyle {
        var style = style
        style.fontSize *= factor
        style.letterSpacing *= factor
        if var stroke = style.stroke {
            stroke.width *= factor
            style.stroke = stroke
        }
        if var shadow = style.shadow {
            shadow.offsetX *= factor
            shadow.offsetY *= factor
            shadow.blur *= factor
            style.shadow = shadow
        }
        if var plate = style.background {
            plate.cornerRadius *= factor
            plate.paddingX *= factor
            plate.paddingY *= factor
            style.background = plate
        }
        return style
    }

    /// A shape with its width, height, line width and cover strength re-expressed.
    static func scaled(_ shape: ShapeAnnotation, by factors: Factors) -> ShapeAnnotation {
        var shape = shape
        shape.width *= factors.width
        shape.height = shape.kind.keepsSquare ? shape.width : shape.height * factors.height
        shape.lineWidth *= factors.height
        if shape.kind.isCover {
            let range = ShapeKind.coverAmountRange
            shape.coverAmount = min(max(shape.coverAmount * factors.height, range.lowerBound), range.upperBound)
        }
        return shape
    }

    /// The edit did not size this text: where it sits, how wide it wraps and how it looks are as they were.
    private static func sameSize(_ a: TextOverlay, _ b: TextOverlay) -> Bool {
        a.centerX == b.centerX && a.centerY == b.centerY && a.boxWidth == b.boxWidth && a.style == b.style
    }

    /// The edit did not size this shape.
    private static func sameSize(_ a: ShapeAnnotation, _ b: ShapeAnnotation) -> Bool {
        a.kind == b.kind && a.centerX == b.centerX && a.centerY == b.centerY && a.width == b.width && a.height == b.height
            && a.lineWidth == b.lineWidth && a.coverAmount == b.coverAmount
    }
}
