import Foundation

// MARK: - 声音库的两个工具：list_voices（只读）、manage_voices（写）
//
// 管什么：两个工具的名片（≤ 450）和参数（每条说明 ≤ 120、范围写数字）。读和写分开，照角色 list_characters / manage_characters 的先例
// （AI 接口第一节第 5 条：只读的和写的不放进同一个工具）。用法、授权、一次性费用、坑都在说明书的同名主题（MCPGuideVoiceLibraryTopics）。
// 方案：docs/plans/2026-11-09-voice-features.md 4.6、4.10（名片样稿；change_voice 是声音 PR 9，这里不提）。
// 不管什么：怎么做（App 的 SkyStudioVoiceLibraryTool）、配旁白用哪个声音（add_voiceover，MCPMediaTools）。

enum MCPVoiceLibraryTools {
    static func definition(for name: MCPToolName) -> MCPToolDefinition {
        switch name {
        case .listVoices: return list
        case .manageVoices: return manage
        default: preconditionFailure("\(name) is not a voice library tool")
        }
    }

    private static var list: MCPToolDefinition {
        MCPToolDefinition(
            .listVoices, title: "List voices",
            description: """
            Read-only, free. Voices for add_voiceover: mine (the user's recorded and designed voices, voice_… ids, with their \
            languages) and Sky Studio presets for one language (gemini:Name, gender, description; the default is marked). Pass \
            language: a preset can sound different per language; omitted lists zh and en. If the voice library is unavailable, \
            presets still come back. Details: skycut_guide topic=list_voices.
            """,
            input: MCPSchema.object([
                "language": MCPSchema.string("ISO 639-1 code (zh, en, ja…) whose presets to list; omitted: zh and en."),
                "include": MCPSchema.string("mine, presets or all (default).", oneOf: MCPVocabulary.voiceListIncludes)
            ]),
            readOnly: true, openWorld: true
        )
    }

    private static var manage: MCPToolDefinition {
        MCPToolDefinition(
            .manageVoices, title: "Manage voices",
            description: """
            Edit the user's voice library (no timeline change, no undo): create from a recording, add_reference (another \
            language), design from a description, rename, delete. design: Paid (Sky Studio credits), one-time; Returns job_id; \
            wait with get_job. The daily credit limit always applies. Ask mode: create, add_reference, design and delete return \
            needs_confirmation first; full access proceeds. Read skycut_guide topic=manage_voices before the first call.
            """,
            input: MCPSchema.object([
                "action": MCPSchema.string("What to do.", oneOf: MCPVocabulary.voiceLibraryActions),
                "voice": MCPSchema.string("voice_… id from list_voices: add_reference, rename, delete."),
                "file": MCPSchema.string("create / add_reference: a recording (audio or video) of one speaker."),
                "start": MCPSchema.number("Seconds into file where the sample may start, 0 or more (default 0).", minimum: 0),
                "end": MCPSchema.number("Seconds into file where it stops, 0 or more (default: end; 3 minutes are used at most).",
                                        minimum: 0),
                "language": MCPSchema.string("ISO 639-1 code of what the recording says (zh, en…): create, add_reference."),
                "name": MCPSchema.string("Voice name, 1 to 80 characters: create, design, rename."),
                "description": MCPSchema.string("design: how the voice sounds, up to 2000 characters."),
                "sample_text": MCPSchema.string("design: optional sentence the sample reads, up to 500 characters."),
                "confirm_token": MCPSchema.confirmToken
            ], required: ["action"]),
            destructive: true, openWorld: true
        )
    }
}
