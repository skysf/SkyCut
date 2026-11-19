import Foundation

// MARK: - 工具清单：花钱的两个工具（generate_media 生成素材，方案第六块；upscale_clip 放大片段，2026-10-02）
//
// 管什么：这两个工具的说明文字和参数。2026-10-28 起都送 Sky Studio、花积分（收费方案第 6 刀；之前 generate_media 送 fal、花美元），
// **始终列出，调用时才核对 Key / 授权 / 积分**（2026-10-30，替代方案第 36 条的隐藏）。种类、upscale 的档位 / 目标 / 范围
// 走词表（MCPVocabulary，和 App 的类型对账）；画幅、分辨率不走词表，照 /models 的目录（Catalog aspect / tier，get_status models=true）；
// upscale 做完直接换源（用户 2026-10-02 定）。
// 不管什么：怎么调 Sky Studio、花积分怎么把关（App 里的 Sources/SrtFlow/SkyStudio/：每日预算硬上限、草稿越档按权限审批）；配旁白（add_voiceover，
// 有 Sky Studio 的 Key 时优先用云端声音，见 docs/architecture/sky-studio-jobs.md）。

enum MCPGenerationTools {
    static func definition(for name: MCPToolName) -> MCPToolDefinition {
        switch name {
        case .generateMedia:
            return MCPToolDefinition(
                .generateMedia, title: "Generate media",
                description: """
                Paid (Sky Studio credits): images, video, lipsync, cutouts, music, sound effects; import with add_clips (video upscale: \
                upscale_clip). job_id: wait with get_job. quote_only=true is free. Beyond the draft: needs_confirmation, ask, repeat with \
                confirm_token. user_requested_overrides needs user_request naming it in the user's words (4K, a model), never \"best quality\". A \
                daily credit limit applies. Read skycut_guide topic=generate_media first.
                """,
                input: MCPSchema.object([
                    "kind": MCPSchema.string("What to make.", oneOf: MCPVocabulary.generationKinds),
                    "prepare_references": MCPSchema.boolean("Official film: only prepare references."),
                    "prepared_references": MCPSchema.string("Official film: the preparation's token."),
                    "film": MCPSchema.object([:], description: "Original-film schema: get_status film_contract=true."),
                    "quote_token": MCPSchema.string("Official token; submit unchanged with seam_review."),
                    "seam_review": MCPFilmSchema.review,
                    "prompt": MCPSchema.string("Generators only."),
                    "operation": MCPSchema.string("Image job; default generate.", oneOf: ["generate", "remove_background", "camera_angle", "upscale"]),
                    "camera_angle": MCPSchema.object([
                        "rotate": ["type": "integer", "enum": [-180, -135, -90, -45, 0, 45, 90, 135, 180]],
                        "tilt": ["type": "integer", "enum": [-45, 0, 45]],
                        "zoom": ["type": "integer", "enum": [-1, 0, 1, 2]]
                    ], description: "Rotate/tilt in degrees, zoom in steps."),
                    "upscale_factor": MCPSchema.string("Image upscale; default x2.", oneOf: ["x2", "x3", "x4"]),
                    "idempotency_key": MCPSchema.string("Stable 1-128 chars; reuse on retry."),
                    "video": MCPSchema.string("Local lipsync video; catalog formats."),
                    "audio": MCPSchema.string("Local lipsync MP3/WAV."),
                    "document": MCPSchema.string("Wan: local document, exclusive with web_url."),
                    "web_url": MCPSchema.string("Wan: public HTTP(S) page, exclusive with document."),
                    "model": MCPSchema.string("Public model id."),
                    "character_id": MCPSchema.string("Character id (list_characters), not a file."),
                    "character_roles": MCPSchema.array(of: MCPSchema.string("View.", oneOf: ["front", "headshot", "side", "back"]), "Character views; default: server picks."),
                    "character_revision": MCPSchema.string("From the quote, unchanged."),
                    "image_context": MCPSchema.string("Subject; mixed/unclear defaults other.", oneOf: ["asian", "other"]),
                    "quality": MCPSchema.string("Video quality; highest requires unrestricted request.", oneOf: ["standard", "highest"]),
                    "input_mode": MCPSchema.string("Video mode; default inferred.", oneOf: ["frames", "multimodal"]),
                    "image": MCPSchema.string("Local image: first frame, reference, portrait, or the camera_angle/upscale source."),
                    "last_image": MCPSchema.string("Optional final frame with image (frames mode)."),
                    "reference_images": MCPSchema.array(of: MCPSchema.string("Image file path."), "Ordered image references."),
                    "reference_videos": MCPSchema.array(of: MCPSchema.string("MP4/MOV path."), "Ordered videos; catalog limits."),
                    "reference_audio": MCPSchema.array(of: MCPSchema.string("MP3/WAV path."), "Ordered audio; catalog limits."),
                    "auto_fallback": MCPSchema.boolean("Deprecated; false only."),
                    "duration": .object(["description": "Catalog seconds; null/auto: Wan, or music that picks its own length.",
                        "anyOf": .array([["type": "number"], ["type": "string", "enum": ["auto"]], ["type": "null"]])]),
                    "exact_length": MCPSchema.boolean("Music: duration must be exact (picks an exact-length model)."),
                    "title": MCPSchema.string("HeyGen label; catalog character limit."),
                    "enable_caption": MCPSchema.boolean("HeyGen; default false."),
                    "enable_dynamic_duration": MCPSchema.boolean("HeyGen; default false."),
                    "disable_music_track": MCPSchema.boolean("HeyGen: omit provider music, default false."),
                    "enable_speech_enhancement": MCPSchema.boolean("HeyGen; default false."),
                    "start_time": MCPSchema.number("HeyGen source seconds; default 0.", minimum: 0),
                    "end_time": MCPSchema.number("HeyGen: end in source seconds (≥ 0), after start_time.", minimum: 0),
                    "enable_transcription": MCPSchema.boolean("H3 Max: false waveform (default), true transcription."),
                    "enable_prompt_expansion": MCPSchema.boolean("Wan: true; required for document/page."),
                    "enable_thinking": MCPSchema.boolean("Wan: omitted is automatic; document/page requires true."),
                    "enable_safety_checker": MCPSchema.boolean("Default true; false needs provider authorization."),
                    "sync_mode": MCPSchema.boolean("Cutout: false default; async job/durable PNG."),
                    "seed": MCPSchema.number("Integer seed in catalog range."),
                    "resolution": MCPSchema.string("Catalog tier; default lowest. Upgrades need approval."),
                    "quote_only": MCPSchema.boolean("Price only: no upload or charge."),
                    "approval_scope": MCPSchema.string("Default once; project only on explicit approval.", oneOf: ["once", "project"]),
                    "user_requested_overrides": MCPSchema.boolean("true only if user_request names the setting."),
                    "user_request": MCPSchema.string("The user's own words naming it."),
                    "aspect_ratio": MCPSchema.string("Catalog aspect; default canvas."),
                    "generate_audio": MCPSchema.boolean("Older audio switch; prefer audio_mode."),
                    "audio_mode": MCPSchema.string("Video sound; default full. none only where the model lists it.", oneOf: MCPVocabulary.videoAudioModes),
                    "instrumental": MCPSchema.boolean("Music only: no singing (default true)."),
                    "lyrics": MCPSchema.string("Music words; requires instrumental=false."),
                    "name": MCPSchema.string("File name; default from the prompt or source."),
                    "confirm_token": MCPSchema.confirmToken
                ], required: ["kind"]),
                openWorld: true
            )
        case .upscaleClip:
            return MCPToolDefinition(
                .upscaleClip, title: "Upscale clip",
                description: """
                Paid (Sky Studio credits): upscale a video clip's source; when done it replaces every clip using that file (one undo step; \
                revert later). job_id: wait with get_job. Over-plan work returns needs_confirmation: ask, repeat with confirm_token. The daily \
                credit limit applies. At most 30 s and 30 fps per job. Images: generate_media operation=upscale. Read skycut_guide \
                topic=upscale_clip first.
                """,
                input: MCPSchema.object([
                    "clip_id": MCPSchema.string("Video clip whose source to upscale."),
                    "approval_scope": MCPSchema.string("Default once; project only on explicit approval.", oneOf: ["once", "project"]),
                    "user_requested_overrides": MCPSchema.boolean("true only if the user asked for it."),
                    "user_request": MCPSchema.string("The user's own words asking for it."),
                    "tier": MCPSchema.string("Model; default topaz-starlight.", oneOf: MCPVocabulary.upscaleTiers),
                    "target": MCPSchema.string("Short side to reach; default per canvas.", oneOf: MCPVocabulary.upscaleTargets),
                    "range": MCPSchema.string("How much of the file to send.", oneOf: MCPVocabulary.upscaleRanges),
                    "confirm_token": MCPSchema.confirmToken
                ], required: ["clip_id"]),
                openWorld: true
            )
        default:
            preconditionFailure("\(name) is not a generation tool")
        }
    }
}
