import Foundation

// MARK: - 说明书：录屏、文件夹、整理文件、设置（第一批，2026-11-10）
//
// 管什么：record_screen、manage_files、open_folder、set_settings 名片写短之后的长话。
// 出处：迁移前的说明原文和参数说明（MCPGuidePreviousCards）、docs/architecture/screen-recording-lifecycle.md 与
// docs/plans/2026-10-03-screen-recording-mcp.md（AI 自己选来源、浮窗在左下角、入轨一步撤销、从不覆盖、丢弃先问）、
// docs/bugfixes/2026-10-03-set-canvas-fps-ignored-while-recording.md（录制中挡改帧率）、ai-control-mcp.md 第四节
// （整理文件只在用户开口时、进废纸篓、改名撞名不覆盖）、workbench-and-settings.md（设置先全验再写、改权限一律要确认）。只写英文。
// 不管什么：参数一行一行的类型和范围（fields 自动生成）。

enum MCPGuideWorkspaceTopics {
    static let recordScreen = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCards.recordScreen,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCards.recordScreen, """
            record_screen records the screen into the project. Choose the source yourself; SkyCut never opens the system picker.
            """),
            MCPGuideSection(name: "sources", about: "display, window, region or drag, plus sound and pointer", text: """
            Sources. get_status screen=true lists displays, windows and microphones. source is display (default; display picks \
            which, 1 is the main one), window (an app name, title words or a window number; the frontmost match), region (rect \
            as display fractions, 0,0 top left) or drag (the user drags the area; ratio can lock its shape). computer_audio \
            records the Mac's sound (default true); microphone puts narration on its own track (off unless given). pointer is \
            shown, hidden or clicks.
            """),
            MCPGuideSection(name: "start_stop", about: "countdown, the Stop panel, stopping and the receipt", text: """
            Start and stop. action=start counts down (countdown, default 3; 0 when you operate the Mac yourself), then returns \
            while capture continues. A small Stop panel at the bottom left of the main display shows the countdown; it is \
            invisible in screenshots, so do not click there. Recording ends on action=stop, after duration seconds, or when the \
            user presses Stop. action=stop returns the job id, status, file, project, clip ids, stopped_by and stop_method (a \
            late stop returns the finished receipt). A user Stop is also reported on your next tool result. get_job shows \
            progress and the same receipt.
            """),
            MCPGuideSection(name: "results", about: "the file, timeline placement, incomplete recordings, resolve", text: """
            Results. The .mov is named title (default Screen Recording <date time>) in SkyCut/Screen Recordings; a taken name \
            gets a number. With add_to_timeline (default true) it goes to the end of V1 as one undo step, the microphone on a \
            new audio track; false keeps only the file. An incomplete recording still lands and says why. action=resolve \
            settles an earlier unfinished recording with decision add, keep or discard; discard asks first in approval mode \
            (needs_confirmation).
            """),
            MCPGuideSection(name: "permission", about: "the macOS permission, the 30-day reminder, frame rate", text: """
            Permission and frame rate. Without Screen & System Audio Recording permission macOS asks the user once; the result \
            explains next steps. macOS may remind them every 30 days. The frame rate follows set_canvas fps, which cannot change \
            while recording.
            """)
        ],
        examples: [
            ["action": "start", "source": "display", "countdown": 3],
            ["action": "stop"]
        ],
        related: ["get_status", "get_job", "set_canvas"],
        readingTip: "To make a first recording, read only section=start_stop."
    )

    static let manageFiles = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCards.manageFiles,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCards.manageFiles, """
            manage_files organises files in the user's folders, only when the user asks.
            """),
            MCPGuideSection(name: "actions", about: "move, rename, make_folder and trash, and what each takes", text: """
            Actions. move moves files or folders into to (made if missing); rename gives file a new_name (without folders; the \
            extension is kept if you leave it out); make_folder creates path; trash moves files or folders to the Trash. \
            Everything stays inside folders the user named with open_folder.
            """),
            MCPGuideSection(name: "rules", about: "when to use it, approval, overwriting and undo", text: """
            Rules. Use it only when the user asked you to organise or clean up; never touch the originals on your own. Nothing is \
            overwritten: a taken name fails and you pick another. trash returns needs_confirmation in approval mode (ask, then \
            repeat with confirm_token); full_access proceeds and notifies the user. Command-Z and undo do not revert these, so \
            tell the user what you did.
            """),
            MCPGuideSection(name: "projects", about: "media in the open project follows moved files", text: """
            Projects. Media used in the open project follows its moved files, so the timeline keeps working.
            """)
        ],
        examples: [
            ["action": "make_folder", "path": "Selects"],
            ["action": "move", "files": ["clip-03.mp4"], "to": "Selects"]
        ],
        related: ["open_folder", "read_document"]
    )

    static let openFolder = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCards.openFolder,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCards.openFolder, """
            open_folder sets the folder you work in; it changes no files.
            """),
            MCPGuideSection(name: "listing", about: "what the result lists, and how paths look", text: """
            Listing. It lists videos, images, audio and subtitle files in the folder and every subfolder, with duration and \
            size, up to max_files (default 400, up to 2000). Paths in the result are relative to the folder, and relative paths \
            you pass to other tools are relative to it too.
            """),
            MCPGuideSection(name: "workspace", about: "importing without asking, and where new files go", text: """
            Workspace. Files in it can be imported without asking again. New files SkyCut makes (exports, projects) go into its \
            SkyCut subfolder (or an older SrtFlow one). Only pass a folder the user gave you; ~ means the user's home folder.
            """),
            MCPGuideSection(name: "finder", about: "using what the user selected in Finder", text: """
            Finder. When the user says to use what they selected in Finder, pass from_finder=true instead of path: the selected \
            files are listed (their folder becomes the workspace), or the selected folder, or the folder open in the front \
            Finder window. macOS asks the user once to let SkyCut see Finder.
            """)
        ],
        examples: [
            ["path": "~/Movies/Trip"],
            ["from_finder": true]
        ],
        related: ["open_project", "new_project", "manage_files"]
    )

    static let setSettings = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCards.setSettings,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCards.setSettings, """
            set_settings changes app-wide preferences, never a project.
            """),
            MCPGuideSection(name: "preferences", about: "theme, language, cache, the daily credit limit and the access mode", text: """
            Preferences. theme is forest (default) or classic; language is the interface language (it applies now, native menus \
            after a restart); optimized_media_cache_gb is the cache limit in decimal GB, matching the Settings picker; \
            clear_optimized_media_cache=true clears regenerable preview media (false does nothing); daily_ai_credit_limit is the \
            hard daily AI budget in credits (0 pauses paid work); ai_access_mode is ask_for_approval or full_access.
            """),
            MCPGuideSection(name: "approval", about: "what always needs the user's agreement and confirm_token", text: """
            Approval. Change only what the user asked for. Any ai_access_mode change always needs the user's explicit agreement \
            and confirm_token, even in full_access; so does raising daily_ai_credit_limit. Ask in the conversation language, \
            using the localized names from get_settings section=ai.
            """),
            MCPGuideSection(name: "behaviour", about: "validation, omitted fields and what it never touches", text: """
            Behaviour. Omitted or null fields stay unchanged, and everything is validated before anything is applied. It never \
            edits a project; keys and connections stay in Settings.
            """)
        ],
        examples: [
            ["theme": "classic"],
            ["daily_ai_credit_limit": 500]
        ],
        related: ["get_settings", "paid"]
    )
}
