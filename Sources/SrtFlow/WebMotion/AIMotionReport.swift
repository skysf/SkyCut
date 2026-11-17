import Foundation
import SrtFlowMCPKit
import SrtFlowWebMotionKit

// Structured results preserve the helper's errors verbatim and tell the AI which rendered moments need visual review.
enum AIMotionReport {
    static func checks(_ result: WebMotionResult) -> JSONValue {
        .array(result.checks.map { check in
            ["name": .string(check.name.rawValue), "passed": check.passed.map(JSONValue.bool) ?? .null, "detail": .string(check.detail)]
        })
    }

    static func success(_ placement: WebMotionActions.Placement, state: TimelineState) -> AIToolResult {
        let clip = placement.clip
        let rendered = placement.rendered
        let hit = clip.timelineStart + (rendered.record.hitTime - clip.sourceStart) / max(0.05, clip.speed)
        let times = [clip.timelineStart + clip.timelineDuration * 0.1, hit, clip.timelineStart + clip.timelineDuration * 0.9]
            .filter { $0 >= clip.timelineStart && $0 < clip.timelineEnd }.sorted()
        var payload: [String: JSONValue] = [
            "clip_id": .string(AIShortIDs(state: state).short(clip.id)),
            "template": .string("project:\(clip.id.uuidString.lowercased())"),
            "start": AIFormat.seconds(clip.timelineStart), "end": AIFormat.seconds(clip.timelineEnd),
            "render_seconds": .number(rendered.cacheHit ? 0 : rendered.result.timing.totalSeconds),
            "cache_hit": .bool(rendered.cacheHit), "checks": checks(rendered.result),
            "look_times": .array(times.map(AIFormat.seconds)),
            "next_step": "Use look with these times to review the motion over the picture. Parameters can be changed with set_motion and this clip_id."
        ]
        if let track = state.location(of: clip.id)?.track { payload["track"] = .string(AITrackName.name(of: track)) }
        if !placement.warnings.isEmpty { payload["warnings"] = .array(placement.warnings.map(JSONValue.string)) }
        return .ok(.object(payload), changed: true)
    }

    static func failure(_ error: Error) -> AIToolResult {
        var payload: [String: JSONValue] = ["error": .string(String(describing: error)), "changed": false,
                                          "guide": "skycut_guide topic=set_motion"]
        if case WebMotionRenderError.rejected(let result) = error {
            payload["error"] = .string(result.failure?.message ?? String(describing: error))
            payload["checks"] = checks(result)
            payload["page_errors"] = .array(result.pageErrors.map(JSONValue.string))
        } else if let error = error as? AIToolError { payload["error"] = .string(error.message) }
        return AIToolResult(payload: .object(payload), isError: true)
    }
}
