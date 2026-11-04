import Foundation

// 已存公开制作计划的按需说明和未知字段检查；不进入常驻 tools/list，也不包含收费凭据或私有配方。
// 这里描述作者输入，当前素材身份、样本覆盖和实际声音仍由 App 的严格读器核对。
public enum MCPProductionSchema {
    public static func validationSchema(for tool: MCPToolName) -> JSONValue? {
        guard tool == .saveProject else { return nil }
        var schema = tool.definition.inputSchema.objectValue!
        var fields = schema["properties"]!.objectValue!
        fields["production"] = nullable(plan)
        schema["properties"] = .object(fields)
        return .object(schema)
    }

    public static var contract: [String: JSONValue] {
        ["production_schema": nullable(plan),
         "production_expected_revision_schema": MCPSchema.integer("Compare-and-set revision from get_timeline.production; 0 when absent.", minimum: 0),
         "production_readback": [
            "revision": "Current authored revision. Identical saves do not change it; repeat reads do not renew evidence.",
            "plan": "Round-trippable author input. Pass only this object as save_project.production, plus expected_revision; null explicitly clears the plan in one undo step when the current revision is still valid for comparison.",
            "expected_snapshots": "Current shots[].output_binding rebinds actual clip/file/use geometry; shots[].source_snapshot binds authored film/render plus actual output review. previous_snapshot/next_snapshot and their timeline_times cover each actual composed seam. sound_cues[].snapshot binds cue timing and current mix.",
            "readiness": "Derived pending/stale evidence. input_anchor_current and needs_refresh_for_regeneration concern source references; output_observations_current concerns inspected output. Saving a story does not generate or certify media."
         ],
         "production_workflow": [
            "Preparation may precede a plan. Read public models or prepare_references, use prepared_render and add explicit context, then save the complete ordered story with expected_revision. New render specifications need a current locally cached public catalog; save never queries it silently. expected_revision without production is refused, including null; omit both for ordinary save.",
            "Quote and new submission require the exact saved current/adjacent film/render, revisions, current source identities and required current anchors. Any change invalidates the quote and spending approval. Recovery of an already submitted original operation remains GET-only and is not blocked by later story edits.",
            "Bind an output clip explicitly. Replacing/trimming the same clip UUID leaves its old output_binding stale. Echo the current expected_snapshots.shots[].output_binding to accept that output; output_review.source_snapshot is separate evidence, never an implicit rebind.",
            "Inspect required early samples (0, .25, .5, 1, 1.5, 2 seconds clipped to the used range), every action turning point, the final used 1-2 seconds and both actual composed seams. Record only observations actually made, with current source/seam snapshots. A quote's seam_review is preflight and cannot stand in for output_review.",
            "expected_snapshots.shots[].source_geometry exposes exact source_file/source_in/source_out/source_duration/speed/timeline_start/fps and first_project_time/last_project_time for reconstructing an owned scratch clip. It is null for stills; frame times are null when no usable project-grid point exists. These are raw Double metadata and requested project positions, not decoded actualTime or new file-identity evidence.",
            "For native anchors, use your own background scratch project with the authoritative source file, used window, speed, project frame rate and placement; freeze_frame mutates that scratch clip. Keep the authoritative output unchanged, or undo a freeze there before binding its original window. Only current matching source/PNG identities and in-window native requested/actual times are accepted. Metadata is upright_source, not final composition; incomplete ordinary freeze results are not valid anchors.",
            "Anchor roles: first=previous.last_used or current.first_used; last=current.last_used or next.first_used. Prepare that exact extracted PNG, then bind its returned originals URL and source_frame; native PNG identity must equal the actual first/last uploaded reference file. Unchanged stored anchors remain historical inputs after output replacement; obtain fresh current anchors before regeneration.",
            "Plan music, environment, action foley and intentional silence separately. Foley names one new visible action, never an already completed action. Realign cues after picture changes. Use listen for numeric measurements; set listened_note only after actually auditioning. Silence needs its purpose and recovery time."
         ]]
    }

