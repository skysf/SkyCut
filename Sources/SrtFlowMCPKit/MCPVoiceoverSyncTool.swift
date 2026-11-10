import Foundation

// MARK: - 显式旁白段落映射的 MCP 合同
// 只管发现参数；准备、对齐和事务复用 App 的旁白 / 批量编辑实现。

enum MCPVoiceoverSyncTool {
    static var definition: MCPToolDefinition {
        let id: JSONValue = ["type": "string"]
        let list: JSONValue = ["type": "array", "items": id]
        let paragraph = MCPSchema.object([
            "from": MCPSchema.number("Old paragraph start, seconds (≥ 0).", minimum: 0),
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
            Retime pictures, titles, shapes and subtitles to new narration already on the timeline (add_clips, or a finished \
            add_voiceover). Returns job_id: wait with get_job; no paid generation; one undo step. Subtitles realign to the new \
            audio.
            Example: \
            {"language":"en","paragraphs":[{"from":0,"to":4,"voiceover_id":"c3","old_voiceover_id":"c2","clips":[{"clip_id":"c1"}],"texts":["t1"]}]}
            Read skycut_guide topic=sync_voiceover first.
            """, input: MCPSchema.object([
                "paragraphs": MCPSchema.array(of: paragraph, "1–100 ordered mappings; old timeline seconds.", minItems: 1),
                "language": MCPSchema.string("Spoken language; local model needed for subtitles."),
                "start": MCPSchema.number("New first paragraph start, seconds (≥ 0); default: the first from.", minimum: 0)
            ], required: ["paragraphs", "language"]), destructive: true)
    }
}
