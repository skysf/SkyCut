import Foundation

// MARK: - 显式旁白段落映射的 MCP 合同
// 只管发现参数；准备、对齐和事务复用 App 的旁白 / 批量编辑实现。

enum MCPVoiceoverSyncTool {
    static var definition: MCPToolDefinition {
        let id: JSONValue = ["type": "string"]
        let list: JSONValue = ["type": "array", "items": id]
        let paragraph = MCPSchema.object([
            "from": MCPSchema.number("Old paragraph start.", minimum: 0),
            "to": MCPSchema.number("Old paragraph end > from."),
            "voiceover_id": MCPSchema.string("New audio id; audible, speed 1."),
            "old_voiceover_id": MCPSchema.string("Old audio id to remove."),
            "clips": MCPSchema.array(of: MCPSchema.object([
                "clip_id": id,
                "fit": MCPSchema.string("speed default (0.1–8); trim uses handles; freeze trims or holds tail (max 60s).",
                                        oneOf: ["speed", "trim", "freeze"])
            ], required: ["clip_id"]), "Video/image clips."),
            "texts": list, "shapes": list, "subtitles": list
        ], required: ["from", "to", "voiceover_id"])
        return MCPToolDefinition(.syncVoiceover, title: "Sync timeline to narration", description: """
            Retime pictures/titles/shapes/cues to replacement narration; no paid generation, one undo. Returns \
            job_id: wait with get_job. Import via add_clips or finish add_voiceover first. Subtitles realign to new \
            audio, preserving exact script/Chinese variants (same language); never scale old times. Pictures keep \
            style/framing/layers. Consecutive old from/to ranges follow voiceover_id lengths; include associated \
            get_timeline ids (example ids are placeholders).
            Example: {"language":"en","paragraphs":[{"from":0,"to":4,"voiceover_id":"c3","old_voiceover_id":"c2","clips":[{"clip_id":"c1"}],"texts":["t1"]}]}
            Unmapped items stay. Cross-boundary/duplicate ids, fit/alignment errors or final collisions reject all. \
            Reuse audio on failure; never regenerate.
            """, input: MCPSchema.object([
                "paragraphs": MCPSchema.array(of: paragraph, "1–100 ordered mappings; old timeline seconds.", minItems: 1),
                "language": MCPSchema.string("Spoken language; local model needed for subtitles."),
                "start": MCPSchema.number("New first paragraph start; default first from.", minimum: 0)
            ], required: ["paragraphs", "language"]), destructive: true)
    }
}
