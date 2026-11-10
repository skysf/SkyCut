import Foundation

// 成片疑点检查的说明与参数；执行和分析均在 App，不在小程序里读媒体。
enum MCPInspectionTool {
    static let definition = MCPToolDefinition(.inspectVideo, title: "Inspect finished video", description: """
    Check a timeline or its export for cut-off, overlapping or silent sound at seams, black frames and subtitle overlaps; \
    never edits. Returns job_id: wait with get_job for suspect times, reasons, screenshots and WAV clips. Levels and beats: \
    listen; words: transcribe. Outside files may return needs_confirmation.
    Example: {"image":false}
    """, input: MCPSchema.object([
        "file": MCPSchema.string("Optional matching export, same length/timestamps."),
        "from": MCPSchema.number("Timeline start seconds (default 0).", minimum: 0),
        "to": MCPSchema.number("Timeline end seconds (≥ 0; default: the end).", minimum: 0),
        "silence_db": MCPSchema.number("Silent below dBFS (default -45).", minimum: -80, maximum: -10),
        "min_silence": MCPSchema.number("Minimum silent seconds (default 0.5).", minimum: 0.1, maximum: 10),
        "image": MCPSchema.boolean("Suspect screenshots, default true."),
        "confirm_token": MCPSchema.confirmToken
    ]))
}
