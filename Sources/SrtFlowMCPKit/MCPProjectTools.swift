import Foundation

// MARK: - 工具说明：状态、文件夹、工程、撤销、播放头
//
// 管什么：这几样工具给 AI 看的说明文字和参数表。清单的总入口在 MCPToolCatalog.swift。

public enum MCPProjectTools {
    /// 每个碰工程的工具都收的 `project` 参数的说明（`MCPToolDefinition.addProjectParameter` 统一加）。
    static let projectParameter = "Default: last opened."

    static func definition(for name: MCPToolName) -> MCPToolDefinition {
        switch name {
        case .getStatus:
            return MCPToolDefinition(
                .getStatus, title: "SkyCut status",
                description: """
                Read-only. Projects, folders, jobs, screen recording, and cloud_tasks grouped by project: closed ones too.
                """,
                input: MCPSchema.object([
                    "screen": MCPSchema.boolean("Also record_screen's sources."),
                    "models": MCPSchema.boolean("Also Sky Studio's model catalog (free)."),
                    "model": MCPSchema.string("With models=true: only this id (minimax-h3)."),
                    "film_contract": MCPSchema.boolean("Public film contracts; local, free.")
                ]),
                readOnly: true, openWorld: true
            )
        case .setView:
            return MCPToolDefinition(
                .setView, title: "View mode",
                description: """
                Ask the user once per conversation: visible (default) shows edits; background leaves SkyCut where it is.
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
                    "path": MCPSchema.string("Absolute folder path; ~ is home."),
                    "from_finder": MCPSchema.boolean("Use what the user selected in Finder instead of path."),
                    "max_files": MCPSchema.integer("Default 400, at most 2000.", minimum: 1, maximum: 2000)
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
                    "path": MCPSchema.string("Absolute path of the project file.")
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
                    "name": MCPSchema.string("No extension; default: workspace folder's name."),
                    "version": MCPSchema.string("Short label (30s, v2): <name> - <version>."),
                    "folder": MCPSchema.string("Save folder when there is no workspace.")
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
                Undo steps (default 1), this round (round=true) or saved version=<id>; one undo step. File operations are not undone.
                """,
                input: MCPSchema.object([
                    "steps": MCPSchema.integer("How many edits to undo (default 1).", minimum: 1, maximum: 50),
                    "round": MCPSchema.boolean("Undo this whole round of AI edits."),
                    "version": MCPSchema.string("A saved version's id (v3); get_status lists them.")
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
