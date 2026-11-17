import CoreGraphics
import Foundation
import SrtFlowMCPKit

// MARK: - Does the picture cover the frame, in words for the AI
//
// What: the fields get_timeline and the edit replies put in a clip's `picture` — fills_frame (covers the whole canvas at every frame it
// is on screen: rotation, crop, flips and keyframes included), and when not: fill_scale (the smallest steady scale that covers it
// throughout) and fills_except (the timeline seconds it fails, when that is only part of the time) — and look's per-frame `uncovered`
// (bare edges with how deep the gap reaches, bare corners with how far along each edge, canvas pixels).
// Both from `ClipCoverage` / `PictureCoverage`; nothing here measures pixels: black footage is never "uncovered".
// Case: docs/bugfixes/2026-11-17-fills-frame-ignores-rotation-and-motion.md. Rule: docs/architecture/preview-free-transform.md.
// Not: how the rest of `picture` is written (AITimelineSummary.picture), the frames look draws (AIFrameComposer).

enum AIPictureCoverage {
    /// fills_frame always; fill_scale and (only part of the time) fills_except when it does not fill.
    static func fields(_ fill: ClipCoverage.Fill) -> [String: JSONValue] {
        var fields: [String: JSONValue] = ["fills_frame": .bool(fill.fillsFrame)]
        guard !fill.fillsFrame else { return fields }
        if let scale = fill.fillScale { fields["fill_scale"] = .number(scale) }
        if fill.isPartial {
            fields["fills_except"] = .array(fill.unfilled.map { [AIFormat.seconds($0.lowerBound), AIFormat.seconds($0.upperBound)] })
        }
        return fields
    }

    /// look's `uncovered` for the timeline frame at `time`: nil when the pictures on screen cover the whole canvas.
    static func uncovered(_ state: TimelineState, at time: Double) -> JSONValue? {
        let canvas = TimelineRenderSize.size(for: state)
        return json(PictureCoverage.gaps(ClipCoverage.coveringPictures(in: state, at: time, canvas: canvas), canvas: canvas))
    }

    /// `{"left": 58, "top_right": [317, 28]}`: an edge with the gap's depth, a corner with [along the top / bottom edge, along the
    /// left / right edge].
    static func json(_ gaps: PictureCoverage.Gaps) -> JSONValue? {
        guard !gaps.isEmpty else { return nil }
        var object: [String: JSONValue] = [:]
        for (edge, depth) in gaps.edges { object[edge.rawValue] = .number(Double(depth)) }
        for (corner, extent) in gaps.corners {
            object[corner.rawValue] = [.number(Double(extent.width)), .number(Double(extent.height))]
        }
        return .object(object)
    }
}
