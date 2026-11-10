import Foundation

// MARK: - 说明书：字幕这一组（第一批，2026-11-10）
//
// 管什么：edit_subtitles、generate_subtitles、translate_subtitles、get_subtitles、export_subtitles 名片写短之后的长话。
// 出处：迁移前的说明原文和参数说明（MCPGuidePreviousCards）、docs/architecture/subtitle-generation-style.md（一行、max_lines、去标点）、
// subtitle-track-visibility-and-layout.md（两条独立轨、工程自己的样式、逐词高亮只亮带词时间的句子）、subtitle-language-flow.md
// （按字判语言、下载只能用户点）、export-settings.md（字幕文件名的语言标签、撞名加编号）。只写英文。
// 不管什么：参数一行一行的类型和范围（fields 自动生成）。

enum MCPGuideSubtitleTopics {
    static let editSubtitles = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCards.editSubtitles,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCards.editSubtitles, """
            edit_subtitles changes the project's subtitle lines (ids from get_subtitles) and this project's subtitle style. The \
            whole call is one undo step.
            """),
            MCPGuideSection(name: "lines", about: "changes, add, delete and merge, and what happens to word times", text: """
            Lines. changes edits the text, start or end of a line by id; add puts new lines on the original track (default) or \
            the translation; delete removes lines by id; merge joins two or more lines of one track, in order, combining text, \
            times and word times. Retyping a line's text loses its word times; merge keeps them. Times are timeline seconds. \
            The subtitle track is created if the project has none.
            """),
            MCPGuideSection(name: "bulk", about: "replace and strip_punctuation across every line", text: """
            Bulk edits. replace finds and replaces on every line of a track (both tracks by default). find is case-sensitive; \
            with regex=true it is an ICU regular expression and with is a template ($1 inserts the first group); an empty with \
            removes the match. replace runs after changes, add and merge, and before delete. strip_punctuation removes pause \
            punctuation the way SkyCut writes generated subtitles: commas, periods, semicolons and colons (also Chinese ones) \
            become a space mid-line and vanish at the end; question marks, exclamation marks, quotes, numbers and abbreviations \
            stay. It runs after replace, and the result lists lines left empty. Bulk edits keep the word times of unchanged words.
            """),
            MCPGuideSection(name: "style", about: "this project's subtitle look: position, size, width, font, colours", text: """
            Style. style sets how this project's subtitles look; the user's Burn In Subtitles page keeps its own style, and \
            own_style in the result turns true once the project has its own look. reset=true starts again from the Burn In \
            Subtitles page style. size is pixels on a 1080-tall frame (20–140, default 56): a 9:16 frame is 1920 tall, so the \
            same number looks 1.78x smaller there; bold captions are usually 56–64 on 16:9 and 42–48 on 9:16. position (bottom, \
            middle, top) and margin place the block; max_width wraps lines (default 0.92 on 16:9, 0.74 on 9:16); line_spacing \
            1.15–1.3 suits full-height fonts such as Yuanti. font must be installed and burnable (for example Hiragino Sans GB, \
            Heiti SC, Helvetica Neue). box draws a background bar instead of the outline; shadow needs the outline. Set the style \
            before generate_subtitles or add_voiceover subtitles=true: lines are cut to fit it.
            """),
            MCPGuideSection(name: "highlight", about: "the spoken-word highlight and which lines can light up", text: """
            Word highlight. highlight colours the word being spoken and highlight_scale (1–1.3, default 1.1; use 1 for long \
            lines) makes it grow. The highlight always belongs to the project. It only lights lines SkyCut made from speech or a \
            voiceover, because only those know their word times; get_subtitles says how many lines do.
            """)
        ],
        examples: [
            ["changes": [["id": "s3", "text": "Welcome back"]]],
            ["strip_punctuation": true],
            ["style": ["position": "bottom", "size": 48]]
        ],
        related: ["get_subtitles", "generate_subtitles", "burn_subtitles"],
        readingTip: "To set how subtitles look, read only section=style."
    )

    static let generateSubtitles = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCards.generateSubtitles,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCards.generateSubtitles, """
            generate_subtitles makes the subtitle track from the speech on the timeline, on this Mac.
            """),
            MCPGuideSection(name: "transcribing", about: "what gets transcribed, languages, macOS 26, translating right after", text: """
            Transcribing. It needs macOS 26 and transcribes the audible clips with speech, skipping hidden clips; clip_ids limits \
            it to some clips (for example just the voice-over). language is auto by default or a locale such as en-US, zh-CN or \
            ja-JP. translate_to also translates the result right after; as with translate_subtitles, macOS may show a language \
            download dialog that only the user can click (get_job then says waiting_for_user).
            """),
            MCPGuideSection(name: "lines", about: "one line per subtitle, max_lines, setting the style first", text: """
            How lines are cut. Each subtitle is one line; what does not fit becomes the next subtitle. Pass max_lines=2 only when \
            the user wants two-line subtitles; the project remembers it and add_voiceover subtitles follow it. Lines are cut to \
            fit the current style, so set it first with edit_subtitles style. Pause punctuation is removed the way edit_subtitles \
            strip_punctuation does.
            """),
            MCPGuideSection(name: "jobs", about: "job_id, get_job, the queue and the undo step", text: """
            Job and undo. It returns job_id: wait with get_job. The finished subtitles replace the current ones as one undo step. \
            Exports, transcriptions and translations run one at a time, so a later job shows queued with queue_position.
            """)
        ],
        examples: [
            ["language": "auto"],
            ["language": "en-US", "translate_to": "zh-Hans", "max_lines": 2]
        ],
        related: ["edit_subtitles", "translate_subtitles", "transcribe"]
    )

    static let translateSubtitles = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCards.translateSubtitles,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCards.translateSubtitles, """
            translate_subtitles fills the translation track from the original track, on this Mac.
            """),
            MCPGuideSection(name: "scope", about: "all versus missing, and the source language", text: """
            What gets translated. scope=all rebuilds every translated line (hand-edited translations are replaced); scope=missing \
            fills only lines with no translation or whose original changed. The source language is read from the original's \
            text (rewriting the original first is fine); source_language overrides it. target_language is a tag such as zh-Hans, \
            en, ja, ko or es.
            """),
            MCPGuideSection(name: "downloads", about: "language downloads only the user can approve, waiting_for_user", text: """
            Language downloads. If this Mac still has to download the languages, macOS shows a download dialog in SkyCut that \
            only the user can click. The result and get_job then carry waiting_for_user: tell the user right away what it says, \
            then keep waiting with get_job.
            """),
            MCPGuideSection(name: "results", about: "job_id, the queue, the undo step and the second track", text: """
            Results. It returns job_id: wait with get_job; translations run one at a time with exports and transcriptions \
            (queued shows queue_position). The finished translation lands as one undo step on its own track, which \
            edit_subtitles, get_subtitles and export_subtitles call translation.
            """)
        ],
        examples: [
            ["target_language": "zh-Hans"],
            ["target_language": "en", "scope": "missing"]
        ],
        related: ["generate_subtitles", "edit_subtitles", "get_job"]
    )

    static let getSubtitles = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCards.getSubtitles,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCards.getSubtitles, """
            get_subtitles reads the project's subtitle lines; it never changes anything.
            """),
            MCPGuideSection(name: "lines", about: "tracks, time ranges and limits", text: """
            Lines. track picks original, translation or both (default). start and end keep only lines inside that time range, in \
            timeline seconds; limit caps the lines per track (default 300, up to 2000). Each line has its id (for edit_subtitles), \
            start, end and text.
            """),
            MCPGuideSection(name: "boxes", about: "where each line is drawn: box and lines", text: """
            Where lines are drawn. Each shown line has box: where it is drawn on the canvas with the current style, as [x, y, \
            width, height] fractions from the top left, and lines when it wraps. Use them to keep subtitles clear of watermarks \
            (look text_scan finds those) or to pick style.max_width.
            """),
            MCPGuideSection(name: "style_words", about: "the style, max_lines and word times for the highlight", text: """
            Style and word times. The result also has the style, max_lines (1 or 2: how many lines a generated subtitle may \
            take) and how many lines know their word times; only those can light up with the highlight (edit_subtitles style).
            """)
        ],
        examples: [["track": "original", "start": 0, "end": 30]],
        related: ["edit_subtitles", "look", "export_subtitles"]
    )

    static let exportSubtitles = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCards.exportSubtitles,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCards.exportSubtitles, """
            export_subtitles writes subtitle files next to the exported videos; it finishes at once and starts no job.
            """),
            MCPGuideSection(name: "files", about: "one file per track, names, languages and formats", text: """
            Files. One file per track: the original, the translation or both (default: every track with lines). format is srt \
            (default) or vtt (WebVTT). Files are named <name>.<language>.srt; the language is read from each track's text, else \
            from the project's record. name defaults to the project's name: pass the exported video's name so players pair them.
            """),
            MCPGuideSection(name: "where", about: "the folder, numbering and what is left out", text: """
            Where and what. Files go where export_video puts videos unless folder names another folder (absolute, or relative \
            to the opened folder). A taken name gets a number and the result has the real paths; SkyCut never replaces a file. \
            Hidden lines are left out; times are timeline seconds.
            """)
        ],
        examples: [
            ["name": "Promo"],
            ["format": "vtt", "track": "translation"]
        ],
        related: ["export_video", "get_subtitles", "burn_subtitles"]
    )
}
