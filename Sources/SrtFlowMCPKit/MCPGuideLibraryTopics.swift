import Foundation

// MARK: - 说明书：曲库、文稿、字幕文件、剪辑风格、角色（第二批，2026-11-10）
//
// 管什么：find_audio、read_document、convert_subtitles、recipes、save_recipe、list_characters、get_character 名片写短之后的长话。
// 出处：迁移前的说明原文和参数说明（MCPGuidePreviousCardsBatch2）、docs/plans/2026-09-22-audio-library.md（只收 CC-BY / CC0、署名）、
// ai-control-mcp.md 第四节（读点名文件夹以外的文件问一次并记住、撞名加编号、剪辑风格 AI 自己挑并说一句、存风格只在用户开口时）、
// sky-studio-jobs.md 第十三节（角色的读是免费的、摘要 ≤ 1 KiB、换图后旧 revision 和批准作废）。只写英文。
// 不管什么：参数一行一行的类型和范围（fields 自动生成）。

enum MCPGuideLibraryTopics {
    static let findAudio = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCardsBatch2.findAudio,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCardsBatch2.findAudio, """
            find_audio searches SkyCut's library; it never downloads or changes anything.
            """),
            MCPGuideSection(name: "search", about: "query words, kinds and the number of results", text: """
            Search. query matches English or Chinese words in the title, artist and tags; every word must match; an empty query \
            lists everything. kind is any (default), music or sound_effect; max_results is 1–50 (default 10).
            """),
            MCPGuideSection(name: "results", about: "what each result tells you", text: """
            Results. Each result has its length, tags, intensity 1–5 and licence; music adds vocals, loudness and its credit \
            line; a sound effect's hit marks its loudest second, which add_clips hit_at lines up with a cut.
            """),
            MCPGuideSection(name: "using", about: "putting it on the timeline, credits, making a sound", text: """
            Using it. Put a result on the timeline with add_clips library_id (SkyCut downloads it). Music is CC-BY or CC0; the \
            sound effects are SkyCut's own and need no credit. When you deliver, pass on the CC-BY credit lines from \
            get_timeline music_credits. When nothing fits, add_clips sound_effect makes one on this Mac; never download music \
            or sound effects from elsewhere.
            """)
        ],
        examples: [
            ["query": "calm piano", "kind": "music"],
            ["query": "whoosh", "kind": "sound_effect", "max_results": 5]
        ],
        related: ["add_clips", "get_timeline"]
    )

    static let readDocument = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCardsBatch2.readDocument,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCardsBatch2.readDocument, """
            read_document reads a document's text; it never changes the file.
            """),
            MCPGuideSection(name: "formats", about: "which files work", text: """
            Formats. PDF, Word (.doc, .docx), RTF, ODT, .txt and .md. Pages files do not work (ask for PDF or Word), and scanned \
            PDFs have no text (they are pictures of text).
            """),
            MCPGuideSection(name: "pieces", about: "long documents in pieces", text: """
            Pieces. It returns at most max_chars characters (500–100000, default 20000) starting at from_char (default 0); when \
            there is more, call again with from_char = next_from_char.
            """),
            MCPGuideSection(name: "access", about: "files outside the opened folder", text: """
            Access. Files in the opened folder are read at once. A file outside it may return needs_confirmation: ask the user, \
            then repeat with confirm_token; the folder is remembered after they agree.
            """)
        ],
        examples: [
            ["file": "script.docx"],
            ["file": "notes.pdf", "from_char": 20000]
        ],
        related: ["open_folder", "set_texts", "add_voiceover"]
    )

    static let convertSubtitles = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCardsBatch2.convertSubtitles,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCardsBatch2.convertSubtitles, """
            convert_subtitles writes new subtitle files; it does not touch the project.
            """),
            MCPGuideSection(name: "formats", about: "the target formats", text: """
            Formats. to is srt, vtt (WebVTT), ass, ssa or txt (plain text). Each input file gives one output with the new \
            extension.
            """),
            MCPGuideSection(name: "output", about: "the folder, numbering and unreadable files", text: """
            Output. Files go to SkyCut/Exports inside the opened folder, or into folder (absolute, or relative to the opened \
            folder; made if missing). A taken name gets a number; nothing is overwritten. It finishes at once and returns where \
            each file went and which files could not be read. Files outside the opened folder may return needs_confirmation.
            """)
        ],
        examples: [["files": ["talk.srt"], "to": "vtt"]],
        related: ["export_subtitles", "burn_subtitles"]
    )

    static let recipes = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCardsBatch2.recipes,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCardsBatch2.recipes, """
            recipes reads editing styles; it never changes anything.
            """),
            MCPGuideSection(name: "styles", about: "what a style contains, presets and the user's own", text: """
            Styles. A style says how to cut a whole video: structure by the second, shot lengths, transitions, filters, fonts, \
            music, voice and a checklist. Without id it lists every style with when to use it (presets: product or course \
            promo, cinematic opening, sci-fi, documentary, daily vlog; the user may have their own); with id (an id or title) \
            it returns the whole style.
            """),
            MCPGuideSection(name: "using", about: "picking one, telling the user, following it", text: """
            Using one. Before editing a whole video from the user's footage, pick the style that fits their goal, tell them in \
            one sentence which one you follow, and follow it; what the user says always wins. Call them editing styles when \
            talking to the user (the built-in ones are preset styles). If they want a style again later, offer save_recipe.
            """)
        ],
        examples: [
            ["id": "documentary"]
        ],
        related: ["save_recipe", "workflows"]
    )

    static let saveRecipe = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCardsBatch2.saveRecipe,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCardsBatch2.saveRecipe, """
            save_recipe saves one of the user's own editing styles, only when they ask.
            """),
            MCPGuideSection(name: "writing", about: "name, use_for and the Markdown text", text: """
            Writing it. name is the style's name (for example Course promo); use_for is one sentence on when to use it; text is \
            the whole style in Markdown, written like the preset ones (read one with recipes first).
            """),
            MCPGuideSection(name: "storage", about: "replacing, presets and where styles live", text: """
            Storage. The name of one of the user's styles replaces it (the old file goes to the Trash); a preset style's name \
            makes the user's own version of it. Styles live in SkyCut's own folder (Settings > Editing & Voices lists them), \
            not in the project.
            """)
        ],
        examples: [
            ["name": "Course promo", "use_for": "Short promos for online courses", "text": "# Course promo\n\nStructure: ..."]
        ],
        related: ["recipes", "get_settings"]
    )

    static let listCharacters = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCardsBatch2.listCharacters,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCardsBatch2.listCharacters, """
            list_characters reads the user's Sky Studio character library; it is free.
            """),
            MCPGuideSection(name: "paging", about: "status filters, page size and cursors", text: """
            Paging. status is ready (default), draft, generating, failed or all; limit is 1–100 (default 50); pass the previous \
            page's next_cursor as cursor.
            """),
            MCPGuideSection(name: "entries", about: "what each summary holds, and get_character", text: """
            Entries. Each summary has id, name, status, revision, available_roles, the saved model and tier and dates; at most \
            1 KiB each, with no image or thumbnail URLs. get_character gives one character's full details.
            """),
            MCPGuideSection(name: "capabilities", about: "capabilities=true for creating characters", text: """
            Capabilities. capabilities=true also returns the character models, tiers, defaults, limits and prices that \
            manage_characters uses (separate from the ordinary image catalog). Nothing is uploaded, reserved or generated.
            """)
        ],
        examples: [
            ["limit": 20],
            ["capabilities": true]
        ],
        related: ["get_character", "manage_characters", "generate_media"]
    )

    static let getCharacter = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCardsBatch2.getCharacter,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCardsBatch2.getCharacter, """
            get_character reads one Sky Studio character; it is free.
            """),
            MCPGuideSection(name: "views", about: "views, the revision, and other accounts' ids", text: """
            Views. It returns the character's available views (front, headshot, side, back) and its revision. An id from \
            another account comes back as not_found.
            """),
            MCPGuideSection(name: "using", about: "using a character with generate_media, and revisions", text: """
            Using it. Pass character_id to generate_media; Sky Studio uses the views directly, without downloading or uploading \
            them. After a view is replaced, read the character again and quote again: old revisions and approvals no longer \
            apply.
            """)
        ],
        examples: [["character_id": "00000000-0000-0000-0000-000000000000"]],
        related: ["list_characters", "generate_media", "manage_characters"]
    )
}
