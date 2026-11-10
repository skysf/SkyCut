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
            "Write the Sky Studio character library: create from text/photo, import views, edit metadata, replace a view, regenerate headshot or delete. Read list_characters capabilities=true. Create/headshot are paid: quote_only, then shared approval/hard daily budget. Other writes are free; deletion follows permission mode. Keep idempotency_key; get_job recovers the original across restarts, never creates or charges again. Ready results return character_id, never timeline clips. Character jobs cannot be cancelled.",
            input: MCPSchema.object([
                "action": MCPSchema.string("One library mutation.", oneOf: ["create", "import", "update", "replace_view", "headshot", "delete"]),
                "character_id": MCPSchema.string("Existing full UUID for update/replace_view/headshot/delete."),
                "character_revision": MCPSchema.string("Latest server revision required for free edits/deletion; headshot uses the quote's revision."),
                "source_type": MCPSchema.string("Create only: default inferred from image. Text needs prompt and no media; photo needs one still image.", oneOf: ["text", "reference_upload"]),
                "prompt": MCPSchema.string("Create only; UTF-16 limit from capabilities. Photo prompt optional; no headshot prompt."),
                "image": MCPSchema.string("Local create photo or replacement view. JPEG/PNG/WebP, 30 MiB; create photo <=64M pixels. No remote URL."),
                "roles": MCPSchema.object([
                    "front": MCPSchema.string("Local front image path; required for import."),
                    "side": MCPSchema.string("Local side image path; required for import."),
                    "back": MCPSchema.string("Local back image path; required for import."),
                    "headshot": MCPSchema.string("Optional local headshot image path.")
                ], description: "Import separate existing views, not a source sheet; required roles come from capabilities."),
                "role": MCPSchema.string("replace_view only.", oneOf: ["front", "side", "back", "headshot"]),
                "name": MCPSchema.string("Import/update only; <=80 UTF-16 units. Create uses server's localized untitled name."),
                "voice_description": MCPSchema.string("Import/update only; <=220 UTF-16 units; empty clears it."),
                "notes": MCPSchema.string("Optional import notes, <=25000 UTF-16 units."),
                "locale": MCPSchema.string("Optional create/import/update metadata language."),
                "model": MCPSchema.string("Native Character id from capabilities; defaults from server/saved character."),
                "resolution": MCPSchema.string("Native Character tier; fixed source/headshot shapes, never pass aspect_ratio."),
                "quote_only": MCPSchema.boolean("Create/headshot/import quote: no upload, Character insertion, reservation or spending."),
                "idempotency_key": MCPSchema.string("Required for create/import/headshot/replace_view: stable 1-128 chars before sending; reuse unchanged after lost answers."),
                "resume": MCPSchema.string("Original stable job_id; pass only action and resume. Paid/role recovery is GET-only. Unknown free import explicitly recovers saved key/body without re-upload."),
                "approval_scope": MCPSchema.string("Default once; project requires explicit authorization for this exact Character operation.", oneOf: ["once", "project"]),
                "user_requested_overrides": MCPSchema.boolean("True only for explicit user requests; hard budgets still apply."),
                "confirm_token": MCPSchema.confirmToken
            ], required: ["action"]), destructive: true, openWorld: true)
    }
}
