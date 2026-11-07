import Foundation

// Sky Studio 角色库清单：读和写分开，角色生成不增加另一套媒体生成入口。
enum MCPCharacterTools {
    static func definition(for name: MCPToolName) -> MCPToolDefinition {
        switch name {
        case .listCharacters:
            return MCPToolDefinition(name, title: "List characters", description:
                "Read the current Sky Studio account's reusable characters for generate_media. Free, read-only; no uploads, reservation or generation. Default status=ready, limit=50; pass next_cursor as cursor for the next page. Use get_character for available views and revision.",
                input: MCPSchema.object([
                    "limit": MCPSchema.integer("Page size; default 50.", minimum: 1, maximum: 100),
                    "cursor": MCPSchema.string("Opaque next_cursor UUID from the preceding page."),
                    "status": MCPSchema.string("Default ready.", oneOf: ["ready", "draft", "generating", "failed", "all"])
                ]), readOnly: true, openWorld: true)
        case .getCharacter:
            return MCPToolDefinition(name, title: "Get character", description:
                "Read one Sky Studio character, available front/headshot/side/back views and its opaque revision. Free and read-only; another account's id is not_found. Use character_id with generate_media; server resolves its views without downloading/re-uploading them. After replacing a view, refresh and requote: old revisions and approvals cannot authorize changed images.",
                input: MCPSchema.object([
                    "character_id": MCPSchema.string("Full character UUID from list_characters or a Character job.")
                ], required: ["character_id"]), readOnly: true, openWorld: true)
        default: preconditionFailure("Not a character tool")
        }
    }
}
