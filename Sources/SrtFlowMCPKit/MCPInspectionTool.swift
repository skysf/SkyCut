import Foundation

// 成片疑点检查的说明与参数；执行和分析均在 App，不在小程序里读媒体。
enum MCPInspectionTool {
    static let definition = MCPToolDefinition(.inspectVideo, title: "Inspect finished video", description: """
    Pre-delivery suspects only: picture, sound and sentence cuts; never blocks export. Returns job_id: wait with get_job. \
    intentional marks a finding with a reason (one undo step); otherwise never edits. skycut_guide topic=inspect_video. \
    Outside files may return needs_confirmation.
    Example: {"image":false}
    """, input: MCPSchema.object([
        "file": MCPSchema.string("Optional matching export, same length/timestamps."),
        "from": MCPSchema.number("Timeline start seconds (default 0).", minimum: 0),
        "to": MCPSchema.number("Timeline end seconds (≥ 0; default: the end).", minimum: 0),
        "silence_db": MCPSchema.number("Silent below dBFS (default -45).", minimum: -80, maximum: -10),
        "min_silence": MCPSchema.number("Minimum silent seconds (default 0.5).", minimum: 0.1, maximum: 10),
        "image": MCPSchema.boolean("Suspect screenshots, default true."),
        // Second-tier sound checks (2026-11-18, AIDeliverySoundRoles): what SkyCut can't tell from where a sound came from.
        "sounds": MCPSchema.object([:], description: "Track or clip id → voice|music|effects|ambience|object where SkyCut can't tell: {\"A2\":\"music\"}."),
        "intentional": MCPSchema.object([
            "job_id": MCPSchema.string("Completed inspection job."),
            "key": MCPSchema.string("Finding key from that report."),
            "reason": MCPSchema.string("One line, 1–240 characters.")
        ], required: ["job_id", "key", "reason"], description: "Mark one finding; omit inspection fields."),
        "clear_intentional": MCPSchema.string("Remove a saved mark by key; one undo step."),
        "confirm_token": MCPSchema.confirmToken
    ]))
}
