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
                Read-only. Call it first: the project (name, path, length, unsaved), open projects with ids and owners, folders, jobs, screen \
                recording state, permission and leftovers, and cloud_tasks grouped by project: closed ones too. models=true: Sky Studio models, \
                prices, limits (free); screen=true: recording sources; film_contract=true: the film contract.
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
                How the user follows your edits: visible (default) brings a project's window forward once and shows each edit; background leaves \
                SkyCut where it is (edits still land and undo). With project, only that one; without, all yours. Ask the user once per \
                conversation which they want, unless they said. Lasts until SkyCut quits.
                """,
                input: MCPSchema.object([
                    "mode": MCPSchema.string("How the user follows your edits.", oneOf: ["visible", "background"])
                ], required: ["mode"])
            )
        case .openFolder:
            return MCPToolDefinition(
                .openFolder, title: "Open a media folder",
                description: """
                Read-only. Use a folder the user named as the workspace: lists its videos, images, audio and subtitle files (with \
                duration and size) in every subfolder; files in it import without asking again, and new files go to its SkyCut \
                subfolder. Only pass a folder the user gave you; from_finder=true uses their Finder selection.
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
                Open a SkyCut project file (.skycut, or .srtflowproj from before the rename); the result's project is its id (p1, \
                p2…). To edit several, open them all, then pass project=<id> on every call; without project a call goes to the one you \
                opened last. A file already open is not opened twice. At most 8 projects stay open: close_project finished ones.
                """,
                input: MCPSchema.object([
                    "path": MCPSchema.string("Absolute path of the project file (.skycut or .srtflowproj).")
                ], required: ["path"])
            )
        case .newProject:
            return MCPToolDefinition(
                .newProject, title: "New project",
                description: """
                Start a new, empty project, saved at once as <name>.skycut so later edits autosave: in folder, else in SkyCut/Projects \
                of the opened folder, the open project's folder or Downloads. A taken name gets a number. A second project in the same \
                folder needs version (<name> - <version>). The result's project is its id; it opens like open_project.
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
                Close one of your projects (project=p2) when you are done, for example after its export finished; it is saved first. \
                At most 8 projects stay open. Refused while one of its jobs runs (export, subtitles, translation): wait with get_job \
                or use cancel_job first.
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
                Undo the latest edits, like Command-Z (steps, default 1). round=true puts the project back to how it was before this \
                round of AI edits began, itself one undo step. File moves by manage_files are not undone.
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
                    Read-only for the project: move SkyCut's playhead to a timeline time so the user sees that frame in the preview.
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
