import Foundation

// 成片疑点检查的说明与参数；执行和分析均在 App，不在小程序里读媒体。
enum MCPInspectionTool {
    static let definition = MCPToolDefinition(.inspectVideo, title: "Inspect finished video", description: """
    Suspect audio cutoffs/overlaps/silence, black frames and subtitle bounds/overlaps; never edits. Defaults: audio \
    seams and last 3s; from/to selects a range. Uses current project style. file must match this timeline. Returns \
    job_id; get_job gives times/reasons, screenshots and temporary WAV auditions. Sampled, needs human review; \
    no transcription. External reads may need approval.
    """, input: MCPSchema.object([
        "file": MCPSchema.string("Optional matching export, same length/timestamps."),
        "from": MCPSchema.number("Timeline start seconds (default 0).", minimum: 0),
        "to": MCPSchema.number("Timeline end seconds (default end).", minimum: 0),
        "silence_db": MCPSchema.number("Silent below dBFS (default -45).", minimum: -80, maximum: -10),
        "min_silence": MCPSchema.number("Minimum silent seconds (default 0.5).", minimum: 0.1, maximum: 10),
        "image": MCPSchema.boolean("Suspect screenshots, default true."),
        "confirm_token": MCPSchema.confirmToken
    ]))
}
