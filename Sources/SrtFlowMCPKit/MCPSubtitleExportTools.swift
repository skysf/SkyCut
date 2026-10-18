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
                Transcribe the speech on the timeline into the subtitle track, on this Mac (needs macOS 26). Replaces the \
                current subtitles as one undoable step. Hidden clips are skipped. Optionally translate right after (the same \
                language download dialog as translate_subtitles can appear). Each subtitle is one line; what does not fit \
                becomes the next subtitle. Pass max_lines=2 only when the user wants two-line subtitles (the project remembers \
                it). Set the style first (edit_subtitles style): lines are cut to fit it. Returns a job id; wait with get_job.
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
                Translate the original subtitle track into a second track in another language, on this Mac. The original's \
                language is read from its text (rewriting the original first is fine). scope all rebuilds every translated line \
                (hand-edited ones are replaced); missing only fills lines with no translation or whose original changed. Returns \
                a job id. If this Mac still has to download the languages, macOS shows a download dialog in SkyCut that only \
                the user can click; the result and get_job then carry waiting_for_user, which you must pass on to the user.
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
                Subtitle lines with ids, start and end on the timeline and text, from the original track, the translated track, \
                or both; optionally only inside a time range. Each shown line also has box (where it is drawn on the canvas with \
                the current style, [x, y, width, height] as fractions from the top left) and lines when it wraps: use them to keep \
                subtitles clear of watermarks or to pick style.max_width. Also the style, max_lines (1 or 2: how many lines a \
                generated subtitle may take) and how many lines know their word times (for highlight).
                """,
                input: MCPSchema.object([
                    "track": MCPSchema.string("Which track (default both).", oneOf: ["original", "translation", "both"]),
                    "start": MCPSchema.number("Only lines that end after this time.", minimum: 0),
                    "end": MCPSchema.number("Only lines that start before this time.", minimum: 0),
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
                Write the project's subtitles to files, one per track: the original, the translation, or both (default: every \
                track that has lines). Files are named <name>.<language>.srt (or .vtt), the language read from each track's \
                text (else the project's record), and go where export_video puts videos, so players pick them up; name \
                defaults to the project's, so pass the exported video's name to pair them. Hidden \
                lines are left out; times are timeline seconds. A taken name gets a number (the result has the real paths); \
                SkyCut never replaces a file. Done at once.
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
                Progress and result of a long job (any call that returned a job id). wait_seconds (up to 30) waits for it before \
                answering; keep waiting instead of starting it again. Exports, transcribing (subtitles, transcripts) and \
                translations run one at a time across all projects: a later one shows status queued with queue_position \
                (1 = next) and starts by itself. If it shows waiting_for_user, tell the user what it says right away.
                """,
                input: MCPSchema.object([
                    "job_id": MCPSchema.string("Job id."),
                    "wait_seconds": MCPSchema.number("Wait up to this long for the job to finish.", minimum: 0, maximum: 30)
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
        "margin": MCPSchema.number("Distance from that edge, as a fraction of the frame height (default 0.056).", minimum: 0, maximum: 0.45),
        "size": MCPSchema.number("Pixels on a 1080-tall frame (a 9:16 frame is 1920 tall: 1.78x larger there); default 56; bold captions 56-64 on 16:9, 42-48 on 9:16.", minimum: 20, maximum: 140),
        "max_width": MCPSchema.number("Widest line as a fraction of the frame width (default 0.92 on 16:9, 0.74 on 9:16); longer lines wrap. Project only.", minimum: 0.3, maximum: 1),
        "line_spacing": MCPSchema.number("Space between lines as a multiple of the line height, 1 (default) to 2; fonts whose glyphs fill the line (Yuanti) read better at 1.15-1.3.", minimum: 1, maximum: 2),
        "font": MCPSchema.string("Font family on this Mac that can burn Chinese or English, e.g. Hiragino Sans GB, Heiti SC, Helvetica Neue."),
        "bold": MCPSchema.boolean("Bold text."),
        "color": MCPSchema.string("Text colour, #RRGGBB."),
        "outline": MCPSchema.string("Outline colour #RRGGBB, or none."),
        "outline_width": MCPSchema.number("Outline thickness (the padding of the box when there is one).", minimum: 0, maximum: 12),
        "box": MCPSchema.string("A bar behind the text instead of an outline: #RRGGBBAA (e.g. #00000099), or none."),
        "shadow": MCPSchema.string("Drop shadow (with an outline, not a box): #RRGGBBAA (e.g. #000000B3), or none."),
        "highlight": MCPSchema.string("Word-by-word highlight: the spoken word turns this colour (#RRGGBB), or none. Project only."),
        "highlight_scale": MCPSchema.number("How much the spoken word grows (1-1.3, default 1.1; 1 for long lines).", minimum: 1, maximum: 1.3),
        "reset": MCPSchema.boolean("Go back to the style from SkyCut's Burn In Subtitles page first.")
    ])

    private static var editSubtitles: MCPToolDefinition {
        let change = MCPSchema.object([
            "id": MCPSchema.string("Line id from get_subtitles."),
            "text": MCPSchema.string("New text."),
            "start": MCPSchema.number("New start, timeline seconds.", minimum: 0),
            "end": MCPSchema.number("New end, timeline seconds.", minimum: 0)
        ], required: ["id"])
        let addition = MCPSchema.object([
            "track": MCPSchema.string("original (default) or translation.", oneOf: ["original", "translation"]),
            "start": MCPSchema.number("Timeline seconds.", minimum: 0),
            "end": MCPSchema.number("Timeline seconds.", minimum: 0),
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
            Change subtitle lines as one undoable step: edit text or times by id, add lines, delete lines, merge lines \
            (merge keeps the word times; retyping loses them), replace text on every line (replace) or strip punctuation from \
            every line (strip_punctuation, what generate_subtitles does); bulk edits keep the word times of unchanged words. \
            Creates the subtitle track if the project has none. style \
            sets how this project's subtitles look (the user's Burn In Subtitles page keeps its own; own_style in the result \
            turns true once the project has its own look; the word highlight always belongs to the project). Set it before \
            generate_subtitles or add_voiceover subtitles=true: lines are cut to fit that size. highlight only lights lines \
            SkyCut made from speech or a voiceover (get_subtitles says how many know their word times).
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
                    "Remove pause punctuation from every line, the way SkyCut writes generated subtitles: commas, periods, semicolons, "
                        + "colons (also Chinese ones) become a space mid-line and vanish at the end; ? ! quotes, numbers and abbreviations stay. "
                        + "Runs after replace. The result lists lines left empty."
                ),
                "style": subtitleStyle
            ])
        )
    }

    private static var exportVideo: MCPToolDefinition {
        MCPToolDefinition(
            .exportVideo, title: "Export the video",
            description: """
            Render the timeline to an .mp4 (audio-only timelines become .m4a). By default the file is named after the \
            project and goes into SkyCut/Exports inside the folder the user named (otherwise the project's folder, or \
            Downloads). Subtitles visible on the timeline are burned in unless burn_subtitles is false. A taken name gets a \
            number (the result has the real path); SkyCut never replaces a file. Returns a job id; wait with get_job. Then \
            give the user the music_credits (get_timeline) for the video's description.
            """,
            input: MCPSchema.object([
                "path": MCPSchema.string("Full output path. Leave out to use name and the default folder."),
                "name": MCPSchema.string("File name without extension."),
                "version": MCPSchema.string("Short version label: the file is named <name> - <version> (a project made with version already has it)."),
                "resolution": MCPSchema.string(
                    "Cap on the short side (default original; never upscales).", oneOf: MCPVocabulary.resolutions
                ),
                "burn_subtitles": MCPSchema.boolean("Burn visible subtitles into the picture (default true).")
            ])
        )
    }
}
