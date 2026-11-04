import Foundation

// 官方 film 的公开参数说明；只描述用户故事，不列私有配方。严格值验证仍由 App 的 SkyStudioFilm 负责。
public enum MCPFilmSchema {
    /// 清单按需展开，与批量工具同一做法；省略长 schema 不代表允许未知公开字段。
    public static func validationSchema(for tool: MCPToolName) -> JSONValue? {
        guard tool == .generateMedia else { return nil }
        var schema = tool.definition.inputSchema.objectValue!
        var fields = schema["properties"]!.objectValue!
        fields["film"] = film
        schema["properties"] = .object(fields)
        return .object(schema)
    }

    public static var contract: JSONValue {
        ["film_schema": film, "seam_review_schema": review,
         "production_enabled": .null,
         "workflow": [
            "Use your own saved background project. Read current public models; no private recipe or research source belongs in a tool argument.",
            "prepare_references=true prepares effective render and uploads any local original images; omit film/quote_only/tokens. get_job returns prepared_render and optional prepared_references. Text-only preparation uploads nothing. Add explicit context to the render for neighbor declarations.",
            "Repeat the exact local paths, public specification and film with quote_only=true and prepared_references when present. Only the official quote resolves supported context; no quote uploads or reserves credits.",
            "Read both declared seam fingerprints from the quote. Submit the unchanged args with quote_only=false, quote_token, explicit seam_review and a stable idempotency_key. Expired or changed requests require a new quote and a fresh review before spending.",
            "Preflight acknowledgements prove only declared contracts. Inspect the actual generated start, action turns, final used range and both output seams. Measure audio with listen; record subjective listening only when actually auditioned.",
            "Preserve idempotency_key after failure. Reopening the same saved project and repeating submitted args recovers only the known original job/output; unknown no-ID receipts never POST again. Restart recovery leaves local_budget_reconciliation=pending without a second local reserve/refund."
         ]]
    }

    public static var film: JSONValue {
        object([
            "intent": choice(["original_film"]), "category": choice(["science_fiction"]), "footage": choice(["none"]),
            "context": context,
            "shot": object(["id": text, "index": MCPSchema.integer("Zero-based index.", minimum: 0, maximum: 99),
                "total": MCPSchema.integer("Shot count.", minimum: 1, maximum: 100),
                "revision": MCPSchema.integer("Increment after changes.", minimum: 1, maximum: 10000),
                "entry": state, "exit": state, "actions": actions]),
            "previous": neighbor("exit"), "next": neighbor("entry"),
            "sound": object(["bed_id": text, "music": text, "environment": text, "foley": text])
        ], required: ["intent", "category", "footage", "context", "shot", "sound"],
        description: "Original public story. Every non-edge shot needs both neighbors, including revision 1. Continuous cuts preserve all state and sound bed. Completed actions persist; shot actions must be new. No research, recipes or private styles.")
    }

    public static var review: JSONValue {
        object(["previous": ["type": ["string", "null"]], "next": ["type": ["string", "null"]]],
               description: "Exact quote fingerprints; absent edge=null. Explicit preflight review, not output acceptance.")
    }

    private static let text: JSONValue = ["type": "string", "minLength": 1, "maxLength": 80]
    private static let actions: JSONValue = ["type": "array", "maxItems": 24, "uniqueItems": true,
        "items": ["type": "string", "pattern": "^[a-z0-9_-]{1,48}$"]]

    private static var state: JSONValue {
        var fields = Dictionary(uniqueKeysWithValues: ["actor_position", "grip", "prop_location", "action_phase", "spatial_relation", "gaze", "screen_direction", "lighting"].map { ($0, text) })
        fields["hand"] = choice(["left", "right", "both", "none"])
        fields["completed_actions"] = actions
        return object(fields)
    }

    private static var context: JSONValue {
        object(["environment": choice(["interior", "exterior", "space"]), "light_source": choice(["practical", "daylight", "mixed", "none"]),
                "shot_task": choice(["establish_space", "read_action", "read_object", "read_reaction", "show_consequence"])])
    }

    private static func neighbor(_ boundary: String) -> JSONValue {
        var schema = object(["shot_id": text, "sound_bed_id": text, boundary: state,
            "render": object(["kind": choice(["image", "text_to_video", "image_to_video"]),
                "model": ["type": "string", "minLength": 1, "maxLength": 160], "prompt": ["type": "string", "minLength": 1, "maxLength": 4000],
                "context": context, "params": MCPSchema.object([:], description: "Exact effective public model parameters from /models; no private knobs."),
                "inputs": object(["image_url": imageURL, "last_frame_url": imageURL,
                    "references": MCPSchema.array(of: object(["type": choice(["image"]), "url": imageURL]), "Ordered real image assets.")], required: [])],
                required: ["kind", "model", "prompt", "context"]),
            "cut": object(["type": choice(["continuous", "time_jump", "location_change", "time_location_jump", "montage"]),
                "reason": ["type": "string", "minLength": 8, "maxLength": 160],
                "reset_fields": MCPSchema.array(of: choice(["actor_position", "hand", "grip", "prop_location", "action_phase", "spatial_relation", "gaze", "screen_direction", "lighting", "sound_bed"]), "Intentional cut: exactly changed fields permitted for its type."),
                "offscreen_actions": actions], required: ["type"], description: "continuous takes only type; other cuts require reason and reset_fields. Never erase action history.")]).objectValue!
        schema["type"] = ["object", "null"]
        return .object(schema)
    }

    private static let imageURL = MCPSchema.string("Exact HTTPS originals file_url returned by this account's preparation; no guessed or generated URL.")
    private static func choice(_ values: [String]) -> JSONValue { ["type": "string", "enum": .array(values.map(JSONValue.string))] }
    private static func object(_ fields: [String: JSONValue], required: [String]? = nil, description: String? = nil) -> JSONValue {
        var value = MCPSchema.object(fields, required: required ?? fields.keys.sorted(), description: description).objectValue!
        value["additionalProperties"] = false
        return .object(value)
    }
}
