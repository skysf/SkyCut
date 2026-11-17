import Foundation

// MARK: - The web-motion editing tool's card and parameters
// Stores no page and runs no code here. Native presets stay on set_text; this tool edits a rendered movie clip.
// The page contract, approval and recovery are in MCPGuideMotionTopic (web-motion-renderer.md / ai-control-mcp.md).

enum MCPMotionTool {
    static var definition: MCPToolDefinition {
        MCPToolDefinition(
            .setMotion, title: "Web motion",
            description: """
            Place a web-motion template or page on an upper video track; clip_id updates the same clip. Prefer native set_text \
            motion_preset, then get_timeline's motion library, then a new page. One undo step. New page code may return \
            needs_confirmation; network stays locked. Returns a result or job_id; wait with get_job. Read skycut_guide topic=set_motion.
            """,
            input: MCPSchema.object([
                "template": MCPSchema.string("Web template id from get_timeline's motion library."),
                "page": MCPSchema.string("HTML fallback; window.motion.frame(t) draws each frame."),
                "parameters": MCPSchema.object([:], description: "Page values; passed keys merge with the stored values."),
                "fields": MCPSchema.array(of: MCPSchema.object([
                    "key": MCPSchema.string("Parameter key."),
                    "label": MCPSchema.string("Form label."),
                    "type": MCPSchema.string("Form control.", oneOf: ["text", "font", "color", "number"]),
                    "minimum": MCPSchema.number("Number's minimum."),
                    "maximum": MCPSchema.number("Number's maximum.")
                ], required: ["key", "label", "type"]), "Editable parameter form."),
                "clip_id": MCPSchema.string("Re-render this web-motion clip instead of adding one."),
                "at": MCPSchema.number("Timeline start, seconds (≥ 0); exclusive with hit_at.", minimum: 0),
                "hit_at": MCPSchema.number("Timeline second (≥ 0) the page's hit lands on; exclusive with at.", minimum: 0),
                "hit": MCPSchema.number("Page-relative hit, seconds (0–60, inside duration).", minimum: 0, maximum: 60),
                "duration": MCPSchema.number("Page length, seconds (> 0, at most 60).", minimum: 0, maximum: 60),
                "track": MCPSchema.string("Upper video track V2+ or new_video; default first free upper track."),
                "name": MCPSchema.string("Name for this project's reusable page."),
                "fonts": MCPSchema.array(of: MCPSchema.string("Installed font name."), "Fonts the page uses; recorded for portability warnings."),
                "confirm_token": MCPSchema.confirmToken
            ])
        )
    }
}
