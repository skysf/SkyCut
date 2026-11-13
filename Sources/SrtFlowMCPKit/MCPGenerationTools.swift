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
                    "prepare_references": MCPSchema.boolean("Official film: prepare and upload references only (no quote); wait with get_job."),
                    "prepared_references": MCPSchema.string("Official film: prepared-references token; void after account/project/file changes."),
                    "film": MCPSchema.object([:], description: "Original-film schema: get_status film_contract=true."),
                    "quote_token": MCPSchema.string("Official token; submit unchanged with seam_review."),
                    "seam_review": MCPFilmSchema.review,
                    "prompt": MCPSchema.string("Generators only; media operations omit it."),
                    "operation": MCPSchema.string("Image job: generate (default), remove_background, camera_angle, upscale; no film.", oneOf: ["generate", "remove_background", "camera_angle", "upscale"]),
                    "camera_angle": MCPSchema.object([
                        "rotate": ["type": "integer", "enum": [-180, -135, -90, -45, 0, 45, 90, 135, 180]],
                        "tilt": ["type": "integer", "enum": [-45, 0, 45]],
                        "zoom": ["type": "integer", "enum": [-1, 0, 1, 2]]
                    ], description: "Rotate / tilt degrees and zoom steps; omitted axes are 0, all zero is refused."),
                    "upscale_factor": MCPSchema.string("Image only, default x2. May be reduced: read actual result size.", oneOf: ["x2", "x3", "x4"]),
                    "idempotency_key": MCPSchema.string("Stable 1-128 chars; reuse unchanged after lost answers."),
                    "video": MCPSchema.string("Local lipsync video; catalog formats."),
                    "audio": MCPSchema.string("Local lipsync MP3/WAV; measured for quote."),
                    "document": MCPSchema.string("Wan: local document, exclusive with web_url."),
                    "web_url": MCPSchema.string("Wan: public HTTP(S) page, exclusive with document."),
                    "model": MCPSchema.string("Public id; default compatible preference."),
                    "character_id": MCPSchema.string("A Sky Studio character id (list_characters), not a file; image and video only."),
                    "character_roles": MCPSchema.array(of: MCPSchema.string("View.", oneOf: ["front", "headshot", "side", "back"]), "Optional character views; omitted lets the server choose."),
                    "character_revision": MCPSchema.string("Revision from the quote; pass it back unchanged."),
                    "image_context": MCPSchema.string("Subject; mixed/unclear defaults other.", oneOf: ["asian", "other"]),
                    "quality": MCPSchema.string("Video quality; highest requires unrestricted request.", oneOf: ["standard", "highest"]),
                    "input_mode": MCPSchema.string("Video mode; default inferred.", oneOf: ["frames", "multimodal"]),
                    "image": MCPSchema.string("Local image: first frame, reference, portrait, or the camera_angle/upscale source."),
                    "last_image": MCPSchema.string("Optional final frame with image (frames mode)."),
                    "reference_images": MCPSchema.array(of: MCPSchema.string("Image file path."), "Ordered image references."),
                    "reference_videos": MCPSchema.array(of: MCPSchema.string("MP4/MOV path."), "Ordered videos; catalog limits."),
                    "reference_audio": MCPSchema.array(of: MCPSchema.string("MP3/WAV path."), "Ordered audio; catalog limits."),
                    "auto_fallback": MCPSchema.boolean("Deprecated: false only; no automatic replacement."),
                    "duration": .object(["description": "Catalog seconds; Wan also null/auto.",
                        "anyOf": .array([["type": "number"], ["type": "string", "enum": ["auto"]], ["type": "null"]])]),
                    "title": MCPSchema.string("HeyGen label; catalog character limit."),
                    "enable_caption": MCPSchema.boolean("HeyGen: false default; captions/burn-in not guaranteed."),
                    "enable_dynamic_duration": MCPSchema.boolean("HeyGen: false; native length limits apply."),
                    "disable_music_track": MCPSchema.boolean("HeyGen: omit provider music, default false."),
                    "enable_speech_enhancement": MCPSchema.boolean("HeyGen speech enhancement; false default."),
                    "start_time": MCPSchema.number("HeyGen source seconds; default 0.", minimum: 0),
                    "end_time": MCPSchema.number("HeyGen: end in source seconds (≥ 0), after start_time.", minimum: 0),
                    "enable_transcription": MCPSchema.boolean("H3 Max: false waveform (default), true transcription."),
                    "enable_prompt_expansion": MCPSchema.boolean("Wan: true; required for document/page."),
                    "enable_thinking": MCPSchema.boolean("Wan: omitted is automatic; document/page requires true."),
                    "enable_safety_checker": MCPSchema.boolean("Safety toggle, true default; disabling needs provider authorization."),
                    "sync_mode": MCPSchema.boolean("Cutout: false default; async job/durable PNG."),
                    "seed": MCPSchema.number("Integer seed in catalog range."),
                    "resolution": MCPSchema.string("Catalog tier; default lowest image/720p-class video. Upgrades need approval."),
                    "quote_only": MCPSchema.boolean("Quote without upload, generation, reservation or charge."),
                    "approval_scope": MCPSchema.string("once default; project needs explicit spec/price-ceiling approval.", oneOf: ["once", "project"]),
                    "user_requested_overrides": MCPSchema.boolean("true only if user_request names the setting (4K, a model); not \"best quality\"."),
                    "user_request": MCPSchema.string("User's own words naming the setting, e.g. \"4K\" or \"use GPT Image 2\"."),
                    "aspect_ratio": MCPSchema.string("Catalog aspect; default canvas, frame video follows image."),
                    "generate_audio": MCPSchema.boolean("Video audio toggle, if offered."),
                    "instrumental": MCPSchema.boolean("Music only: no singing (default true)."),
                    "lyrics": MCPSchema.string("Music words; requires instrumental=false."),
                    "name": MCPSchema.string("File name (default from the prompt, or the source name plus the operation)."),
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
                    "clip_id": MCPSchema.string("The video clip whose source file to upscale (get_timeline)."),
                    "approval_scope": MCPSchema.string("once by default; project only with explicit project-wide agreement.", oneOf: ["once", "project"]),
                    "user_requested_overrides": MCPSchema.boolean("true only if the user asked for this paid upscale; quote them in user_request."),
                    "user_request": MCPSchema.string("User's own words asking for it, e.g. \"upscale this to 4K\"."),
                    "tier": MCPSchema.string("Which Sky Studio model (default topaz-starlight).", oneOf: MCPVocabulary.upscaleTiers),
                    "target": MCPSchema.string("Short side to reach (default: what the canvas needs).", oneOf: MCPVocabulary.upscaleTargets),
                    "range": MCPSchema.string(
                        "How much to send (default: the longest span other clips use, else this clip).", oneOf: MCPVocabulary.upscaleRanges
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
