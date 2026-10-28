import Foundation

// MARK: - 工具清单：花钱的两个工具（generate_media 生成素材，方案第六块；upscale_clip 放大片段，2026-10-02）
//
// 管什么：这两个工具的说明文字和参数。2026-10-28 起都送 Sky Studio、花积分（收费方案第 6 刀；之前 generate_media 送 fal、花美元），
// **只在用户存了 Sky Studio 的 Key 时才列出来**（`MCPToolName.provider`，方案第 36 条）。种类、画幅、分辨率、upscale 的档位 / 目标 / 范围
// 走词表（MCPVocabulary，和 App 的类型对账）；upscale 做完直接换源（用户 2026-10-02 定）。
// 不管什么：怎么调 Sky Studio、花积分怎么把关（App 里的 Sources/SrtFlow/SkyStudio/：超了每日上限回确认码）；配旁白（add_voiceover，
// 有 fal 的 Key 时它优先用 fal 的声音，见 docs/architecture/fal-generation.md）。

enum MCPGenerationTools {
    static func definition(for name: MCPToolName) -> MCPToolDefinition {
        switch name {
        case .generateMedia:
            return MCPToolDefinition(
                .generateMedia, title: "Generate media",
                description: """
                Makes a new image, video clip, music or sound effect with the user's Sky Studio credits (paid; listed only \
                because the user added a Sky Studio key). Not for subtitles (generate_subtitles), narration (add_voiceover), \
                effects add_clips sound_effect can make, or footage the user already has. One result per call. It returns a \
                job_id at once: wait with get_job (an image takes about 15 s, a sound effect 10 s, music about a minute, a \
                video a few minutes); while it runs get_job shows phase (uploading, queued, processing, downloading), \
                queue_position, transfer_percent, phase_seconds and typical_seconds. The finished job has file (a path in the \
                user's SkyCut folder; put it on the timeline with add_clips) and credits_charged; it also stays in the user's \
                Sky Studio library. kind: image | text_to_video | image_to_video | music | sound_effect. Image: Seedream 5 \
                Flash; aspect_ratio (default: the project's canvas). Video: MiniMax H3, 5–15 s per clip with sound built in; \
                resolution 480p (cheaper, for drafts) or 768p (default); text_to_video takes aspect_ratio (21:9, 16:9, 4:3, \
                1:1, 3:4 or 9:16; default: the canvas); image_to_video takes image (the first frame) and keeps its shape. \
                Music: Lyria 3 Pro; instrumental (default true), or instrumental=false with lyrics; duration 60–180 s, or \
                leave it out and the model decides. Sound effect: 0.5–180 s (default 5; under 3 s costs as 3 s). Write \
                prompts like a director: subject, action, camera, light, style; for music, style, mood and instruments. Cost: \
                the result's credits is Sky Studio's price; within the user's daily credit limit SkyCut just starts; when a \
                call would go over it, it returns needs_confirmation with a confirm_token instead: ask the user and, only if \
                they agree, call again with it. cancel_job refunds a job still in Sky Studio's queue; once it has started it \
                cannot be cancelled. Tell the user before you make several expensive clips.
                """,
                input: MCPSchema.object([
                    "kind": MCPSchema.string("What to make.", oneOf: MCPVocabulary.generationKinds),
                    "prompt": MCPSchema.string("What it should look / sound like."),
                    "image": MCPSchema.string("image_to_video: the picture file to start from (a path in the user's folder)."),
                    "duration": MCPSchema.number(
                        "Seconds. Video 5–15 (default 5), music 60–180 (default: the model decides), sound effect 0.5–180 (default 5).",
                        minimum: 0.5, maximum: 180
                    ),
                    "resolution": MCPSchema.string("Video only (default 768p).", oneOf: MCPVocabulary.videoResolutions),
                    "aspect_ratio": MCPSchema.string(
                        "Image and text_to_video (default: the canvas of the project). Video takes 21:9, 16:9, 4:3, 1:1, 3:4 or 9:16.",
                        oneOf: MCPVocabulary.generationAspects
                    ),
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
                credits; listed only because the user added a Sky Studio key) and, when it is done, points every clip in this \
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
