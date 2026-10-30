import Foundation

// MARK: - 工具清单：花钱的两个工具（generate_media 生成素材，方案第六块；upscale_clip 放大片段，2026-10-02）
//
// 管什么：这两个工具的说明文字和参数。2026-10-28 起都送 Sky Studio、花积分（收费方案第 6 刀；之前 generate_media 送 fal、花美元），
// **始终列出，调用时才核对 Key / 授权 / 积分**（2026-10-30，替代方案第 36 条的隐藏）。种类、画幅、分辨率、upscale 的档位 / 目标 / 范围
// 走词表（MCPVocabulary，和 App 的类型对账）；upscale 做完直接换源（用户 2026-10-02 定）。
// 不管什么：怎么调 Sky Studio、花积分怎么把关（App 里的 Sources/SrtFlow/SkyStudio/：超了每日上限回确认码）；配旁白（add_voiceover，
// 有 Sky Studio 的 Key 时优先用云端声音，见 docs/architecture/sky-studio-jobs.md）。

enum MCPGenerationTools {
    static func definition(for name: MCPToolName) -> MCPToolDefinition {
        switch name {
        case .generateMedia:
            return MCPToolDefinition(
                .generateMedia, title: "Generate media",
                description: """
                Generates one image, video, music or sound effect with Sky Studio credits (paid; key required in SkyCut \
                Settings). Read get_status models=true (optionally model=<id>) BEFORE choosing references: it lists current \
                models, defaults and per-mode image/video/audio counts, formats, size, duration and combination limits. \
                Image: Asian people/places/culture prefer seedream5-flash; other, mixed or unclear subjects prefer nano2. \
                Judge the subject, not the prompt language; set image_context=asian when appropriate. Video prefers \
                MiniMax H3 (minimax-h3), then gemini-omni-1.1-flash, veo-fast, seedance-2-pro. Only when the user explicitly wants maximum \
                quality regardless of cost/time set quality=highest: seedance-2-5, then veo-pro. Explicit model overrides \
                preferences. image_to_video frames use image plus optional last_image; multimodal uses ordered reference_images, \
                reference_videos and reference_audio. Supported types and limits differ by model; keep every reference. \
                Seedance may refuse real or photoreal people. auto_fallback=true switches once to compatible MiniMax/Google \
                only after confirmed refusal and refund/no-charge proof, within the original approved price; never resubmit \
                an unknown or timed-out job. Returns job_id immediately: wait with get_job for phase, queue_position, \
                transfer_percent, phase_seconds and typical_seconds. Finished jobs have file and credits_charged; add_clips \
                puts the file on the timeline. Results also stay in the Sky Studio library. Aspect defaults to canvas; \
                frame video keeps the image shape. Music: Lyria 3 Pro, instrumental=true or false with lyrics; 60–180 s or \
                leave duration out. Sound effects: 0.5–180 s, default 5. Narration uses add_voiceover; subtitles use generate_subtitles. SkyCut quotes before \
                spending; above the daily credit limit it returns needs_confirmation and confirm_token: ask the user before \
                retrying with that token. cancel_job refunds queued jobs; started jobs cannot be cancelled.
                """,
                input: MCPSchema.object([
                    "kind": MCPSchema.string("What to make.", oneOf: MCPVocabulary.generationKinds),
                    "prompt": MCPSchema.string("What it should look / sound like."),
                    "model": MCPSchema.string("Exact model id from get_status models=true. Leave out to use the subject/quality preference among compatible models."),
                    "image_context": MCPSchema.string("Image subjects: asian for primarily Asian people, places or culture; other for non-Asian, mixed or unclear. Default other.", oneOf: ["asian", "other"]),
                    "quality": MCPSchema.string("Video: standard by default. highest only when the user explicitly prioritizes quality without cost/time limits.", oneOf: ["standard", "highest"]),
                    "input_mode": MCPSchema.string("Video: frames or multimodal. Inferred from reference arrays when omitted; inspect model limits first.", oneOf: ["frames", "multimodal"]),
                    "image": MCPSchema.string("First frame for image_to_video, or one reference for image generation; a file path."),
                    "last_image": MCPSchema.string("Optional final frame with image, in frames mode."),
                    "reference_images": MCPSchema.array(of: MCPSchema.string("Image file path."), "Ordered image references; image generation or multimodal video."),
                    "reference_videos": MCPSchema.array(of: MCPSchema.string("MP4/MOV file path."), "Ordered multimodal video references; model-specific count/length limits."),
                    "reference_audio": MCPSchema.array(of: MCPSchema.string("MP3/WAV file path."), "Ordered multimodal audio references; some models require a visual reference or do not accept audio."),
                    "auto_fallback": MCPSchema.boolean("Allow one compatible MiniMax/Google replacement after a refunded Seedance real-person refusal, within the original approved price. Default true."),
                    "duration": MCPSchema.number(
                        "Seconds. Video uses this model's exact duration choices/default; music 60–180 or automatic; effects 0.5–180, default 5.",
                        minimum: 0.5, maximum: 180
                    ),
                    "resolution": MCPSchema.string("Image/video output size from this model's mode-specific choices; default from /models."),
                    "aspect_ratio": MCPSchema.string("Image/text/multimodal video aspect from the model catalog; default nearest to canvas. Frame video follows the image."),
                    "generate_audio": MCPSchema.boolean("Video audio toggle, only when this model lists it. Other models may always generate sound."),
                    "instrumental": MCPSchema.boolean("Music only: no singing (default true)."),
                    "lyrics": MCPSchema.string("Music only, with instrumental=false: the words to sing."),
                    "name": MCPSchema.string("A short file name (default: made from the prompt)."),
                    "confirm_token": MCPSchema.confirmToken
                ], required: ["kind", "prompt"]),
                openWorld: true
            )
        case .upscaleClip:
            return MCPToolDefinition(
                .upscaleClip, title: "Upscale clip",
                description: """
                Sends one video clip's source file to Sky Studio for a sharper, larger version (paid with the user's Sky Studio \
                credits; requires a Sky Studio key in SkyCut Settings) and, when it is done, points every clip in this \
                project that uses that file at the new one (one undo step; the original file stays next to it and the user can \
                compare or revert from the clip's context menu). Use it when a clip's source_size (get_timeline) is below the \
                canvas or the export size: plain scaling adds no detail. It returns a job_id at once: wait with get_job, which \
                shows phase (preparing, uploading, queued, processing, downloading, finishing), queue_position, \
                transfer_percent, phase_seconds and typical_seconds. The finished job has replaced_ids, file, width, height and \
                credits_charged; the upscale is also kept in the user's Sky Studio library. tier: topaz-starlight (default; \
                re-draws fur, leaves, water; a few minutes; 1080p or 2160p only) or bytedance-upscaler-pro (large-model \
                restoration; about a minute per second of video). target: 1080p, 1440p or 2160p on the short side (default: \
                what the canvas needs); a source already at or above it is refused. range: clip (this clip's used part plus up \
                to 1 s handles each side), longest (default when another clip uses more of the same file: covers both), file \
                (the whole file). Sky Studio takes at most 30 s per upscale, handles included (split longer clips), and \
                sources up to 30 fps. Cost: the result's credits is Sky Studio's price; within the user's daily credit limit \
                SkyCut just starts; when a call would go over it, it returns needs_confirmation with a confirm_token instead: \
                ask the user and, only if they agree, call again with it. cancel_job refunds an upscale still in Sky Studio's \
                queue; once it has started it cannot be cancelled. Tell the user before upscaling many clips.
                """,
                input: MCPSchema.object([
                    "clip_id": MCPSchema.string("The video clip whose source file to upscale (get_timeline)."),
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
