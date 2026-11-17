import Foundation

// MARK: - 工具说明：状态、文件夹、工程、撤销、播放头
//
// 管什么：这几样工具给 AI 看的说明文字和参数表。清单的总入口在 MCPToolCatalog.swift。

public enum MCPProjectTools {
    /// 每个碰工程的工具都收的 `project` 参数的说明（`MCPToolDefinition.addProjectParameter` 统一加）。
    static let projectParameter = "Project; default last opened."

    static func definition(for name: MCPToolName) -> MCPToolDefinition {
        switch name {
        case .getStatus:
            return MCPToolDefinition(
                .getStatus, title: "SkyCut status",
                description: """
                Read-only. Projects, folders, jobs, screen recording, and cloud_tasks grouped by project: closed ones too. \
                models=true: free model catalog; screen=true: recording sources; film_contract=true: public film contract.
                """,
                input: MCPSchema.object([
                    "screen": MCPSchema.boolean("Also list the displays, windows and microphones record_screen can use."),
                    "models": MCPSchema.boolean("Also list Sky Studio's models and reference limits (free, read-only)."),
                    "model": MCPSchema.string("With models=true, return only this model id, for example minimax-h3."),
                    "film_contract": MCPSchema.boolean("Public film/production contracts; local, free; no deployment proof.")
                ]),
                readOnly: true, openWorld: true
            )
        case .setView:
            return MCPToolDefinition(
                .setView, title: "View mode",
                description: """
                Ask the user once per conversation: visible (default) shows edits; background leaves SkyCut where it is. \
                With project: only that one; without: all yours. Lasts until SkyCut quits.
                """,
                input: MCPSchema.object([
                    "mode": MCPSchema.string("How the user follows your edits.", oneOf: ["visible", "background"])
                ], required: ["mode"])
            )
        case .openFolder:
            return MCPToolDefinition(
                .openFolder, title: "Open a media folder",
                description: """
                Read-only. List media in a user-named folder and subfolders. Use only a folder the user gave you, or \
                from_finder=true for their Finder selection. Files inside import without asking again.
                """,
                input: MCPSchema.object([
                    "path": MCPSchema.string("Absolute path of the folder. ~ means the user's home folder."),
                    "from_finder": MCPSchema.boolean("Use what the user selected in Finder instead of path."),
                    "max_files": MCPSchema.integer("Stop listing after this many files (default 400).", minimum: 1, maximum: 2000)
                ]),
                readOnly: true
            )
        case .openProject:
            return MCPToolDefinition(
                .openProject, title: "Open a project",
                description: """
                Open .skycut or .srtflowproj; returns project id. For several projects, pass project=<id> on each call; \
                omitted means last opened. At most 8 open; close_project finished ones.
                """,
                input: MCPSchema.object([
                    "path": MCPSchema.string("Absolute path of the project file (.skycut or .srtflowproj).")
                ], required: ["path"])
            )
        case .newProject:
            return MCPToolDefinition(
                .newProject, title: "New project",
                description: """
                Create and save an empty project; edits then autosave. A taken name gets a number. A second cut in the same \
                folder needs version. Returns project id. Locations: skycut_guide topic=new_project.
                """,
                input: MCPSchema.object([
                    "name": MCPSchema.string("Project name without extension. Default: the workspace folder's name."),
                    "version": MCPSchema.string("Short version label (30s, vertical, v2): the file is <name> - <version>."),
                    "folder": MCPSchema.string("Folder to save the project in, when there is no workspace yet.")
                ])
            )
        case .closeProject:
            return MCPToolDefinition(
                .closeProject, title: "Close a project",
                description: """
                Close project; saved first. Refused while its jobs run: wait with get_job or use cancel_job.
                """,
                input: MCPSchema.object([:], required: ["project"])
            )
        case .saveProject:
            return MCPToolDefinition(
                .saveProject, title: "Save the project",
                description: """
                Save the project now, or a copy to path (a taken name gets a number). Edits autosave anyway. production writes the \
                official film plan as one undo step (read get_status film_contract=true first).
                """,
                input: MCPSchema.object([
                    "path": MCPSchema.string("Save location (.skycut); default current."),
                    "production": ["type": ["object", "null"], "description": "Public plan; null clears."],
                    "expected_revision": MCPSchema.integer("Current production revision; 0 if absent.", minimum: 0)
                ])
            )
        case .undo:
            return MCPToolDefinition(
                .undo, title: "Undo",
                description: """
                Undo edits (steps, default 1); round=true restores this AI round's starting state as one undo step. \
                File operations are not undone.
                """,
                input: MCPSchema.object([
                    "steps": MCPSchema.integer("How many edits to undo (default 1).", minimum: 1, maximum: 50),
                    "round": MCPSchema.boolean("Undo everything done since this round of AI edits began.")
                ]),
                destructive: true
            )
        case .seek:
            return MCPToolDefinition(
                .seek, title: "Show a moment",
                description: """
                    Read-only. Show a timeline moment to the user by moving the playhead.
                    """,
                input: MCPSchema.object([
                    "time": MCPSchema.number("Timeline time in seconds (≥ 0).", minimum: 0)
                ], required: ["time"]),
                readOnly: true
            )
        default:
            preconditionFailure("\(name.rawValue) is described in another group")
        }
    }
}
