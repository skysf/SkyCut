import Foundation

// MARK: - 说明书：出片和长任务这一组（第一批，2026-11-10）
//
// 管什么：export_video、inspect_video、compress_videos、burn_subtitles、get_job 名片写短之后的长话。
// 出处：迁移前的说明原文和参数说明（MCPGuidePreviousCards）、docs/architecture/export-settings.md（短边封顶、只降不升、撞名加编号、
// quick_review 不改正式设置）、finished-video-inspection.md（成片检查）、ai-control-mcp.md 第四节（任务排队、waiting_for_user、
// 压缩 / 烧录排进现成的队列）、sky-studio-jobs.md（原单恢复、不重放收费请求、退款只认账单）。只写英文。
// 不管什么：参数一行一行的类型和范围（fields 自动生成）。

enum MCPGuideOutputTopics {
    static let exportVideo = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCards.exportVideo,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCards.exportVideo, """
            export_video renders the project; the saved export settings never change.
            """),
            MCPGuideSection(name: "presets", about: "final versus quick_review, and per-call overrides", text: """
            Presets. preset=final uses the saved export settings. preset=quick_review is a fast review copy: hardware encoder, \
            at most 720p on the short side, small quality, AAC 128 kbps; it never upscales. encoder, resolution and quality \
            override only this call; resolution is a short-side cap that never upscales. The saved settings stay as they were.
            """),
            MCPGuideSection(name: "files", about: "where the file goes, its name, version labels and numbering", text: """
            Where it goes. path sets the full output path; otherwise the file is named name (default: the project's name) and \
            goes to SkyCut/Exports in the opened folder, the project's folder or Downloads. version adds a short label: \
            <name> - <version> (a project made with version already has it). A taken name gets a number; a file is never \
            replaced. Audio-only projects export M4A.
            """),
            MCPGuideSection(name: "results", about: "job_id, what get_job returns, subtitles and music credits", text: """
            Results. It returns job_id: wait with get_job, which gives the file, export_settings and timings, and its sound: \
            audio_loudness_lufs and audio_peak_dbtp (the true peak of the exported file itself). When the -1 dBTP limiter had to \
            work it adds audio_peak_before_limiter_dbtp, audio_limited_seconds and audio_max_reduction_db. burn_subtitles \
            (default true) burns the visible subtitles into the picture. When the timeline uses library music, pass \
            get_timeline's music_credits on to the user. Exports run one at a time with transcriptions and translations.
            """)
        ],
        examples: [
            ["preset": "quick_review"],
            ["name": "Promo", "resolution": "1080p"]
        ],
        related: ["get_job", "inspect_video", "export_subtitles"]
    )

    static let inspectVideo = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCards.inspectVideo,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCards.inspectVideo, """
            inspect_video gives one pre-delivery report. Inspection never edits or blocks export; explicit intentional marks save a review decision.
            """),
            MCPGuideSection(name: "range", about: "the timeline or a matching export, and the range checked", text: """
            What it checks. By default the whole timeline; from and to choose a range in \
            timeline seconds. file points at a matching export (same length and timestamps). It uses the project's subtitle \
            style. Outside files may return needs_confirmation. Pictures are sampled every 0.5 s; with file every frame of the \
            export is also scanned (frame_scan) for stray_frames (a few frames of another picture), flash, frozen_picture (6 s \
            or more without movement; stills and native screen recordings are exempt) and black_frame, over the whole file or the from and to range. Every visible clip is also \
            checked against cuts inside its own source file: a few frames of another shot come back as source_cut with \
            suggested_source_in or suggested_source_out. Longer retained joins are source_cut_crossing suspects.
            """),
            MCPGuideSection(name: "results", about: "suspect times, reasons, screenshots and WAV clips", text: """
            Results. It returns job_id: get_job gives suspect times and reasons, screenshots (image=false leaves them out) and \
            temporary WAV clips to listen to. Under the screenshots the measured mix of the checked range is drawn as look \
            sound draws it: each screenshot is #n on the strip, blue lines mark where sounds start, and the result's sound lists \
            them. silence_db (default -45) and min_silence (default 0.5 s) set what counts as \
            silence. Suspects are sampled: a person should review them. A cut is reported as cutting speech (audio_cutoff) only \
            where a cached transcript or narration subtitles show words there; clips cut where sound plays without either are \
            listed in speech_unchecked: transcribe the ones with speech, then inspect again. When the file was made before the \
            project's last change, attention says so first: export again and inspect the new file.
            """),
            MCPGuideSection(name: "delivery", about: "mix overload, limiter, thin sound, holes and sentence cuts", text: """
            Delivery checks. The report includes audio_overload (timeline true peak before limiting), audio_limiter (where the \
            export limiter worked), audio_true_peak (decoded file peak), audio_thin (below -30 dBFS with at most one audible \
            layer for 0.75 s), audio_hole (a 12 dB drop from the preceding 0.5 s, lasting 0.5 s), and sentence_cut (a source end \
            or picture cut inside a transcript sentence). Silence uses silence_db and min_silence. Sound findings include \
            loudest_layers from the frozen timeline. With file, mix levels describe that file; layer attribution and limiter \
            history describe the frozen timeline and cannot prove the file matches. These thresholds are review heuristics. \
            Missing speech evidence is listed; no recognition or paid work starts. Partial picture coverage remains explicit.
            """),
            // Second tier (2026-11-18, MCP-37 / 38 / 39; finished-video-inspection.md "Second-tier sound checks").
            MCPGuideSection(name: "sound", about: "cut jumps, sounds past their picture, voice clarity, music swells; sounds", text: """
            Sound checks that need to know what each sound is. sound_roles says what SkyCut took each track's sounds to be: \
            voice (its voice-overs), music (library or generated), effects (library or made), camera (a picture's own sound) or \
            other (an imported file). Say what it cannot know with sounds: a track, tracks joined with + or a clip id → voice, \
            music, effects, ambience or object, e.g. {"A1":"voice","A3":"music","c4":"object"}. audio_cut_jump: at a picture \
            cut the sound of the place (camera, ambience, objects, other) jumps 6 dB or more (full band or above 300 Hz, 0.3 s each \
            side) and nothing covers it: no voice, music or effect bed within 6 dB, music accent within 3 frames, music entering or \
            stopping, hit or riser at the cut, or a line in the picture's own sound starting or ending within 0.35 s. Fix it with \
            set_transition sound. audio_linger: an object still sounds over 2 frames above -50 dBFS after the picture it starts \
            in cuts away, or a picture's own detached sound stays 6 dB over the next shot for over 2 frames. audio_voice_masked \
            and audio_two_voices: listen voice's verdicts for every audio track holding only voice, with the main maskers. \
            audio_music_swell: music rises 6 dB or more in the voice band during a line. A clear line whose one added layer may \
            be loud is a grey hint (audio_voice_loud) in hints, not a suspect. A voice sharing its track with other sounds cannot \
            be measured (limitations). The lines come from one human film and a few listener marks: mark expected ones intentional.
            """),
            // MCP-40's remaining second-tier rows (2026-11-19; finished-video-inspection.md "Music rows and abrupt sounds").
            MCPGuideSection(name: "music", about: "music dropping out under a line, late or missing, hard music edges, abrupt sounds", text: """
            Music and sounds that jump out (music is whatever sound_roles says is music). audio_music_drops: music heard in the \
            last 3 s sits more than 22 dB under a speaking voice for 2 s or more, so it all but vanishes; keep it about 10 dB under \
            words (set_track duck_others_db). audio_music_late: music is first heard more than 3 s after the first picture; an \
            opening line starting inside those 3 s lets it wait until 3 s after the line ends. audio_no_score: 15 s or more with \
            neither music nor an effect of 3 s or more (a long tone or a riser), a reminder; a video with no music at all gets only \
            the grey hint audio_no_music in hints. audio_music_edge: music starting or stopping without a fade of 0.3 s, above -40 \
            dBFS, more than 6 frames from a picture cut, the first picture, a title appearing or a line spoken in the picture \
            starting or ending (edge in or out, event_at, frames_from_event); not where another music plays across it, the same \
            file carries on, or the music's own hit is at the edge (an accent within 3 frames: placed there on purpose, as with \
            add_clips hit_at). audio_abrupt: an effect or an object peaking above -30 dBFS and 15 dB over the rest of the mix (the \
            median of 3 s each side), more than 6 frames from a cut or a title. The lines are the production research's, from one \
            human film and two AI drafts: mark deliberate ones intentional (a music edge on a hit in the music itself, a held breath \
            before a big hit).
            """),
            MCPGuideSection(name: "intentional", about: "mark, review or clear any finding with one undo step", text: """
            Every finding has a key. Call inspect_video intentional={job_id:<completed report>,key:<finding key>,reason:<one \
            nonempty line, at most 240 characters>}, without inspection fields. This explicitly saves one review decision in \
            the project, in one undo step. Matching findings leave findings and appear separately in intentional with their \
            reason; they never block export. Repeat an inspection after editing before marking. Marks match kind, clip IDs, \
            source-anchored bounds (two project frames of tolerance), and a content/mix fingerprint; material timing, source, \
            clip or gain changes report the suspect again. clear_intentional=<saved key> removes one mark, also one undo step. \
            Reports expire when SkyCut quits; project marks persist. A stale-export attention note still remains visible.
            """),
            MCPGuideSection(name: "limits", about: "what it does not do: transcription and source levels", text: """
            Limits. It does no transcription. For source levels and beats use listen; for words use transcribe.
            """)
        ],
        examples: [
            ["image": false],
            ["from": 0, "to": 30]
        ],
        related: ["listen", "transcribe", "export_video", "look"]
    )

    static let compressVideos = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCards.compressVideos,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCards.compressVideos, """
            compress_videos makes smaller copies of video files; it does not touch the project.
            """),
            MCPGuideSection(name: "settings", about: "the remembered page settings and per-batch options", text: """
            Settings. Without options it uses the settings the user keeps on SkyCut's Compress Video page. quality (small, \
            balanced, high), resolution (a short-side cap such as 1080p), frame_rate and fast (the Mac's hardware encoder: about \
            ten times faster, but a bigger file at the same quality) apply to this batch only. Resolution and frame rate are only \
            ever lowered.
            """),
            MCPGuideSection(name: "output", about: "file names, the folder and the page's queue", text: """
            Output. One H.264 MP4 per file, named <name>_compressed.mp4, in SkyCut/Exports inside the opened folder, or in \
            folder (absolute, or relative to the opened folder; made if missing). It never overwrites. The videos also show up \
            in the Compress Video page's queue. Files outside the opened folder may return needs_confirmation.
            """),
            MCPGuideSection(name: "results", about: "job_id and the size of each output", text: """
            Results. It returns job_id: wait with get_job, whose result lists each output with its size.
            """)
        ],
        examples: [
            ["files": ["a.mp4"]],
            ["files": ["a.mp4", "b.mov"], "quality": "small", "resolution": "720p"]
        ],
        related: ["burn_subtitles", "get_job", "manage_files"]
    )

    static let burnSubtitles = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCards.burnSubtitles,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCards.burnSubtitles, """
            burn_subtitles burns subtitle files into videos outside the project.
            """),
            MCPGuideSection(name: "items", about: "which videos and subtitle files, and when export_video fits instead", text: """
            Items. Each item pairs a video with its subtitle file (.srt, .vtt, .ass, .ssa or .txt). For the project's own \
            subtitles use export_video, which burns them into the edit.
            """),
            MCPGuideSection(name: "look", about: "the Burn In Subtitles page style and per-batch style", text: """
            Look. Subtitles look the way the user set up SkyCut's Burn In Subtitles page. style changes this batch only (the \
            same fields as edit_subtitles style); the word highlight does not apply because subtitle files have no word times.
            """),
            MCPGuideSection(name: "output", about: "file names, the folder, encoding options and the job", text: """
            Output. One output per video, named <name>_sub.mp4, in SkyCut/Exports inside the opened folder or in folder; it \
            never overwrites. quality, resolution, frame_rate and fast apply to this batch only. Files outside the opened folder \
            may return needs_confirmation. It returns job_id: wait with get_job.
            """)
        ],
        examples: [["items": [["video": "talk.mp4", "subtitles": "talk.srt"]]]],
        related: ["export_video", "compress_videos", "edit_subtitles"]
    )

    static let getJob = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCards.getJob,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCards.getJob, """
            get_job reports on any job id; it never starts or repeats work.

            Read-only. Progress and result of a long job (any call that returned a job id). wait_seconds (up to 30) waits first: keep \
            waiting, never restart the job. Exports, transcriptions and translations run one at a time (queued: queue_position). \
            waiting_for_user: tell the user right away. Paid jobs: billing_note explains the charge.
            """),
            MCPGuideSection(name: "waiting", about: "wait_seconds, waiting instead of restarting, the shared queue", text: """
            Waiting. wait_seconds (up to 30) waits for the job before answering; keep calling get_job instead of starting the \
            job again. Exports, transcriptions (subtitles, transcripts) and translations run one at a time across all projects: \
            a later one shows status queued with queue_position (1 = next) and starts by itself. A look still working after about \
            25 seconds is a job too (kind look): while it waits behind earlier calls on its project it shows status queued, \
            queue_position and waiting_for; when done its answer is under result, with the picture.
            """),
            MCPGuideSection(name: "user", about: "waiting_for_user and what to tell the user", text: """
            The user. If the job shows waiting_for_user (for example a language download only the user can click), tell the user \
            what it says right away, then keep waiting.
            """),
            MCPGuideSection(name: "paid", about: "paid jobs: recovery, billing_note and refunds", text: """
            Paid jobs. Character jobs keep stable ids across App restarts; their source generation, finalization and billing are \
            independent, and recovery never repeats paid generation. After a local failure, cloud generation refreshes the \
            original server job's billing and remote_result; this never submits a replacement or repeats a charge. Explain \
            billing_note to the user; a delivery failure does not imply a refund.
            """)
        ],
        examples: [["job_id": "export-1", "wait_seconds": 30]],
        related: ["cancel_job", "export_video", "generate_media"]
    )
}
