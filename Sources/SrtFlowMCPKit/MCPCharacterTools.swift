import Foundation

// Sky Studio 角色库清单：读和写分开，角色生成不增加另一套媒体生成入口。
enum MCPCharacterTools {
    static func definition(for name: MCPToolName) -> MCPToolDefinition {
        switch name {
        case .listCharacters:
            return MCPToolDefinition(name, title: "List characters", description:
                """
                Read-only and free. List Sky Studio characters as compact summaries, each at most 1 KiB with no image URLs; \
                get_character gives the full details. Pass next_cursor as cursor. capabilities=true adds the character models, limits \
                and prices.
                """,
                input: MCPSchema.object([
                    "limit": MCPSchema.integer("Page size; default 50.", minimum: 1, maximum: 100),
                    "cursor": MCPSchema.string("next_cursor of the previous page."),
                    "status": MCPSchema.string("Default ready.", oneOf: ["ready", "draft", "generating", "failed", "all"]),
                    "capabilities": MCPSchema.boolean("Also character capabilities.")
                ]), readOnly: true, openWorld: true)
        case .getCharacter:
            return MCPToolDefinition(name, title: "Get character", description:
                """
                Read-only and free. One Sky Studio character's views and revision; pass character_id to generate_media to use it. \
                After a view changes, read it again and quote again: old revisions and approvals no longer apply.
                """,
                input: MCPSchema.object([
                    "character_id": MCPSchema.string("Full UUID (list_characters).")
                ], required: ["character_id"]), readOnly: true, openWorld: true)
        case .manageCharacters: return manage
        default: preconditionFailure("Not a character tool")
        }
    }

    private static var manage: MCPToolDefinition {
        MCPToolDefinition(.manageCharacters, title: "Manage characters", description:
            """
            Edit Sky Studio characters: create (text or photo), import views, update, replace_view, headshot, delete. create and \
            headshot: Paid (Sky Studio credits); quote_only prices first. Over-plan work or a delete \
            may return needs_confirmation: ask, repeat with confirm_token. The daily credit limit applies. job_id: wait with \
            get_job. Read skycut_guide topic=manage_characters first.
            """,
            input: MCPSchema.object([
                "action": MCPSchema.string("One library mutation.", oneOf: ["create", "import", "update", "replace_view", "headshot", "delete"]),
                "character_id": MCPSchema.string("Full UUID of an existing character."),
                "character_revision": MCPSchema.string("Latest revision; headshot: the quote's."),
                "source_type": MCPSchema.string("Default from image.", oneOf: ["text", "reference_upload"]),
                "prompt": MCPSchema.string("Create; optional with a photo."),
                "image": MCPSchema.string("Local photo or view; no URLs."),
                "roles": MCPSchema.object([
                    "front": MCPSchema.string("Required local image path."),
                    "side": MCPSchema.string("Required local image path."),
                    "back": MCPSchema.string("Required local image path."),
                    "headshot": MCPSchema.string("Optional local image path.")
                ], description: "Import: one image per view, not a sheet."),
                "role": MCPSchema.string("replace_view only.", oneOf: ["front", "side", "back", "headshot"]),
                "name": MCPSchema.string("<=80 UTF-16 units."),
                "voice_description": MCPSchema.string("<=220 UTF-16 units; empty clears it."),
                "notes": MCPSchema.string("<=25000 UTF-16 units."),
                "locale": MCPSchema.string("Metadata language."),
                "model": MCPSchema.string("Character model id (capabilities)."),
                "resolution": MCPSchema.string("Character tier (capabilities)."),
                "quote_only": MCPSchema.boolean("Price only: nothing uploaded or spent."),
                "idempotency_key": MCPSchema.string("1-128 chars; reuse on retry."),
                "resume": MCPSchema.string("Original job_id to recover; never charges."),
                "approval_scope": MCPSchema.string("Default once; project needs explicit approval.", oneOf: ["once", "project"]),
                "user_requested_overrides": MCPSchema.boolean("true only if the user asked for it."),
                "user_request": MCPSchema.string("The user's own words asking for it."),
                "confirm_token": MCPSchema.confirmToken
            ], required: ["action"]), destructive: true, openWorld: true)
    }
}
