import Foundation

// MARK: - 说明书：听和按说话 / 鼓点剪这一组（第一批，2026-11-10）
//
// 管什么：transcribe、listen、cut_speech、cut_to_beat、sync_voiceover 名片写短之后的长话。
// 出处：迁移前的说明原文和参数说明（MCPGuidePreviousCards）、docs/architecture/ai-control-mcp.md 第四节（listen 读波形那一份、
// cuts=true 和 cut_speech 同一份输入、鼓点按整首歌分析）、docs/bugfixes/2026-10-14-cut-speech-trusts-word-times.md（切口先看量出来的停顿）、
// 2026-10-15-linkage-moves-subtitles-as-a-block.md（字幕两头各自换算）、docs/architecture/voiceover-timeline-sync.md（显式段落映射）。只写英文。
// 不管什么：参数一行一行的类型和范围（fields 自动生成）。

enum MCPGuideSpeechTopics {
    static let transcribe = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCards.transcribe,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCards.transcribe, """
            transcribe reads what is said and when; it never changes the project.
            """),
            MCPGuideSection(name: "sources", about: "timeline clips or a file, and which times come back", text: """
            What it reads. By default every video-track clip with sound; audio-only clips such as music only when named in \
            clip_ids. Times are timeline seconds. With file it reads a media file instead (absolute, or relative to the opened \
            folder; outside files may return needs_confirmation) and times are seconds in that file; source_in and source_out \
            narrow it. language is auto by default or a tag such as en, zh-Hans or ja.
            """),
            MCPGuideSection(name: "results", about: "sentences, words, and long transcripts in pieces", text: """
            Results. Sentences come with start, end and text; words=true also lists every word with its start and end \
            (estimates: 0.1–0.3 s off around pauses). Long transcripts come in pieces of about max_chars characters (default \
            12000): call again with from = next_from; from and to limit the time range.
            """),
            MCPGuideSection(name: "first_time", about: "the first transcription as a job, the cache and the queue", text: """
            First time. Media never transcribed is transcribed on this Mac first: the result is then job_id. Wait with get_job, \
            then call transcribe again with the same arguments; the cache answers instantly, and subtitles generated in SkyCut \
            earlier count too. Transcriptions run one at a time with exports and translations.
            """),
            MCPGuideSection(name: "using_it", about: "picking quotes and cutting mistakes, fillers and repeats", text: """
            Using it. Pick what to keep for a promo, or find mistakes, filler words and repeats, then cut with cut_speech \
            (remove_fillers and remove_repeats need transcribe first).
            """)
        ],
        examples: [
            ["words": true],
            ["file": "interview.mp4", "source_in": 0, "source_out": 60]
        ],
        related: ["cut_speech", "listen", "generate_subtitles"]
    )

    static let listen = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCards.listen,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCards.listen, """
            listen measures sound and never changes the project.
            """),
            MCPGuideSection(name: "what", about: "one clip, a file, or every audible clip, and time ranges", text: """
            What it measures. clip_id measures one timeline clip including its volume, fades and track faders; file measures a \
            media file in source seconds (source_in and source_out narrow it; outside files may return needs_confirmation); with \
            neither it lists every audible clip. from and to limit the timeline seconds.
            """),
            MCPGuideSection(name: "levels", about: "level, peak, silences, the loudest moment and the curve", text: """
            Levels. level_db is the RMS level excluding silence, peak_db the peak, silences the quiet stretches (quieter than \
            silence_db, default -45, for at least min_silence seconds, default 0.5), loudest_at the loudest moment, plus a \
            per-step curve for one clip or file. Around -60 dBFS or lower is silent.
            """),
            MCPGuideSection(name: "beats", about: "tempo, beats and downbeats, the analysis cut_to_beat uses", text: """
            Beats. beats=true with one clip or file returns tempo_bpm, beats and downbeats; cut_to_beat uses the same analysis. \
            Music without a steady beat gives unreliable beats.
            """),
            MCPGuideSection(name: "cuts", about: "checking every V1 cut for pauses and speech", text: """
            Cuts. cuts=true with neither clip nor file checks the head and tail of every V1 clip: whether the cut sits in a \
            pause or on speech, which words (from transcribe) it cuts, and suggested_source_in / suggested_source_out for \
            edit_clip. It uses the same measurements as cut_speech. Apply a suggestion, then check again.
            """)
        ],
        examples: [
            ["clip_id": "c1"],
            ["cuts": true],
            ["clip_id": "m1", "beats": true]
        ],
        related: ["transcribe", "cut_speech", "cut_to_beat", "inspect_video"]
    )

    static let cutSpeech = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCards.cutSpeech,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCards.cutSpeech, """
            cut_speech edits one talking clip on V1 in a single step.
            """),
            MCPGuideSection(name: "ranges", about: "remove and keep ranges, and where the cuts land", text: """
            Ranges. remove cuts out ranges and keep keeps only these ranges of the clip; both are timeline seconds, usually \
            sentence or word times from transcribe. A time that falls in a pause (listen's silences) is cut exactly there; one \
            on speech moves into the nearest measured pause (transcript word times can be 0.1–0.3 s off), and moved lists every \
            time that moved. snap=false cuts exactly at the given times, only rounded to frames.
            """),
            MCPGuideSection(name: "cleanup", about: "shortening pauses, filler words and repeats", text: """
            Clean-up. remove_pauses shortens pauses longer than that many seconds (for example 0.6), leaving pause_left seconds \
            (default 0.25); silence_db sets what counts as a pause (default: measured from the clip). remove_fillers cuts filler \
            words (um, uh and Chinese ones) and remove_repeats words said twice in a row; both need transcribe first. language \
            picks which transcript to use (default auto).
            """),
            MCPGuideSection(name: "what_moves", about: "the clip's pieces, later clips, linked sound and other tracks", text: """
            What moves. The clip becomes pieces placed back to back and later V1 clips move left; its linked sound is cut with \
            it even with Linkage off. With Linkage on, subtitles, texts and sounds on the clip follow its pieces: those only on a \
            cut part are deleted, a subtitle shrinks to the speech left under it and goes when less than half is left, and music \
            across clips stays. With Linkage off, other tracks stay where they are: regenerate subtitles afterwards.
            """),
            MCPGuideSection(name: "results", about: "what comes back, and the undo step", text: """
            Results. One undo step. It returns what was removed (times before the cut), the new pieces and moved.
            """)
        ],
        examples: [
            ["clip_id": "c1", "remove_pauses": 0.6, "remove_fillers": true],
            ["clip_id": "c1", "remove": [["start": 4.2, "end": 6.8]]]
        ],
        related: ["transcribe", "listen", "generate_subtitles"]
    )

    static let cutToBeat = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCards.cutToBeat,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCards.cutToBeat, """
            cut_to_beat retimes V1 clips to the beats of a music clip.
            """),
            MCPGuideSection(name: "how", about: "which clips change and where their out points land", text: """
            How it cuts. clip_ids are V1 clips next to each other (default: the V1 clips playing while the music does). The first \
            clip keeps its start; each clip keeps its in point and gets a new out point on a beat: the nearest to where it ends \
            now, or exactly beats_per_clip beats (fewer when the media is too short). on=downbeats cuts only on the first beat of \
            each bar. Clips stay at least 0.4 s long; one that cannot reach a beat keeps its length.
            """),
            MCPGuideSection(name: "what_moves", about: "later clips, linked sound and the music", text: """
            What moves. Later V1 clips move with the change and linked sound follows; the music clip does not move. One undo \
            step.
            """),
            MCPGuideSection(name: "check_first", about: "checking the beat first with listen", text: """
            Check first. It needs music with a steady beat: listen beats=true on the music clip shows tempo_bpm, beats and \
            downbeats from the same analysis.
            """)
        ],
        examples: [
            ["music_clip_id": "m1"],
            ["music_clip_id": "m1", "beats_per_clip": 2, "on": "downbeats"]
        ],
        related: ["listen", "add_clips", "find_audio"]
    )

    static let syncVoiceover = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCards.syncVoiceover,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCards.syncVoiceover, """
            sync_voiceover moves the timeline to narration you already placed; it never generates audio.
            """),
            MCPGuideSection(name: "mapping", about: "paragraphs: old ranges, new audio and the items each one moves", text: """
            Mapping. paragraphs is 1–100 ordered mappings in old timeline seconds: from and to are an old paragraph's start and \
            end; voiceover_id is the new audio clip for it (audible, speed 1); old_voiceover_id is the old audio to remove. \
            clips, texts, shapes and subtitles list the get_timeline ids that belong to that paragraph (ids in examples are \
            placeholders). Consecutive old ranges follow the voiceover_id lengths; start sets where the first paragraph begins \
            (default: the first from).
            """),
            MCPGuideSection(name: "fit", about: "how pictures fit the new length: speed, trim or freeze", text: """
            Fitting pictures. Each clip's fit is speed (default, 0.1–8x), trim (uses the clip's handles) or freeze (trims, or \
            holds the last frame for at most 60 s). Pictures keep their style, framing and layers.
            """),
            MCPGuideSection(name: "subtitles", about: "how subtitles realign to the new audio", text: """
            Subtitles. Subtitles realign to the new audio, keeping the exact script and Chinese variants in the same language; \
            old times are never scaled. language is the spoken language; a local speech model is needed for subtitles.
            """),
            MCPGuideSection(name: "failures", about: "what is rejected, what stays, and never regenerating", text: """
            Failures. Items not in a mapping stay where they are. Ids that cross paragraph boundaries or repeat, fit or \
            alignment errors, or collisions at the end reject the whole call, and nothing changes. On failure reuse the same \
            audio and fix the mapping; never regenerate narration. Place the narration with add_clips, or finish add_voiceover, \
            first.
            """)
        ],
        examples: [
            ["language": "en", "paragraphs": [["from": 0, "to": 4, "voiceover_id": "c3", "old_voiceover_id": "c2",
                                               "clips": [["clip_id": "c1"]], "texts": ["t1"]]]]
        ],
        related: ["add_clips", "add_voiceover", "get_timeline", "get_job"]
    )
}
