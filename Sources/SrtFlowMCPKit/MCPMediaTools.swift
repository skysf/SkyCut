import Foundation

// MARK: - 工具清单：素材从哪来（音乐库）
//
// 管什么：find_audio、add_voiceover 的说明文字和参数（add_voiceover 是名片，用法在说明书的同名主题：MCPGuideVoiceTopics）。
// 不管什么：怎么搜、怎么下载（App 里的 AIAudioLibraryTools.swift）；把一首放上时间线是 add_clips 的 library_id；
// 配音怎么做（App 里的 AIVoiceoverTool / AISpeechSynthesis）。

enum MCPMediaTools {
    static func definition(for name: MCPToolName) -> MCPToolDefinition {
        switch name {
        case .findAudio:
            return MCPToolDefinition(
                .findAudio, title: "Find audio",
                description: """
                Search SkyCut's music (CC-BY/CC0) and owned sound effects (no credit). English/Chinese query matches \
                title/artist/tags; all words must match; empty lists all. kind filters the library. Results: length, tags, \
                intensity 1–5, licence; music adds vocals/loudness/credit line; SFX hit marks the loudest second. Import with \
                add_clips library_id; hit_at aligns SFX to a cut. Report CC-BY credit lines from get_timeline music_credits \
                when done. Nothing fits? add_clips sound_effect synthesizes one; never download music/SFX.
                """,
                input: MCPSchema.object([
                    "query": MCPSchema.string("Words to search for, e.g. \"calm piano\", \"whoosh\" or \"epic\" (Chinese words work too)."),
                    "kind": MCPSchema.string("any (default), music or sound_effect.", oneOf: MCPVocabulary.audioKinds),
                    "max_results": MCPSchema.integer("How many tracks to return (default 10).", minimum: 1, maximum: 50)
                ]),
                readOnly: true
            )
        case .addVoiceover:
            // 名片（≤ 450）照说明书试点的写法（docs/architecture/mcp-guide.md 第 14 条）：第一句做什么、录好的声音指到 add_clips；
            // 只留不知道就会调错、花错钱的：撤销、默认声音、花积分、任务号、确认、每日上限、失败了别重发。
            // 怎么挑声音、模型、字幕、恢复、坑都在说明书的 add_voiceover 主题（MCPGuideVoiceTopics）。SkyCut 声音方案 4.10。
            return MCPToolDefinition(
                .addVoiceover, title: "Add a voiceover",
                description: """
                Narrate lines, optional subtitles (recordings: add_clips). One undo step. Voices: gemini:Name (default \
                gemini:Charon), voice_… (list_voices), eleven:Name, a role or local voice. Cloud: Paid (Sky Studio credits). \
                Returns job_id; wait with get_job; relay voice.note. May return needs_confirmation. The daily credit limit \
                always applies. On failure: resume=recovery_file, never resend lines. Read skycut_guide topic=add_voiceover \
                before the first call.
                """,
                input: MCPSchema.object([
                    "lines": MCPSchema.array(of: MCPSchema.object([
                        "text": MCPSchema.string("What to say, up to 1000 characters."),
                        "start": MCPSchema.number("Timeline seconds, 0 or more; default 0.3 s after the previous line (the first: playhead).",
                                                  minimum: 0)
                    ], required: ["text"]), "The narration in order, 1 to 50 lines (not with resume or download_voices).",
                        minItems: 1, maxItems: 50),
                    "voice": MCPSchema.string("gemini:Name (default gemini:Charon), voice_… (list_voices), eleven:Name, a role, or a local voice."),
                    "model": MCPSchema.string("Cloud model: auto (default) or a voice model id from get_status models=true."),
                    "speed": MCPSchema.number("0.5 to 2, 1 = normal (default). Local voices only.", minimum: 0.5, maximum: 2),
                    "track": MCPSchema.string(MCPSchema.trackDescription),
                    "subtitles": MCPSchema.boolean("Also add the script's words as subtitles, timed to the voice (see subtitle_timing)."),
                    "max_lines": MCPSchema.integer("With subtitles=true: 1 (default) or 2 lines per subtitle; stays with the project.",
                                                   minimum: 1, maximum: 2),
                    "download_voices": MCPSchema.boolean("Only download SkyCut's own voices (about 333 MB, returns job_id); no lines."),
                    "resume": MCPSchema.string("recovery_file from get_job; send no lines or voice. Reopen the original project first."),
                    "generate_missing": MCPSchema.boolean("With resume: also pay for batches never generated (default false)."),
                    "skip_one_time": MCPSchema.boolean("No to a one-time fee: voice_… reads with the no-fee model; with resume, retries with the same model."),
                    "confirm_token": MCPSchema.confirmToken
                ])
            )
        default:
            preconditionFailure("\(name) is not a media tool")
        }
    }
}