    public static var plan: JSONValue {
        object([
            "story": text(2000),
            "shots": array(shot, minimum: 1, maximum: 100, description: "Ordered complete story; shot index/total, neighbors and revisions must agree."),
            "sound_cues": array(soundCue, maximum: 400, description: "Distinct cue ids; omitted means no cues.")
        ], required: ["story", "shots"], description: "Public authored story only. Unknown fields are refused; no pins, credentials or private recipe information.")
    }

    private static var shot: JSONValue {
        object([
            "film": MCPFilmSchema.film, "render": MCPFilmSchema.render,
            "clip_id": nullable(text(80)),
            "output_binding": nullable(fingerprint),
            "output_review": nullable(outputReview),
            "anchors": array(anchor, maximum: 2, description: "At most one first and one last input anchor; omitted means none.")
        ], required: ["film", "render"], description: "clip_id names an actual project output. Preserve old stale bindings/evidence or explicitly refresh them; authoring never silently renews them.")
    }

    private static var outputReview: JSONValue {
        object([
            "source_times": times,
            "action_samples": array(object([
                "action_id": actionID, "source_times": times, "notes": text(400)
            ]), maximum: 24, description: "One record per new visible action, with at least two usable project-frame positions around its turn, at least one project-frame apart in source time."),
            "notes": text(1000), "source_snapshot": fingerprint,
            "previous": nullable(outputSeam), "next": nullable(outputSeam)
        ], required: ["source_times", "notes", "source_snapshot"], description: "Caller-authored visual observations bound to the current authored render/output. Times are requests, not native decoder actualTime.")
    }

    private static var outputSeam: JSONValue {
        object(["timeline_times": times, "notes": text(1000), "snapshot": fingerprint],
               description: "Actual adjacent composed clips, inspected on both sides; use expected snapshot and sample requests.")
    }

    private static var soundCue: JSONValue {
        object([
            "id": text(80),
            "shot_ids": array(text(80), minimum: 1, maximum: 100, unique: true, description: "Existing shots; foley must name exactly one."),
            "layer": choice(["music", "environment", "foley", "silence"]), "purpose": text(400),
            "at": seconds, "duration": ["type": "number", "exclusiveMinimum": 0, "maximum": 86400],
            "action_id": nullable(actionID), "audio_clip_id": nullable(text(80)),
            "silence_reason": nullable(text(400)), "recovery_at": nullable(seconds),
            "alignment": nullable(object([
                "snapshot": fingerprint, "measured_note": nullable(text(400)), "listened_note": nullable(text(400))
            ], required: ["snapshot"], description: "Current expected cue snapshot. Measured and actually auditioned evidence are distinct; old unchanged evidence stays stale after edits."))
        ], required: ["id", "shot_ids", "layer", "purpose", "at", "duration"],
        description: "at+duration<=86400. Foley names a new action; silence has no audio clip and requires a reason plus recovery_at equal to its end.")
    }

    private static var anchor: JSONValue {
        object([
            "role": choice(["first", "last"]), "source_edge": choice(["first_used", "last_used"]),
            "from_shot_id": text(80), "asset_url": MCPSchema.string("Exact corresponding first/last HTTPS originals URL returned by preparation."),
            "source_frame": sourceFrame
        ], description: "Current accepted native source-frame evidence. The PNG must be authorized, unchanged, and exactly the prepared reference.")
    }

