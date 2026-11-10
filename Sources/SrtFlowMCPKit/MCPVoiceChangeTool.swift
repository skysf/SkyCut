import Foundation

// MARK: - 变声的工具：change_voice
//
// 管什么：名片（≤ 450）和参数（每条说明 ≤ 120）。变声改时间线、是长任务、花积分，和 upscale_clip 同一类，单独一个工具：它不能并进
// add_voiceover（输入是一段现成的声音，不是文字），也不能并进 generate_media（那个不改工程）。用法、落地、语言、坑都在说明书的同名主题
// （MCPGuideVoiceChangeTopic）。只判每日硬预算、不是一次性费用，所以不回 needs_confirmation、不收 confirm_token。
// 方案：docs/plans/2026-11-09-voice-features.md 4.8、4.10（名片样稿）。片段的参数名照全清单的习惯写 `clip_id`（方案写的是 `clip`）。
// 不管什么：怎么做（App 的 VoiceChangeTool）、有哪些声音（list_voices，MCPVoiceLibraryTools）。

enum MCPVoiceChangeTool {
    static var definition: MCPToolDefinition {
        MCPToolDefinition(
            .changeVoice, title: "Change voice",
            description: """
            Paid (Sky Studio credits): re-voice one clip with a library or preset voice (dub it in my voice). Returns job_id; \
            wait with get_job. Result: the new voice and the separated background on two new linked audio tracks; the original \
            clip is muted. One undo step. The daily credit limit always applies. Read skycut_guide topic=change_voice before the \
            first call.
            """,
            input: MCPSchema.object([
                "clip_id": MCPSchema.string("The clip whose voice to change: video or audio, with sound, not muted (get_timeline)."),
                "voice": MCPSchema.string("Target voice: a voice_… id from list_voices mine (best), or a preset such as gemini:Charon."),
                "language": MCPSchema.string("ISO 639-1 code of what the clip says (zh, en…); omitted: detected on this Mac if possible.")
            ], required: ["clip_id", "voice"]),
            openWorld: true
        )
    }
}
