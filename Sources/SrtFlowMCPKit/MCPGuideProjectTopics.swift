import Foundation

// MARK: - 说明书：工程这一组（第二批，2026-11-10）
//
// 管什么：get_status、set_view、open_project、new_project、close_project、save_project 名片写短之后的长话。
// 出处：迁移前的说明原文和参数说明（MCPGuidePreviousCardsBatch2）、docs/architecture/open-projects.md（短 id、最多 8 个、同一个文件只开一份、
// 后台工程不开窗口）、ai-control-mcp.md 第四节第 4、46 条（一个会话一组工程、别的会话的不碰、版本名）、mcp-discovery.md（mcp_catalog
// 不证明客户端换了清单）、official-film.md（production 和 film_contract）。只写英文。
// 不管什么：参数一行一行的类型和范围（fields 自动生成）。

enum MCPGuideProjectTopics {
    static let getStatus = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCardsBatch2.getStatus,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCardsBatch2.getStatus, """
            get_status reports on SkyCut and your projects; it never changes anything.
            """),
            MCPGuideSection(name: "status", about: "what the plain call reports", text: """
            What it reports. The open project (name, path, length, unsaved changes); every open project with its id (p1, p2…), \
            which AI session edits it and whether it has a window; the folders you opened; jobs and whether the user pressed \
            Stop; the screen recording state, its permission and any leftover recording; and cloud_tasks grouped by project, \
            background and closed projects included. mcp_catalog gives the App's tool count and fingerprint; it does not prove \
            that your client reloaded the tools. skycut_plan says what the user's plan includes.
            """),
            MCPGuideSection(name: "extras", about: "models=true, screen=true and film_contract=true", text: """
            Extras. models=true reads Sky Studio's model catalog with prices, defaults and reference limits, free and \
            read-only; model narrows it to one id (for example minimax-h3). screen=true lists the displays, windows and \
            microphones record_screen can use. film_contract=true returns the public contracts of the official film flow; it is \
            local and free, and no proof that anything is deployed.
            """)
        ],
        examples: [
            ["models": true, "model": "minimax-h3"],
            ["screen": true]
        ],
        related: ["get_settings", "record_screen", "generate_media"]
    )

    static let setView = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCardsBatch2.setView,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCardsBatch2.setView, """
            set_view decides whether the user watches your edits; it never changes a project.
            """),
            MCPGuideSection(name: "modes", about: "visible versus background", text: """
            Modes. visible (the default) brings a project's window forward once when you open it (or now), and selects and \
            shows each edit in its preview. background leaves SkyCut where it is and does not follow the edits; they still go \
            into the project and can be undone, and projects you open then have no window (the user sees them in SkyCut's AI \
            projects list).
            """),
            MCPGuideSection(name: "scope", about: "one project or all of yours, how long it lasts, asking the user", text: """
            Scope. With project only that project changes mode; without it, your open projects and the ones you open next. The \
            mode lasts until SkyCut quits. Ask the user once per conversation which they want, unless they already said.
            """)
        ],
        examples: [
            ["mode": "background"],
            ["mode": "visible", "project": "p2"]
        ],
        related: ["open_project", "get_status"]
    )

    static let openProject = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCardsBatch2.openProject,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCardsBatch2.openProject, """
            open_project opens a project file and gives you its id.
            """),
            MCPGuideSection(name: "ids", about: "project ids and working on several projects", text: """
            Ids. The result's project is its id (p1, p2…). To edit several projects (for example with sub-agents), open or \
            create them all first, then pass project=<id> on every call; a call without project goes to the project you opened \
            last.
            """),
            MCPGuideSection(name: "windows", about: "which window it opens in, and background projects", text: """
            Windows. It opens in SkyCut's main window when that is empty, otherwise in a window of its own, shown once. After \
            set_view background it opens with no window; the user sees it in SkyCut's AI projects list.
            """),
            MCPGuideSection(name: "limits", about: "files already open, other sessions, the 8-project limit", text: """
            Limits. A file already open is not opened twice: you get its id, unless another AI session is editing it. SkyCut \
            keeps at most 8 projects open: close_project the finished ones. .srtflowproj files from before the rename open too.
            """)
        ],
        examples: [["path": "/path/to/Trip.skycut"]],
        related: ["new_project", "close_project", "set_view"]
    )

    static let newProject = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCardsBatch2.newProject,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCardsBatch2.newProject, """
            new_project creates and saves an empty project.
            """),
            MCPGuideSection(name: "where", about: "where the file goes and how it is named", text: """
            Where. The file is <name>.skycut, saved at once so every later edit autosaves. It goes into folder when given, \
            otherwise SkyCut/Projects inside the folder the user named with open_folder, the open project's folder, or \
            Downloads. name defaults to the workspace folder's name. A taken name gets a number; the result has the real path.
            """),
            MCPGuideSection(name: "versions", about: "several cuts from one folder with version", text: """
            Versions. Several cuts from one folder need version (a short label such as 30s, vertical or v2): the file becomes \
            <name> - <version>. A second project in a folder where you already have one open is refused without it. Exports \
            of a project made with version carry the label too.
            """),
            MCPGuideSection(name: "ids", about: "the project id and the open-project rules", text: """
            Ids and limits. The result's project is its id; it opens and counts like open_project (windows, set_view \
            background, at most 8 open).
            """)
        ],
        examples: [
            ["name": "Trip"],
            ["name": "Trip", "version": "vertical"]
        ],
        related: ["open_project", "open_folder", "close_project"]
    )

    static let closeProject = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCardsBatch2.closeProject,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCardsBatch2.closeProject, """
            close_project saves and closes one of your projects.
            """),
            MCPGuideSection(name: "when", about: "when to close, and the 8-project limit", text: """
            When. Close a project when you are done with it, for example after its export finished. SkyCut keeps at most 8 \
            projects open, so close finished ones before opening more. It is saved first.
            """),
            MCPGuideSection(name: "refusals", about: "running jobs and other sessions' projects", text: """
            Refusals. It is refused while one of the project's jobs runs (export, subtitles, translation…): wait with get_job, \
            or stop it with cancel_job first. Projects another AI session is editing are not yours to close.
            """)
        ],
        examples: [["project": "p2"]],
        related: ["open_project", "get_job", "cancel_job"]
    )

    static let saveProject = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCardsBatch2.saveProject,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCardsBatch2.saveProject, """
            save_project saves now or writes a copy; edits autosave anyway.
            """),
            MCPGuideSection(name: "saving", about: "saving in place, saving a copy, numbering", text: """
            Saving. Without path it saves the project where it is. path saves to that location (.skycut); a taken name gets a \
            number. Every edit also autosaves; when an AI-made project had never been saved, SkyCut saves it into the \
            workspace and reports project_saved_to: tell the user where it is.
            """),
            MCPGuideSection(name: "film_plan", about: "the official film plan: production and expected_revision", text: """
            Film plan. production writes the public plan of the official original-film flow as one undo step (null clears \
            it); expected_revision is the plan's current revision (0 when there is none). Read get_status film_contract=true \
            for the full contract first.
            """)
        ],
        examples: [["path": "/path/to/Trip copy.skycut"]],
        related: ["get_status", "close_project"]
    )
}
