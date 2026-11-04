import Foundation

// MARK: - 工具清单：花钱的两个工具（generate_media 生成素材，方案第六块；upscale_clip 放大片段，2026-10-02）
//
// 管什么：这两个工具的说明文字和参数。2026-10-28 起都送 Sky Studio、花积分（收费方案第 6 刀；之前 generate_media 送 fal、花美元），
// **始终列出，调用时才核对 Key / 授权 / 积分**（2026-10-30，替代方案第 36 条的隐藏）。种类、画幅、分辨率、upscale 的档位 / 目标 / 范围
// 走词表（MCPVocabulary，和 App 的类型对账）；upscale 做完直接换源（用户 2026-10-02 定）。
// 不管什么：怎么调 Sky Studio、花积分怎么把关（App 里的 Sources/SrtFlow/SkyStudio/：每日预算硬上限、草稿越档按权限审批）；配旁白（add_voiceover，
// 有 Sky Studio 的 Key 时优先用云端声音，见 docs/architecture/sky-studio-jobs.md）。

enum MCPGenerationTools {
    static func definition(for name: MCPToolName) -> MCPToolDefinition {
        switch name {
        case .generateMedia:
            return MCPToolDefinition(
                .generateMedia, title: "Generate media",
                description: """
                Generate media, lipsync or cutouts with Sky Studio credits. Read get_status models=true for controls and limits. \
                Official film: get_status film_contract=true describes prepare/quote/review/submit in an owned saved project. \
                Stable idempotency_key required; expired/changed quotes need new review. \
                quote_only never uploads/reserves. Drafts: lowest image tier, 720p-class video. ask_for_approval upgrades return \
                needs_confirmation: ask then repeat with confirm_token. full_access proceeds/notifies; both obey the hard daily credit limit. \
                Use conversation-language notices. Image preferences: Seedream for Asian subjects, Nano 2 otherwise. Video: MiniMax H3, \
                Omni, Veo Fast, Seedance 2.0. quality=highest requires unrestricted quality. image_to_video uses image/last_image; multimodal \
                uses arrays. Lipsync omits prompt; cutouts use image operation=remove_background. Wait with get_job. Unknown/delivery \
                failures recover the original, never replay. Confirmed refunded terminal failures may start a new approved operation. \
                Successful output stays charged; only billing proves refunds. Results stay in the library; add_clips imports them. \
                Narration: add_voiceover; subtitles: generate_subtitles. cancel_job attempts queued cancellation. Preflight is not output acceptance.
                """,
                input: MCPSchema.object([
                    "kind": MCPSchema.string("What to make.", oneOf: MCPVocabulary.generationKinds),
                    "prepare_references": MCPSchema.boolean("Prepare render/upload images; omit film/quote_only/tokens. get_job returns render/assets. No quote/reservation."),
                    "prepared_references": MCPSchema.string("Local real-asset token; repeat exact image paths/roles. Account/project/file changes invalidate it."),
                    "film": MCPSchema.object([:], description: "Strict public original-film story; full schema: get_status film_contract=true."),
                    "quote_token": MCPSchema.string("Official quote token; unchanged submit plus explicit seam_review."),
                    "seam_review": MCPFilmSchema.review,
                    "prompt": MCPSchema.string("Required for generators; omit for lipsync/cutouts."),
                    "operation": MCPSchema.string("Image operation; matching model required.", oneOf: ["generate", "remove_background"]),
                    "idempotency_key": MCPSchema.string("Stable key, 1-128 chars; reuse unchanged after lost answers."),
                    "video": MCPSchema.string("Local lipsync video; catalog formats."),
                    "audio": MCPSchema.string("Local lipsync MP3/WAV; measured for quote."),
                    "document": MCPSchema.string("Wan: local document, exclusive with web_url."),
                    "web_url": MCPSchema.string("Wan: public HTTP(S) page, exclusive with document."),
                    "model": MCPSchema.string("Public model id; default compatible preference."),
                    "image_context": MCPSchema.string("Subject context; default other, including mixed/unclear.", oneOf: ["asian", "other"]),
                    "quality": MCPSchema.string("Video quality; highest requires unrestricted request.", oneOf: ["standard", "highest"]),
                    "input_mode": MCPSchema.string("Video mode; default inferred.", oneOf: ["frames", "multimodal"]),
                    "image": MCPSchema.string("Local first frame, image reference, lip-sync portrait or cutout input."),
                    "last_image": MCPSchema.string("Optional final frame with image, in frames mode."),
                    "reference_images": MCPSchema.array(of: MCPSchema.string("Image file path."), "Ordered image references."),
                    "reference_videos": MCPSchema.array(of: MCPSchema.string("MP4/MOV path."), "Ordered videos; catalog limits."),
                    "reference_audio": MCPSchema.array(of: MCPSchema.string("MP3/WAV path."), "Ordered audio; catalog limits."),
                    "auto_fallback": MCPSchema.boolean("Deprecated; false only. Automatic model replacement is disabled."),
                    "duration": .object(["description": "Catalog seconds; Wan also null/auto.",
                        "anyOf": .array([["type": "number"], ["type": "string", "enum": ["auto"]], ["type": "null"]])]),
                    "title": MCPSchema.string("HeyGen: optional label; catalog character limit."),
                    "enable_caption": MCPSchema.boolean("HeyGen: false default; captions/burn-in not guaranteed."),
                    "enable_dynamic_duration": MCPSchema.boolean("HeyGen: false; native length limits apply."),
                    "disable_music_track": MCPSchema.boolean("HeyGen: omit provider music, default false."),
                    "enable_speech_enhancement": MCPSchema.boolean("HeyGen: enhance speech, default false."),
                    "start_time": MCPSchema.number("HeyGen: processing start in source seconds; default beginning.", minimum: 0),
                    "end_time": MCPSchema.number("HeyGen: start < end <= source length; no billing discount.", minimum: 0),
                    "enable_transcription": MCPSchema.boolean("H3 Max: false default follows waveform; true uses transcription."),
                    "enable_prompt_expansion": MCPSchema.boolean("Wan: true; required for document/page."),
                    "enable_thinking": MCPSchema.boolean("Wan: omitted is automatic; document/page requires true."),
                    "enable_safety_checker": MCPSchema.boolean("Safety toggle, true default; disabling needs provider authorization."),
                    "sync_mode": MCPSchema.boolean("Cutout: false default; still returns async job/durable PNG."),
                    "seed": MCPSchema.number("Integer seed in catalog range."),
                    "resolution": MCPSchema.string("Default lowest image tier/720p-class video; upgrades follow approval mode."),
                    "quote_only": MCPSchema.boolean("true: validate and quote only, no uploads, generation, reservation or charge."),
                    "approval_scope": MCPSchema.string("Default once; project requires explicit approval of this spec and per-task ceiling.", oneOf: ["once", "project"]),
                    "user_requested_overrides": MCPSchema.boolean("true ONLY for the user's explicit exact overrides, never the assistant's plan. Budgets/settings confirmation still apply."),
                    "aspect_ratio": MCPSchema.string("Catalog aspect; default canvas, frame video follows image."),
                    "generate_audio": MCPSchema.boolean("Video audio toggle, only when offered by model."),
                    "instrumental": MCPSchema.boolean("Music only: no singing (default true)."),
                    "lyrics": MCPSchema.string("Music only, with instrumental=false: the words to sing."),
                    "name": MCPSchema.string("File name; default from prompt."),
                    "confirm_token": MCPSchema.confirmToken
                ], required: ["kind"]),
                openWorld: true
            )
        case .upscaleClip:
            return MCPToolDefinition(
                .upscaleClip, title: "Upscale clip",
                description: """
                Paid upscale of a video clip's source through Sky Studio; requires its key. Completion replaces every clip using \
                that file in this project (one undo); originals stay available to compare or revert. Use source_size below the canvas: \
                plain scaling adds no detail. Returns job_id: get_job reports phase, queue_position, transfer_percent, phase_seconds, \
                typical_seconds; completion gives replaced_ids, file, width, height, credits_charged. Results stay in the library. \
                Models: topaz-starlight (default; 1080p/2160p) or bytedance-upscaler-pro. Targets: 1080p, 1440p, 2160p short side. \
                range=clip adds up to 1s handles; longest covers other uses; file sends the whole source. At most 30 s including \
                handles, 30 fps. The daily credit limit is a hard cap in both modes: notify users to raise it in Settings. \
                Upscale exceeds draft settings: ask_for_approval returns needs_confirmation; ask then repeat with confirm_token. \
                full_access proceeds and notifies. cancel_job attempts queued cancellation; check original billing afterward.
                """,
                input: MCPSchema.object([
                    "clip_id": MCPSchema.string("The video clip whose source file to upscale (get_timeline)."),
                    "approval_scope": MCPSchema.string("once by default; project only with explicit project-wide agreement.", oneOf: ["once", "project"]),
                    "user_requested_overrides": MCPSchema.boolean("true only if the user explicitly requested this paid upscale; never infer from the assistant's plan."),
                    "tier": MCPSchema.string("Which Sky Studio model (default topaz-starlight).", oneOf: MCPVocabulary.upscaleTiers),
                    "target": MCPSchema.string("Short side to reach (default: what the canvas needs).", oneOf: MCPVocabulary.upscaleTargets),
                    "range": MCPSchema.string(
                        "How much of the file to send (default: longest when another clip uses more of it, else clip).", oneOf: MCPVocabulary.upscaleRanges
                    ),
                    "confirm_token": MCPSchema.confirmToken
                ], required: ["clip_id"]),
                openWorld: true
            )
        default:
            preconditionFailure("\(name) is not a generation tool")
        }
    }
}
