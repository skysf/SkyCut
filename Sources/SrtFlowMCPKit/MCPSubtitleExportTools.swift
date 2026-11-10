import Foundation

// MARK: - 工具说明：字幕、导出、长任务
//
// 管什么：这几样工具给 AI 看的说明文字和参数表。清单的总入口在 MCPToolCatalog.swift。
// 生成字幕、翻译、导出都要跑好一阵，一律先回任务号，AI 用 get_job 等结果 ——
// 客户端对一次工具调用大多只等一分钟左右。

public enum MCPSubtitleExportTools {
    static func definition(for name: MCPToolName) -> MCPToolDefinition {
        switch name {
        case .generateSubtitles:
            return MCPToolDefinition(
                .generateSubtitles, title: "Generate subtitles",
                description: """
                Transcribe the timeline's speech into the subtitle track on this Mac (macOS 26), replacing current subtitles; hidden \
                clips are skipped; can translate right after. Each subtitle is one line; pass max_lines=2 only when the user wants \
                two-line subtitles. Set the style first (edit_subtitles style). Returns job_id: wait with get_job. One undo step.
                """,
                input: MCPSchema.object([
                    "language": MCPSchema.string("Spoken language: auto (default) or a locale such as en-US, zh-CN, ja-JP."),
                    "translate_to": MCPSchema.string("Also translate into this language, e.g. zh-Hans, en, ja."),
                    "clip_ids": MCPSchema.array(of: MCPSchema.string("Clip id."), "Only transcribe these clips (for example just the voice-over)."),
                    "max_lines": MCPSchema.integer(
                        "Lines one subtitle may take: 1 (default) or 2. Stays with the project; add_voiceover subtitles follow it.",
                        minimum: 1, maximum: 2
                    )
                ])
            )
        case .translateSubtitles:
            return MCPToolDefinition(
                .translateSubtitles, title: "Translate subtitles",
                description: """
                Translate the original subtitle track into a second track on this Mac; the source language is read from the text. \
                scope=all rebuilds every line, missing fills only lines without one. Returns job_id: wait with get_job. If macOS must \
                download languages, waiting_for_user asks the user to click; tell them. One undo step.
                """,
                input: MCPSchema.object([
                    "target_language": MCPSchema.string("Language tag, e.g. zh-Hans, en, ja, ko, es."),
                    "source_language": MCPSchema.string("Language the original lines are written in. Default: detected from their text."),
                    "scope": MCPSchema.string("all (default) or missing.", oneOf: ["all", "missing"])
                ], required: ["target_language"])
            )
        case .getSubtitles:
            return MCPToolDefinition(
                .getSubtitles, title: "Read subtitles",
                description: """
                Read-only. Subtitle lines with ids, start, end and text from the original track, the translation or both, optionally \
                in a time range. Each line has its box on the canvas (to avoid watermarks or pick style.max_width), plus the style, \
                max_lines and how many lines know their word times.
                """,
                input: MCPSchema.object([
                    "track": MCPSchema.string("Which track (default both).", oneOf: ["original", "translation", "both"]),
                    "start": MCPSchema.number("Only lines that end after this time, seconds (≥ 0).", minimum: 0),
                    "end": MCPSchema.number("Only lines that start before this time, seconds (≥ 0).", minimum: 0),
                    "limit": MCPSchema.integer("At most this many lines per track (default 300).", minimum: 1, maximum: 2000)
                ]),
                readOnly: true
            )
        case .editSubtitles:
            return editSubtitles
        case .exportVideo:
            return exportVideo
        case .exportSubtitles:
            return MCPToolDefinition(
                .exportSubtitles, title: "Export subtitle files",
                description: """
                Write the project's subtitles to .srt or .vtt files, one per track (original, translation or both), named \
                <name>.<language>.srt next to where export_video puts videos; pass the exported video's name to pair them. Hidden \
                lines are left out. Never replaces a file. Done at once.
                """,
                input: MCPSchema.object([
                    "track": MCPSchema.string("Which track (default both: every track with lines).", oneOf: ["original", "translation", "both"]),
                    "format": MCPSchema.string("srt (default) or vtt (WebVTT).", oneOf: MCPVocabulary.subtitleFileFormats),
                    "name": MCPSchema.string("File name without language or extension, e.g. the exported video's name."),
                    "folder": MCPSchema.string("Folder to write into (absolute, or relative to the opened folder). Default: where export_video puts videos.")
                ])
            )
        case .getJob:
            return MCPToolDefinition(
                .getJob, title: "Job progress",
                description: """
                Read-only. Progress and result of a long job (any call that returned a job id). wait_seconds (up to 30) waits before \
                answering: keep waiting instead of starting the job again. Exports, transcriptions and translations run one at a time: \
                queued shows queue_position. If it shows waiting_for_user, tell the user right away. Paid jobs: billing_note explains \
                the charge.
                """,
                input: MCPSchema.object([
                    "job_id": MCPSchema.string("Job id."),
                    "wait_seconds": MCPSchema.number("Wait up to this long for the job to finish, 0–30 seconds.", minimum: 0, maximum: 30)
                ], required: ["job_id"]),
                readOnly: true
            )
        case .cancelJob:
            return MCPToolDefinition(
                .cancelJob, title: "Cancel a job",
                description: "Stop a running export, subtitle generation or translation.",
                input: MCPSchema.object(["job_id": MCPSchema.string("Job id.")], required: ["job_id"])
            )
        default:
            preconditionFailure("\(name.rawValue) is described in another group")
        }
    }

