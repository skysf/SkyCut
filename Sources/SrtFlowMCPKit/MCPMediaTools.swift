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
                Search SkyCut's libraries: music (CC-BY or CC0) and sound effects the user owns (no credit: whooshes, impacts, \
                risers, wind, ice, water, creaks, mechanical…). query matches titles, artists and tags in English or Chinese; \
                all words must match; empty lists everything; kind picks one library. Each result has length, tags, intensity \
                1–5 and licence; music also vocals, loudness and credit line; a sound effect has hit (the second of its loudest \
                moment). Put one on the timeline with add_clips {library_id}, a sound effect with hit_at so its hit lands on a \
                cut. CC-BY music must be credited: give the user the credit lines when the video is done (get_timeline: \
                music_credits). Nothing fits? add_clips sound_effect makes one; never download music or sound effects from the \
                internet.
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
                subtitles, as one undo step. Sky Studio voices return job_id immediately: wait with get_job to a terminal state; \
                never repeat add_voiceover while it runs. Cloning may queue for several minutes. Local voices return directly. \
                Best first: Sky Studio (saved key, daily credits allow it; otherwise ordinary narration falls back with a voice.note), \
                then downloaded SkyCut voices, then this Mac's voices. Cloud voices ignore speed. voice is a role \
                (zh_female_lively, zh_female_warm, zh_male, en_female_lively, en_female_warm, en_male, en_female_british, \
                en_male_british), a cloud preset such as Rachel or Brian, a SkyCut voice (af_heart, zf_xiaoxiao…), or a Mac voice. \
                Default is a warm female voice in the text's language. clone_from sends a clear single-speaker sample to Sky Studio; \
                cloning requires its key and budget, has no local fallback, and combines several lines per paid request. \
                Multi-line cloning needs an installed speech transcription model (macOS 26); otherwise nothing is charged. \
                Files go into SkyCut/Voiceovers. subtitles=true times subtitles to the voice (existing overlaps are left out). \
                Pass voice.note to the user. download_voices=true only downloads SkyCut's voices (a job, about 333 MB; tell the user).
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
                    "download_voices": MCPSchema.boolean("Only download SkyCut's own voices (returns a job); lines are ignored.")
                ])
            )
        default:
            preconditionFailure("\(name) is not a media tool")
        }
    }
}
