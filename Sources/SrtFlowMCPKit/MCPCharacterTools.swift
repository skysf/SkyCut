import Foundation

// Sky Studio 角色库清单：读和写分开，角色生成不增加另一套媒体生成入口。
enum MCPCharacterTools {
    static func definition(for name: MCPToolName) -> MCPToolDefinition {
        switch name {
        case .listCharacters:
            return MCPToolDefinition(name, title: "List characters", description:
                """
                Read-only and free. List Sky Studio characters as compact summaries: id, name, status, revision, available_roles, \
                saved model and dates; each at most 1 KiB, no image URLs. get_character gives the full details. Pages of limit \
                (default 50); pass next_cursor as cursor. capabilities=true adds the character models, limits and prices.
                """,
                input: MCPSchema.object([
                    "limit": MCPSchema.integer("Page size; default 50.", minimum: 1, maximum: 100),
                    "cursor": MCPSchema.string("Opaque next_cursor UUID from the preceding page."),
                    "status": MCPSchema.string("Default ready.", oneOf: ["ready", "draft", "generating", "failed", "all"]),
                    "capabilities": MCPSchema.boolean("Also read native Character capabilities; no writes.")
                ]), readOnly: true, openWorld: true)
        case .getCharacter:
            return MCPToolDefinition(name, title: "Get character", description:
                """
                Read-only and free. One Sky Studio character: its front, headshot, side and back views and its revision. Pass \
                character_id to generate_media to use it; Sky Studio uses the views directly. After a view changes, read it again and \
                quote again: old revisions and approvals no longer apply.
                """,
                input: MCPSchema.object([
                    "character_id": MCPSchema.string("Full character UUID from list_characters or a Character job.")
                ], required: ["character_id"]), readOnly: true, openWorld: true)
        case .manageCharacters: return manage
        default: preconditionFailure("Not a character tool")
        }
    }

    private static var manage: MCPToolDefinition {
        MCPToolDefinition(.manageCharacters, title: "Manage characters", description:
            """
            Edit the Sky Studio character library: create (text or photo), import views, rename, replace a view, regenerate the \
            headshot, delete. create and headshot: Paid (Sky Studio credits); quote_only prices first. Over-plan work or a delete \
            may return needs_confirmation: ask, repeat with confirm_token. The daily credit limit applies. job_id: wait with \
            get_job. Read skycut_guide topic=manage_characters first.
            """,
            input: MCPSchema.object([
                "action": MCPSchema.string("One library mutation.", oneOf: ["create", "import", "update", "replace_view", "headshot", "delete"]),
                "character_id": MCPSchema.string("Existing full UUID for update/replace_view/headshot/delete."),
                "character_revision": MCPSchema.string("Latest revision for free edits/deletion; headshot: the quote's revision."),
                "source_type": MCPSchema.string("Create only (default from image): text = prompt only; photo = one still image.", oneOf: ["text", "reference_upload"]),
                "prompt": MCPSchema.string("Create only (limit: capabilities); optional with a photo; not for headshot."),
                "image": MCPSchema.string("Local photo/view: JPEG, PNG or WebP, 30 MiB; create photo <=64M pixels; no URLs."),
                "roles": MCPSchema.object([
                    "front": MCPSchema.string("Local front image path; required for import."),
                    "side": MCPSchema.string("Local side image path; required for import."),
                    "back": MCPSchema.string("Local back image path; required for import."),
                    "headshot": MCPSchema.string("Optional local headshot image path.")
                ], description: "Import separate views, not a source sheet; required roles: capabilities."),
                "role": MCPSchema.string("replace_view only.", oneOf: ["front", "side", "back", "headshot"]),
                "name": MCPSchema.string("Import/update only; <=80 UTF-16 units. Create gets the server's untitled name."),
                "voice_description": MCPSchema.string("Import/update only; <=220 UTF-16 units; empty clears it."),
                "notes": MCPSchema.string("Optional import notes, <=25000 UTF-16 units."),
                "locale": MCPSchema.string("Optional create/import/update metadata language."),
                "model": MCPSchema.string("Native Character id from capabilities; defaults from server/saved character."),
                "resolution": MCPSchema.string("Native Character tier; fixed source/headshot shapes, never pass aspect_ratio."),
                "quote_only": MCPSchema.boolean("Create/headshot/import quote only: no upload, insertion, reservation or spending."),
                "idempotency_key": MCPSchema.string("For create/import/headshot/replace_view: 1-128 chars, reused after lost answers."),
                "resume": MCPSchema.string("Original job_id to recover (only action + resume); reads it, never charges."),
                "approval_scope": MCPSchema.string("Default once; project needs explicit approval for this exact Character operation.", oneOf: ["once", "project"]),
                "user_requested_overrides": MCPSchema.boolean("true only if the user asked for this paid change; quote them in user_request."),
                "user_request": MCPSchema.string("User's own words asking for it, e.g. \"make a character from this photo\"."),
                "confirm_token": MCPSchema.confirmToken
            ], required: ["action"]), destructive: true, openWorld: true)
    }
}
