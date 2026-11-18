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
            media file (absolute, or relative to the opened folder) in source seconds (source_in and source_out narrow it; outside \
            files may return needs_confirmation); with neither it lists every audible clip. from and to limit the timeline \
            seconds. mix=true measures the mix itself instead (the mix section).
            """),
            // 2026-11-17: peaks are true peaks and loudest_at is a frame (docs/architecture/ai-control-mcp.md section 4 item 13).
            MCPGuideSection(name: "levels", about: "level, true peak, silences, the loudest frame and the curve", text: """
            Levels. level_db is the RMS level excluding silence, peak_db the true peak in dBTP (between samples too: the \
            measure the export limiter holds at -1), silences the quiet stretches (quieter than silence_db, default -45, for at \
            least min_silence seconds, default 0.5), loudest_at the start of the loudest frame at the project frame rate, plus \
            peak_at (when the true peak is) and a per-step curve for one clip or file. Around -60 dBFS or lower is silent.
            """),
            MCPGuideSection(name: "beats", about: "tempo, beats and downbeats, the analysis cut_to_beat uses", text: """
            Beats. beats=true with one clip or file returns tempo_bpm, beats and downbeats; cut_to_beat uses the same analysis. \
            Music without a steady beat gives unreliable beats.
            """),
            MCPGuideSection(name: "cuts", about: "checking every V1 cut for pauses and speech", text: """
            Cuts. cuts=true with neither clip nor file checks the head and tail of every V1 clip: whether the cut sits in a \
            pause or on speech, which words (from transcribe) it cuts, and suggested_source_in / suggested_source_out for \
            edit_clip. It uses the same measurements as cut_speech. Apply a suggestion, then check again.
            """),
            // 出处：docs/architecture/export-audio-mixdown.md「五、按层量」、ai-control-mcp.md 第四节第 13 条（mix=true）。
            MCPGuideSection(name: "mix", about: "mix=true: the mixed timeline per track layer and per frame, as exported", text: """
            Mix. mix=true measures the timeline's mix itself instead of clips: SkyCut renders it offline with the engine that \
            makes the exported sound (clip volume, curves, fades, scenes, track and master faders) and measures the whole mix and \
            each layer, frame by frame at the project frame rate. Nothing is estimated from the media files, so a mono voice reads \
            as loud as it plays. from and to limit the timeline seconds (whole timeline by default); clip_id measures that clip's \
            seconds and splits the sound into its own track and rest.
            Layers. layers lists the layers, each a track (A1), tracks joined by + (V1+V2), or rest (every audible track not \
            named). The default is one layer per audible track. V1 is the main track's own sound; hidden or muted tracks are not \
            in the mix. Layers are as they enter the master bus, before the limiter, so they add up to the mix wherever nothing \
            is over.
            Results. The mix: loudness_lufs (integrated, after the limiter: the number export_video reports), max_momentary and \
            max_short_term (the loudest 400 ms and 3 s), peak_db and peak_at (true peak before the limiter), loudest_at (the start \
            of the loudest frame), over (frames above the -1 dBTP limiter ceiling, with the peak and how much the limiter takes off: \
            reported, never blocked), limited_seconds, max_reduction_db and a level curve. Each layer: level_db, loudness_lufs, \
            peak_db, peak_at, loudest_at and bands_db (low below 300 Hz, low_mid 300-800, high_mid 800-3000, high above 3000). \
            To pull a mix down, lower the master with set_track. frames=true adds per-frame values for a few seconds: the more \
            layers, the fewer frames, and a longer range is refused with a to that fits. A long timeline may return job_id: wait \
            with get_job.
            """),
            // Since 2026-11-17 (MCP-39; docs/architecture/listening-engine.md section 2, ai-control-mcp.md section 4 item 13).
            MCPGuideSection(name: "voice", about: "voice=: is each narration line covered, by what, and how much", text: """
            Voice. voice checks narration against the mix: name the voice track (voice=A1; several joined by +) or voice=auto (the \
            audio tracks holding SkyCut's voice-overs). Both accept at most 11 voice tracks, reserving a layer for other sounds. \
            A voice inside a clip's own sound (V1, V2: on-camera speech) can't be \
            measured and is refused. Each voice clip is cut into lines at its pauses; each line gets estoi (0–1: how much of it \
            survives in the whole mix), a verdict, maskers (the two layers covering it most, with kind music, effects, clip_sound, \
            voice or other, and how much removing it or lowering it 6 dB would add) and low_150_db next to voice_db (ESTOI can't \
            hear below ~134 Hz: compare them yourself). Verdicts: probably_unintelligible below 0.31, may_be_hard 0.31–0.41 \
            (listen to it); when music covers it most, only below 0.20; two_voices when another voice track speaks during at least \
            0.5 s of the line; \
            too_short. A separate grey hint says "clear, but [layer] may be loud — try 3–6 dB lower" only for a clear line with \
            estoi < 0.50 whose main masker is one added music, ambience or effects layer (never clip_sound, a voice or rest) and \
            removing it adds at least 0.25; summary.may_be_loud counts these hints. Report only: nothing blocks, and the lines \
            come from one listener, so treat them as where to listen. To fix \
            a line, lower the masker it names (set_track, edit_clip volume_db or a volume curve) and check again. from and to \
            narrow it; a long timeline may return job_id.
            """),
            // Since 2026-11-17 (MCP-42, MCP-44; docs/architecture/listening-engine.md section 2 item 4).
            MCPGuideSection(name: "describe", about: "describe=true: what is in a clip's own sound, in words", text: """
            Describe. describe=true with clip_id (or file) says what a clip's own sound is, per 3 s window: traits from \
            SkyCut's measures (low_drone, broadband_noise, pitched, rhythmic, speech_like) with the numbers behind them, labels \
            (macOS's sound classifier: the strongest few, each with its own score, not one verdict) and words (how many the \
            on-device speech recogniser found; the summary quotes what it heard). Words, not a verdict: the classifier calls a \
            low drone music, and neither says music or not. Our own voice-overs, library music and effects are not described: \
            where they came from already says what they are. At most 60 s at a time (narrow with from/to or source_in/source_out); \
            it may return job_id. Words are only checked with a speech model already on this Mac (macOS 26).
            """)
        ],
        examples: [
            ["clip_id": "c1"],
            ["cuts": true],
            ["clip_id": "m1", "beats": true],
            ["mix": true, "from": 70, "to": 76],
            ["mix": true, "layers": ["A1", "rest"], "frames": true, "from": 29, "to": 31],
            ["voice": "A1"],
            ["clip_id": "v3", "describe": true]
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
