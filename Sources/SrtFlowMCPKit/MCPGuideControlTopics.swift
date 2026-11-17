import Foundation

// MARK: - 说明书：撤销、播放头、取消任务、读设置（第二批，2026-11-10）
//
// 管什么：undo、seek、cancel_job、get_settings 名片写短之后的长话。
// 出处：迁移前的说明原文和参数说明（MCPGuidePreviousCardsBatch2）、docs/architecture/ai-control-mcp.md 第五节（这一轮 / 撤销这一轮、
// 一个工具 = 一步撤销）与第四节（整理文件撤不回、任务排队、取消先从队里拿）、sky-studio-jobs.md（只能取消排队中的、角色任务不能取消）、
// workbench-and-settings.md（设置的分区、不碰密钥）、sky-studio-account.md（没开通时只有 get_status 和说明书照答）。只写英文。
// 不管什么：参数一行一行的类型和范围（fields 自动生成）。

enum MCPGuideControlTopics {
    static let undo = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCardsBatch2.undo,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCardsBatch2.undo, """
            undo reverses edits in the project, the way the user would with Command-Z.

            Undo the latest edits, like Command-Z (steps, default 1). round=true puts the project back to how it was before this \
            round of AI edits began, itself one undo step. File moves by manage_files are not undone.

            Undo like Command-Z (steps, default 1), this AI round (round=true) or to a saved version (version=<id>). Each is one \
            undo step.
            """),
            MCPGuideSection(name: "steps", about: "how many edits, and what one edit is", text: """
            Steps. steps (1–50, default 1) undoes that many edits. Every tool call that changes a project is one undo step, so \
            one step undoes one call; batch tools and add_clips count as one.
            """),
            MCPGuideSection(name: "round", about: "undoing this whole round of AI edits", text: """
            Round. round=true puts the project back to how it was before this round of AI edits began, as one undo step of its \
            own. Use it when the user wants everything you did undone.
            """),
            // Saved versions (2026-11-17): docs/architecture/project-versions.md, ai-control-mcp.md section 5.
            MCPGuideSection(name: "versions", about: "saved versions from before and after each round, and going back to one", text: """
            Saved versions. For a project with a file, SkyCut saves a version (v1, v2…) when a round of AI edits first changes it \
            (the state from before the round) and when the round ends (30 seconds without calls, or the user's Stop), but only when \
            the project changed since its newest version. The round's first change returns before_round_version: tell the user its id. \
            version=<id> puts the whole project back to that version as one undo step; the state you leave is saved first \
            (saved_before_going_back in the result). Unlike round=true it survives a restart and reaches older rounds. get_status \
            lists the newest versions; each project keeps its newest 30. An unknown id lists the ones there are.
            """),
            MCPGuideSection(name: "limits", about: "what undo cannot reverse", text: """
            Limits. File operations by manage_files (moves, renames, the Trash) and files you wrote (exports, recordings) are \
            not undone; tell the user what you did instead.
            """)
        ],
        examples: [
            ["steps": 2],
            ["round": true],
            ["version": "v3"]
        ],
        related: ["get_timeline", "get_status", "manage_files"]
    )

    static let seek = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCardsBatch2.seek,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCardsBatch2.seek, """
            seek moves the playhead so the user sees a frame; it never changes the project.

            Read-only for the project: move SkyCut's playhead to a timeline time so the user sees that frame in the preview.
            """),
            MCPGuideSection(name: "showing", about: "pointing the user at a moment", text: """
            Showing a moment. time is timeline seconds. The preview shows that frame, so use it to point the user at something \
            you found (a cut, a black frame). In visible mode SkyCut also shows each edit by itself.
            """),
            MCPGuideSection(name: "looking", about: "seeing a frame yourself instead", text: """
            Looking yourself. To see a frame yourself, use look at that time; seek only moves the playhead for the user.
            """)
        ],
        examples: [["time": 12.5]],
        related: ["look", "set_view"]
    )

    static let cancelJob = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCardsBatch2.cancelJob,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCardsBatch2.cancelJob, """
            cancel_job stops a job that returned job_id.

            Stop a job: a running export, subtitle generation or translation stops, and a queued job is dropped. Sky Studio jobs \
            can only be cancelled while queued; character jobs cannot. Check get_job afterwards.
            """),
            MCPGuideSection(name: "what_stops", about: "jobs on this Mac, queued jobs and Sky Studio jobs", text: """
            What stops. An export, subtitle generation or translation on this Mac stops at once, and a job still queued behind \
            another is dropped. Sky Studio jobs (generate_media, upscale_clip) can only be cancelled while queued; once \
            started they finish, are charged and stay in the user's library. Character jobs cannot be cancelled. A recording \
            ends with record_screen action=stop. A look that became a job stops at its next frame; still queued, it never starts.
            """),
            MCPGuideSection(name: "afterwards", about: "checking the result afterwards", text: """
            Afterwards. Check get_job: it shows whether the job stopped and, for paid jobs, the billing (billing_note).
            """)
        ],
        examples: [["job_id": "export-1"]],
        related: ["get_job", "export_video", "generate_media"]
    )

    static let getSettings = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCardsBatch2.getSettings,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCardsBatch2.getSettings, """
            get_settings reads app preferences; it never opens windows or changes anything.

            Read-only. App preferences without opening windows: general (language, theme), ai (clients, permission mode), editing \
            (styles, voices), cache and sky_studio (account, credits, daily limit). Returns values, writable fields and the \
            localized mode names; never keys. Change them with set_settings.
            """),
            MCPGuideSection(name: "sections", about: "general, ai, editing, cache and sky_studio", text: """
            Sections. general has the interface language and theme; ai the connected clients and the permission mode \
            (ask_for_approval or full_access) with the localized names to use when you ask the user; editing the editing styles \
            and voices; cache the optimized-media cache; sky_studio the account, credits and the daily hard credit limit. \
            section picks one (default all).
            """),
            MCPGuideSection(name: "changing", about: "where each setting is changed", text: """
            Changing them. Each value says whether it is writable; change them with set_settings. Editing styles are managed \
            with recipes and save_recipe; SkyCut's own voices are downloaded with add_voiceover download_voices=true. Keys and \
            client connections are never returned and stay in Settings. Without a plan that includes MCP it is refused like \
            the other tools; get_status still answers.
            """)
        ],
        examples: [["section": "ai"]],
        related: ["set_settings", "get_status", "recipes"]
    )
}
