import Foundation

// MARK: - 工具说明：文稿与文件（读文稿、整理文件）
//
// 管什么：这几样工具给 AI 看的说明文字和参数表。清单的总入口在 MCPToolCatalog.swift。

public enum MCPFileTools {
    static func definition(for name: MCPToolName) -> MCPToolDefinition {
        switch name {
        case .readDocument:
            return MCPToolDefinition(
                .readDocument, title: "Read a document",
                description: """
                Read-only. Read a user-provided PDF, Word, RTF, ODT, txt or md; excludes Pages/scans. Continue long text with from_char=next_from_char. Outside files may need needs_confirmation.
                """,
                input: MCPSchema.object([
                    "file": MCPSchema.string("Path of the document (absolute, or relative to the opened folder)."),
                    "from_char": MCPSchema.integer("Start at this character (default 0).", minimum: 0),
                    "max_chars": MCPSchema.integer("At most this many characters (default 20000).", minimum: 500, maximum: 100000),
                    "confirm_token": MCPSchema.confirmToken
                ], required: ["file"]),
                readOnly: true
            )
        case .manageFiles:
            return MCPToolDefinition(
                .manageFiles, title: "Organise files",
                description: """
                Only when asked, move, rename, make_folder or Trash within open_folder folders; never overwrite. Trash: needs_confirmation in ask mode; full_access proceeds and notifies. No undo.
                """,
                input: MCPSchema.object([
                    "action": MCPSchema.string("What to do.", oneOf: ["move", "rename", "make_folder", "trash"]),
                    "files": MCPSchema.array(of: MCPSchema.string("Path (absolute, or relative to the opened folder)."), "move / trash: the files or folders."),
                    "file": MCPSchema.string("rename: the file or folder to rename."),
                    "new_name": MCPSchema.string("rename: the new name, no folders (the extension stays if left out)."),
                    "to": MCPSchema.string("move: the destination folder (made if missing)."),
                    "path": MCPSchema.string("make_folder: the new folder."),
                    "confirm_token": MCPSchema.confirmToken
                ], required: ["action"]),
                destructive: true
            )
        default:
            preconditionFailure("\(name.rawValue) is described in another group")
        }
    }
}
