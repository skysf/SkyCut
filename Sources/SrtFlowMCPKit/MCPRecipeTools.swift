import Foundation

// MARK: - 工具清单：剪辑风格
//
// 管什么：recipes（只读：列出每套和「什么时候用」、按名字回全文）和 save_recipe（写：存用户自己的一套）的说明文字和参数。
// 两个挨着的用途按第 33 条拆成一个只读、一个会写，说明里写清彼此的区别。
// 不管什么：剪辑风格的内容（App 资源里的 recipe-*.md）、怎么读写（App 里的 AIRecipeTools / AIRecipeStore）。
// 产品决定见 docs/plans/2026-09-27-mcp.md 第 39–41 条：剪辑风格由 AI 自己挑，不做斜杠命令。

enum MCPRecipeTools {
    static func definition(for name: MCPToolName) -> MCPToolDefinition {
        switch name {
        case .recipes:
            return MCPToolDefinition(
                .recipes, title: "Read editing styles",
                description: """
                Read-only. SkyCut's editing styles (presets and the user's own): structure, shot lengths, transitions, filters, fonts, music, \
                checklist. No id: every style and when to use it; id: the whole style. Before cutting a whole video, pick one that fits, tell \
                the user in one sentence which one you follow, and follow it; the user's words win.
                """,
                input: MCPSchema.object([
                    "id": MCPSchema.string("A style's id or title; leave out to list them all.")
                ]),
                readOnly: true
            )
        case .saveRecipe:
            return MCPToolDefinition(
                .saveRecipe, title: "Save an editing style",
                description: """
                Save an editing style of the user's own, only when they ask. text is the whole style in Markdown, written like the \
                preset ones (read one with recipes first). Saving under one of their names replaces it (the old file goes to the \
                Trash); a preset's name makes their own version. Styles live in SkyCut's folder, not in the project.
                """,
                input: MCPSchema.object([
                    "name": MCPSchema.string("The style's name, e.g. \"Course promo\"."),
                    "use_for": MCPSchema.string("One sentence: when to use this style."),
                    "text": MCPSchema.string("The whole style in Markdown.")
                ], required: ["name", "use_for", "text"]),
                destructive: true
            )
        default:
            preconditionFailure("\(name) is not a recipe tool")
        }
    }
}