    /// 字幕长什么样：edit_subtitles（这个工程的）和 burn_subtitles（那一批的）共用这一份。
    static let subtitleStyle = MCPSchema.object([
        "position": MCPSchema.string("Where the subtitles sit.", oneOf: MCPVocabulary.subtitlePositions),
        "margin": MCPSchema.number("Edge distance / frame height, 0–0.45 (default 0.056).", minimum: 0, maximum: 0.45),
        "size": MCPSchema.number("Pixels on a 1080-tall frame, 20–140 (default 56); a 9:16 frame is 1920 tall.", minimum: 20, maximum: 140),
        "max_width": MCPSchema.number("Line width / frame width; wraps. Default 0.92 (16:9), 0.74 (9:16). Project only.", minimum: 0.3, maximum: 1),
        "line_spacing": MCPSchema.number("Line-height multiple, 1–2 (default 1); full-height glyphs (Yuanti) suit 1.15–1.3.", minimum: 1, maximum: 2),
        "font": MCPSchema.string("Installed burnable font: e.g. Hiragino Sans GB, Heiti SC, Helvetica Neue."),
        "bold": MCPSchema.boolean("Bold."),
        "color": MCPSchema.string("Text colour, #RRGGBB."),
        "outline": MCPSchema.string("Outline colour #RRGGBB, or none."),
        "outline_width": MCPSchema.number("Outline thickness, or box padding, 0–12.", minimum: 0, maximum: 12),
        "box": MCPSchema.string("Background bar replaces outline: #RRGGBBAA, or none."),
        "shadow": MCPSchema.string("Shadow with outline only: #RRGGBBAA, or none."),
        "highlight": MCPSchema.string("Spoken-word colour: #RRGGBB, or none. Project only."),
        "highlight_scale": MCPSchema.number("How much the spoken word grows (1-1.3, default 1.1; 1 for long lines).", minimum: 1, maximum: 1.3),
        "reset": MCPSchema.boolean("Go back to the style from SkyCut's Burn In Subtitles page first.")
    ])

    private static var editSubtitles: MCPToolDefinition {
        let change = MCPSchema.object([
            "id": MCPSchema.string("Line id from get_subtitles."),
            "text": MCPSchema.string("New text."),
            "start": MCPSchema.number("New start, timeline seconds (≥ 0).", minimum: 0),
            "end": MCPSchema.number("New end, timeline seconds (≥ 0).", minimum: 0)
        ], required: ["id"])
        let addition = MCPSchema.object([
            "track": MCPSchema.string("original (default) or translation.", oneOf: ["original", "translation"]),
            "start": MCPSchema.number("Timeline seconds (≥ 0).", minimum: 0),
            "end": MCPSchema.number("Timeline seconds (≥ 0).", minimum: 0),
            "text": MCPSchema.string("Text of the new line.")
        ], required: ["start", "end", "text"])
        let replacement = MCPSchema.object([
            "find": MCPSchema.string("Text to find (case-sensitive); with regex=true an ICU regular expression."),
            "with": MCPSchema.string("Replacement; an empty string removes the match. With regex, a template: $1 inserts the first group."),
            "regex": MCPSchema.boolean("find is a regular expression (default false)."),
            "track": MCPSchema.string("Which track (default both).", oneOf: ["original", "translation", "both"])
        ], required: ["find", "with"])
        return MCPToolDefinition(
            .editSubtitles, title: "Edit subtitles",
            description: """
            Change subtitle lines in one call: edit text or times by id (get_subtitles), add, delete or merge lines (merge keeps \
            word times), find and replace on every line, or strip_punctuation. style sets this project's subtitle look: set it \
            before generate_subtitles or add_voiceover subtitles=true. Creates the subtitle track if there is none. One undo step.
            """,
            input: MCPSchema.object([
                "changes": MCPSchema.array(of: change, "Lines to change."),
                "add": MCPSchema.array(of: addition, "Lines to add."),
                "delete": MCPSchema.array(of: MCPSchema.string("Line id."), "Lines to delete."),
                "merge": MCPSchema.array(
                    of: MCPSchema.array(of: MCPSchema.string("Line id."), "Two or more lines on one track, in order."),
                    "Groups of lines to join into one (text, times and word times combined)."
                ),
                "replace": MCPSchema.array(of: replacement, "Find and replace on every line of a track; runs after changes, add and merge, before delete."),
                "strip_punctuation": MCPSchema.boolean(
                    "Remove pause punctuation from every line, the way generated subtitles are written; runs after replace."
                ),
                "style": subtitleStyle
            ])
        )
    }

    private static var exportVideo: MCPToolDefinition {
        MCPToolDefinition(
            .exportVideo, title: "Export the video",
            description: """
            Render the project to MP4 (audio-only: M4A), burning visible subtitles. preset=final uses the saved settings; \
            preset=quick_review is a fast, small review copy; per-call fields override without changing saved settings. Never \
            replaces a file. Returns job_id: wait with get_job. Pass on get_timeline music_credits.
            Example: {"preset":"quick_review"}
            """,
            input: MCPSchema.object([
                "path": MCPSchema.string("Full output path. Leave out to use name and the default folder."),
                "name": MCPSchema.string("File name without extension."),
                "version": MCPSchema.string("Short version label: the file is named <name> - <version> (a project made with version already has it)."),
                "resolution": MCPSchema.string(
                    "Short-side cap; default saved; never upscales.", oneOf: MCPVocabulary.resolutions
                ),
                "encoder": MCPSchema.string("Per-call encoder.", oneOf: ["software", "hardware"]),
                "quality": MCPSchema.string("Per-call quality.", oneOf: MCPVocabulary.encodeQualities),
                "preset": MCPSchema.string("final: saved settings; quick_review: hardware/720p/small/AAC128. Explicit fields override.", oneOf: ["final", "quick_review"]),
                "burn_subtitles": MCPSchema.boolean("Burn visible subtitles into the picture (default true).")
            ])
        )
    }
}
