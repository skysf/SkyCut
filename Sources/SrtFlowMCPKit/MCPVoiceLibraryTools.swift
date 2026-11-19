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
            Read-only, free. Voices for add_voiceover: mine (the user's voices, voice_… ids) and Sky Studio presets for one \
            language (gemini:Name). Pass language: a preset can sound different per language; omitted lists zh and en. If the \
            voice library is unavailable, presets still come back. Details: skycut_guide topic=list_voices.
            """,
            input: MCPSchema.object([
                "language": MCPSchema.string("Presets' ISO 639-1 code; omitted: zh and en."),
                "include": MCPSchema.string("Default all.", oneOf: MCPVocabulary.voiceListIncludes)
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
                "voice": MCPSchema.string("voice_… id from list_voices."),
                "file": MCPSchema.string("Recording of one speaker."),
                "start": MCPSchema.number("Sample start in file, seconds; default 0.", minimum: 0),
                "end": MCPSchema.number("Sample end in file, seconds (0 or more); default: its end.", minimum: 0),
                "language": MCPSchema.string("optional ISO 639-1 code of what is said; omitted, SkyCut detects it or asks for it."),
                "name": MCPSchema.string("Voice name, 1 to 80 characters."),
                "description": MCPSchema.string("design: how it sounds, up to 2000 characters."),
                "sample_text": MCPSchema.string("design: the sample's sentence, up to 500 characters."),
                "confirm_token": MCPSchema.confirmToken
            ], required: ["action"]),
            destructive: true, openWorld: true
        )
    }
}
