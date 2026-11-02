import Foundation

// MARK: - 工具清单：素材从哪来（音乐库）
//
// 管什么：find_audio、add_voiceover 的说明文字和参数。以后「生成素材」（Sky Studio，方案第六块）也放这一组。
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
            return MCPToolDefinition(
                .addVoiceover, title: "Add a voiceover",
                description: """
                Make voiceover files and put each line on the same audio track (new unless track is given), plus optional \
                subtitles, as one undo step. Sky Studio returns job_id: wait with get_job. After failure use resume=recovery_file; \
                this only processes saved audio or queries original jobs, never repeats a charge. generate_missing=true additionally \
                generates only missing batches. Progress lists completed, pending recovery and not generated parts. Repeated resume \
                cannot duplicate audio/subtitles. Never repeat the original lines after a cloud/local failure. \
                Cloud cloning may queue minutes; local voices finish directly. A key prefers Sky Studio; hard budgets pause. \
                Unavailable ordinary narration falls back to downloaded SkyCut voices then Mac; relay voice.note. Cloud ignores speed. \
                voice accepts roles (zh_female_lively, zh_female_warm, zh_male, en_female_lively, en_female_warm, en_male, \
                en_female_british, en_male_british), presets Rachel/Brian, SkyCut names af_heart/zf_xiaoxiao, or Mac names; \
                default warm female in the text's language. clone_from needs one clear speaker; no fallback, lines combine per \
                paid batch. Multi-line clones require installed local transcription (macOS 26) before charging. \
                subtitles=true adds aligned cues except existing overlaps. download_voices=true only downloads 333 MB; tell the user.
                """,
                input: MCPSchema.object([
                    "lines": MCPSchema.array(of: MCPSchema.object([
                        "text": MCPSchema.string("What to say."),
                        "start": MCPSchema.number("Timeline seconds (default: right after the previous line; the first at the playhead).", minimum: 0)
                    ], required: ["text"]), "The lines of narration, in order (not needed with download_voices).", minItems: 1),
                    "voice": MCPSchema.string("A role or an installed voice's name."),
                    "speed": MCPSchema.number("1 = normal (default). Not used by Sky Studio voices.", minimum: 0.5, maximum: 2),
                    "clone_from": MCPSchema.string("A file of one person speaking; the lines are spoken in that voice (Sky Studio only)."),
                    "clone_start": MCPSchema.number("Seconds into clone_from where the sample starts (default 0).", minimum: 0),
                    "clone_seconds": MCPSchema.number("Length of the sample (default 10).", minimum: 5, maximum: 30),
                    "track": MCPSchema.string(MCPSchema.trackDescription),
                    "subtitles": MCPSchema.boolean("Also add the words as subtitles, timed to the voice (one line each unless max_lines=2)."),
                    "max_lines": MCPSchema.integer("With subtitles=true: 1 (default) or 2 lines per subtitle; stays with the project.",
                                                   minimum: 1, maximum: 2),
                    "download_voices": MCPSchema.boolean("Only download SkyCut's own voices (returns a job); lines are ignored."),
                    "resume": MCPSchema.string("recovery_file from get_job; omit original lines/voice. Reopen the original project first."),
                    "generate_missing": MCPSchema.boolean("With resume: generate only missing batches; default false (existing audio only).")
                ])
            )
        default:
            preconditionFailure("\(name) is not a media tool")
        }
    }
}
