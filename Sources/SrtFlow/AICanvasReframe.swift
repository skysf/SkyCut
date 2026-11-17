import Foundation
import SrtFlowMCPKit

// MARK: - What set_canvas tells the AI about the clips
//
// What: when set_canvas changes the frame's shape, `CanvasReframe` (run by `perform`) keeps every framed clip's shape. The reply says
// which clips it re-expressed (`reframed`: the stored numbers changed so that x, y and scale read the same and the picture is not
// stretched) and which picture clips covered the old frame but not the new one (`no_longer_fill`: default-layout clips included — they
// letterbox like before), so the AI knows what to pass to edit_clips fit=fill. Nothing listed: neither field nor the note.
// Not: the reframing itself (`CanvasReframe`), the canvas size (`TimelineRenderSize`).
// Case: docs/bugfixes/2026-11-17-canvas-change-stretches-framed-clips.md.

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
        var fields: [String: JSONValue] = [:]
        var notes: [String] = []
        if !reframed.isEmpty {
            fields["reframed"] = .array(reframed.map { .string($0) })
            notes.append("Clips keep their shape: reframed clips keep x, y and scale (as get_timeline reports them) on the new frame; nothing is stretched or cropped differently.")
        }
        if !unfilled.isEmpty {
            fields["no_longer_fill"] = .array(unfilled.map { .string($0) })
            notes.append("Clips in no_longer_fill covered the old frame but not this one: edit_clips with fit=fill fills it again.")
        }
        if !notes.isEmpty { fields["note"] = .string(notes.joined(separator: " ")) }
        return fields
    }
}
