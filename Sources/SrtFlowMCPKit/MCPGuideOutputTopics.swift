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
            Results. It returns job_id: wait with get_job, which gives the file, export_settings and timings. burn_subtitles \
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
            inspect_video looks for problems in finished sound and picture; it never edits.
            """),
            MCPGuideSection(name: "range", about: "the timeline or a matching export, and the range checked", text: """
            What it checks. By default the seams plus the last 3 seconds of the timeline; from and to choose a range in \
            timeline seconds. file points at a matching export (same length and timestamps). It uses the project's subtitle \
            style. Outside files may return needs_confirmation.
            """),
            MCPGuideSection(name: "results", about: "suspect times, reasons, screenshots and WAV clips", text: """
            Results. It returns job_id: get_job gives suspect times and reasons, screenshots (image=false leaves them out) and \
            temporary WAV clips to listen to. silence_db (default -45) and min_silence (default 0.5 s) set what counts as \
            silence. Suspects are sampled: a person should review them.
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
            """),
            MCPGuideSection(name: "waiting", about: "wait_seconds, waiting instead of restarting, the shared queue", text: """
            Waiting. wait_seconds (up to 30) waits for the job before answering; keep calling get_job instead of starting the \
            job again. Exports, transcriptions (subtitles, transcripts) and translations run one at a time across all projects: \
            a later one shows status queued with queue_position (1 = next) and starts by itself.
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