    /// 这是可写入 anchor 的严格子集；freeze_frame 普通回读可能含 null/false，不能照单当成有效证据。
    private static var sourceFrame: JSONValue {
        object([
            "version": ["type": "integer", "enum": [1]], "scope": choice(["upright_source"]),
            "source_clip_uuid": ["type": "string", "format": "uuid"], "source_file": path,
            "source_file_identity": fileIdentity, "source_file_unchanged": truth,
            "used_source_window": object([
                "start": MCPSchema.number("Used source start.", minimum: 0),
                "duration": ["type": "number", "exclusiveMinimum": 0],
                "end": MCPSchema.number("Exactly start+duration; excluded."), "bounds": choice(["half_open"])
            ]),
            "requested_source_time": nativeTime(requested: true), "actual_source_time": nativeTime(),
            "drift_source_seconds": MCPSchema.number("Exact native (actual-requested).seconds; within current source-space half frame."),
            "used_tolerance_fallback": ["type": "boolean"], "used_tolerance": nativeTime(),
            "requested_in_used_window": truth, "actual_in_used_window": truth,
            "image": object(["file": path, "file_identity": fileIdentity], description: "Extracted PNG with captured native file identity.")
        ], description: "Complete original native metadata, unchanged. All fields required. No inferred timestamps; the half-open source end is never a used frame.")
    }

    private static func nativeTime(requested: Bool = false) -> JSONValue {
        object([
            "value": ["type": "string", "pattern": "^(0|[1-9][0-9]*)$", "description": "Exact nonnegative Int64 decimal ticks."],
            "timescale": requested ? ["type": "integer", "enum": [600]] : MCPSchema.integer("Native timescale.", minimum: 1, maximum: 2147483647),
            "epoch": choice(["0"]), "flags": ["type": "integer", "enum": [1, 3]],
            "seconds": MCPSchema.number("Exact numeric rational seconds; null is not accepted for anchors.", minimum: 0)
        ], description: "Original CMTime fields; preserve native precision and flags.")
    }

    private static var fileIdentity: JSONValue {
        object([
            "path": path, "device": unsignedDecimal, "inode": unsignedDecimal,
            "bytes": ["type": "string", "pattern": "^[1-9][0-9]*$", "description": "Positive UInt64 decimal byte count."],
            "modified": MCPSchema.number("Native modification time; finite.")
        ], description: "Captured nonempty regular-file stat. Exact path and current stat must still match.")
    }

    private static let path: JSONValue = ["type": "string", "pattern": "^/", "maxLength": 4096,
        "description": "Exact standardized absolute local path, no controls, at most 4096 UTF-8 bytes."]
    private static let unsignedDecimal: JSONValue = ["type": "string", "pattern": "^(0|[1-9][0-9]*)$", "description": "Exact UInt64 decimal."]
    private static let truth: JSONValue = ["type": "boolean", "enum": [true]]
    private static let fingerprint: JSONValue = ["type": "string", "pattern": "^[a-f0-9]{64}$"]
    private static let actionID: JSONValue = ["type": "string", "pattern": "^[a-z0-9_-]{1,48}$"]
    private static let seconds = MCPSchema.number("Finite seconds.", minimum: 0, maximum: 86400)
    private static var times: JSONValue { array(seconds, maximum: 128, unique: true, description: "Distinct finite sample requests in ascending order.") }
    private static func text(_ maximum: Int) -> JSONValue { ["type": "string", "minLength": 1, "maxLength": .number(Double(maximum))] }
    private static func choice(_ values: [String]) -> JSONValue { ["type": "string", "enum": .array(values.map(JSONValue.string))] }

    private static func nullable(_ value: JSONValue) -> JSONValue {
        var result = value.objectValue!
        result["type"] = .array([result["type"]!, "null"])
        return .object(result)
    }

    private static func array(_ item: JSONValue, minimum: Int = 0, maximum: Int, unique: Bool = false, description: String) -> JSONValue {
        var value: [String: JSONValue] = ["type": "array", "items": item,
            "minItems": .number(Double(minimum)), "maxItems": .number(Double(maximum)), "description": .string(description)]
        if unique { value["uniqueItems"] = true }
        return .object(value)
    }

    private static func object(_ fields: [String: JSONValue], required: [String]? = nil, description: String? = nil) -> JSONValue {
        var value = MCPSchema.object(fields, required: required ?? fields.keys.sorted(), description: description).objectValue!
        value["additionalProperties"] = false
        return .object(value)
    }
}
