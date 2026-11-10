import Foundation

// MARK: - 说明书：花积分的 upscale_clip、manage_characters（第一批，2026-11-10）
//
// 管什么：两个花 Sky Studio 积分的工具名片写短之后的长话。
// 出处：迁移前的说明原文和参数说明（MCPGuidePreviousCards）、docs/architecture/video-upscale.md（范围带余料、一次最长 30 秒、
// 最高 30 fps、做完换源一步撤销、原片留着能换回）、sky-studio-jobs.md 第六、十三节（报价、确认、每日硬上限、只能取消排队中的、
// 原单恢复不重放收费请求、角色的 revision 和六种写入）、ai-control-mcp.md 第四节第 44 条。只写英文。
// 不管什么：参数一行一行的类型和范围（fields 自动生成）、五个工具共守的花钱规矩（通用主题 paid）。

enum MCPGuidePaidTopics {
    static let upscaleClip = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCards.upscaleClip,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCards.upscaleClip, """
            upscale_clip spends the user's Sky Studio credits on a sharper, larger copy of a clip's source file.
            """),
            MCPGuideSection(name: "choices", about: "models, targets, how much of the file to send, the 30 s and 30 fps limits", text: """
            Choices. tier is topaz-starlight (default; 1080p and 2160p) or bytedance-upscaler-pro. target is the short side to \
            reach: 1080p, 1440p or 2160p (default: what the canvas needs). Upscale only a source below the canvas (source_size): \
            plain scaling adds no detail. range=clip sends the clip's part with up to 1 s handles, longest also covers the other \
            clips that use the same file, file sends the whole source (default: longest when another clip uses more of it, else \
            clip). A job is at most 30 s including handles, at most 30 fps.
            """),
            MCPGuideSection(name: "spending", about: "price, approval, the daily limit and cancelling", text: """
            Spending. The upscale goes beyond the draft settings, so in ask_for_approval mode it returns needs_confirmation with \
            the price: ask the user, then repeat with confirm_token (approval_scope=project only with explicit project-wide \
            agreement). full_access proceeds and notifies. Set user_requested_overrides=true only when the user explicitly asked \
            for this paid upscale. The daily credit limit is a hard cap in both modes: if it blocks the job, tell the user they \
            can raise it in Settings. cancel_job can only cancel a queued job; check the original billing afterwards.
            """),
            MCPGuideSection(name: "results", about: "progress fields, replacing clips, reverting and the library", text: """
            Results. It returns job_id: get_job reports phase, queue_position, transfer_percent, phase_seconds and \
            typical_seconds; completion gives replaced_ids, file, width, height and credits_charged. When it finishes, every \
            clip using that file in this project switches to the upscaled file as one undo step; the original stays available \
            to compare or revert. Finished files also stay in the user's Sky Studio library.
            """)
        ],
        examples: [["clip_id": "c1", "target": "2160p"]],
        related: ["paid", "generate_media", "get_job", "cancel_job"],
        readingTip: "Before spending, read only section=spending."
    )

    static let manageCharacters = MCPGuideWrittenTopics.Written(
        previousCard: MCPGuidePreviousCards.manageCharacters,
        sections: [
            MCPGuideWrittenTopics.overview(MCPGuidePreviousCards.manageCharacters, """
            manage_characters writes the user's Sky Studio character library; list_characters and get_character read it.
            """),
            MCPGuideSection(name: "actions", about: "create, import, update, replace_view, headshot and delete", text: """
            Actions. action=create makes a character from text (source_type=text with prompt and no media) or a photo \
            (source_type=reference_upload with one still image; prompt optional); import adds separate existing views (roles \
            front, side and back, headshot optional; not one sheet) with name, notes and voice_description; update renames it or \
            edits notes and voice_description; replace_view swaps one role's image; headshot regenerates the headshot; delete \
            removes the character. Read list_characters capabilities=true first: it gives the models, limits and required roles.
            """),
            MCPGuideSection(name: "files_limits", about: "images, sizes and text limits", text: """
            Files and limits. image is a local JPEG, PNG or WebP up to 30 MiB (a create photo at most 64 megapixels); no remote \
            URLs. name is at most 80 UTF-16 units, notes 25000 and voice_description 220 (empty clears it); the prompt limit \
            comes from capabilities. model and resolution come from capabilities too; never pass aspect_ratio.
            """),
            MCPGuideSection(name: "spending", about: "which actions are paid, quotes, approval and the daily limit", text: """
            Spending. create and headshot are paid with Sky Studio credits: quote_only=true prices them without uploading, \
            creating, reserving or spending; then the shared approval rules and the hard daily budget apply (needs_confirmation, \
            confirm_token, approval_scope). Other writes are free; a delete follows the permission mode and may ask first. Set \
            user_requested_overrides=true only for the user's explicit request.
            """),
            MCPGuideSection(name: "jobs", about: "idempotency_key, revisions, recovering with resume, no cancelling", text: """
            Jobs and recovery. Give create, import, headshot and replace_view a stable idempotency_key (1–128 characters) and \
            reuse it unchanged after a lost answer. Free edits and deletes need the latest character_revision; headshot uses the \
            quote's revision. get_job, or resume with the original job_id, recovers the original across restarts and never \
            creates or charges again; an unknown free import is recovered from its saved request without uploading again. \
            Character jobs cannot be cancelled. Ready results return character_id, never timeline clips.
            """)
        ],
        examples: [
            ["action": "create", "source_type": "text", "prompt": "A friendly robot guide", "quote_only": true,
             "idempotency_key": "robot-guide-1"]
        ],
        related: ["list_characters", "get_character", "generate_media", "paid"],
        readingTip: "Before a paid create or headshot, read only section=spending."
    )
}
