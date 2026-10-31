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
                Generates media, lipsync or transparent cutouts with Sky Studio credits (key required). First read \
                get_status models=true for public ids, defaults, controls and input limits. lipsync: HeyGen takes video+audio; \
                H3 Max takes image+audio. image operation=remove_background takes one image, no prompt. HeyGen dynamic duration \
                defaults false; match input lengths. Results may be WebM with optional SRT; cutouts preserve PNG alpha. \
                Wan reference-to-video uses multimodal arrays, document or web_url. image_to_video uses image/last_image. \
                Images prefer Seedream for Asian subjects, Nano 2 otherwise; judge subject, not prompt language. Video prefers \
                MiniMax H3 then Omni, Veo Fast, Seedance 2.0. quality=highest only for explicitly unrestricted quality requests: \
                Seedance 2.5 then Veo Pro. Explicit model overrides preferences. Quotes before spending; above the daily credit limit \
                returns needs_confirmation: ask the user, then repeat with confirm_token. Reuse one idempotency_key per operation; \
                wait with get_job. Never automatically regenerate or switch models after failure/unknown status. Explain billing: \
                provider-successful results stay charged if downloading/saving/importing fails; only billing proves a refund. \
                Results stay in the Sky Studio library. add_clips imports actual media; WebM editing copies preserve originals. \
                Narration uses add_voiceover; subtitles use generate_subtitles. Music defaults instrumental/auto length; sound \
                effects default 5s. cancel_job attempts queued cancellation; check billing for settlement.
                """,
                input: MCPSchema.object([
                    "kind": MCPSchema.string("What to make.", oneOf: MCPVocabulary.generationKinds),
                    "prompt": MCPSchema.string("Required for generators; omit for lipsync/cutouts."),
                    "operation": MCPSchema.string("Image: generate (default) or remove_background; choose a matching catalog model.", oneOf: ["generate", "remove_background"]),
                    "idempotency_key": MCPSchema.string("Stable operation key, 1-128 characters. Reuse after lost answers; bind unchanged inputs."),
                    "video": MCPSchema.string("Local source video for lipsync; HeyGen accepts MP4/WebM per catalog."),
                    "audio": MCPSchema.string("Local replacement MP3/WAV for lipsync; measured duration is used for /quote."),
                    "document": MCPSchema.string("Wan: local document, exclusive with web_url."),
                    "web_url": MCPSchema.string("Wan: public HTTP(S) page, exclusive with document."),
                    "model": MCPSchema.string("Public id from get_status models=true; omitted uses compatible preferences."),
                    "image_context": MCPSchema.string("Image subject context; default other (mixed/unclear included).", oneOf: ["asian", "other"]),
                    "quality": MCPSchema.string("Video: standard default; highest only for explicitly unrestricted quality.", oneOf: ["standard", "highest"]),
                    "input_mode": MCPSchema.string("Video input mode; inferred from references when omitted.", oneOf: ["frames", "multimodal"]),
                    "image": MCPSchema.string("Local first frame, image reference, lip-sync portrait or cutout input."),
                    "last_image": MCPSchema.string("Optional final frame with image, in frames mode."),
                    "reference_images": MCPSchema.array(of: MCPSchema.string("Image file path."), "Ordered image references."),
                    "reference_videos": MCPSchema.array(of: MCPSchema.string("MP4/MOV file path."), "Ordered video references; limits from catalog."),
                    "reference_audio": MCPSchema.array(of: MCPSchema.string("MP3/WAV file path."), "Ordered audio references; compatibility from catalog."),
                    "auto_fallback": MCPSchema.boolean("Deprecated; false only. Automatic model replacement is disabled."),
                    "duration": .object(["description": "Seconds from the model catalog; Wan also accepts null or auto for smart duration.",
                        "anyOf": .array([["type": "number"], ["type": "string", "enum": ["auto"]], ["type": "null"]])]),
                    "title": MCPSchema.string("HeyGen: optional label; catalog character limit."),
                    "enable_caption": MCPSchema.boolean("HeyGen: default false; provider may still return captions, no guaranteed burn-in."),
                    "enable_dynamic_duration": MCPSchema.boolean("HeyGen: false default; native length checks still apply."),
                    "disable_music_track": MCPSchema.boolean("HeyGen: omit provider music, default false."),
                    "enable_speech_enhancement": MCPSchema.boolean("HeyGen: enhance speech, default false."),
                    "start_time": MCPSchema.number("HeyGen: processing start in source seconds; default beginning.", minimum: 0),
                    "end_time": MCPSchema.number("HeyGen: end > start, within source; no promised billing discount.", minimum: 0),
                    "enable_transcription": MCPSchema.boolean("H3 Max: false default follows waveform; true uses transcription."),
                    "enable_prompt_expansion": MCPSchema.boolean("Wan: default true; required for document/page."),
                    "enable_thinking": MCPSchema.boolean("Wan: omitted is automatic; document/page requires true."),
                    "enable_safety_checker": MCPSchema.boolean("Safety toggle, true default; disabling needs provider authorization."),
                    "sync_mode": MCPSchema.boolean("Cutout: false default; still returns async job/durable PNG."),
                    "seed": MCPSchema.number("Optional integer random seed within the model catalog range."),
                    "resolution": MCPSchema.string("Output size; catalog choices/default."),
                    "aspect_ratio": MCPSchema.string("Catalog aspect; default canvas, frame video follows image."),
                    "generate_audio": MCPSchema.boolean("Video audio toggle, only when offered by model."),
                    "instrumental": MCPSchema.boolean("Music only: no singing (default true)."),
                    "lyrics": MCPSchema.string("Music only, with instrumental=false: the words to sing."),
                    "name": MCPSchema.string("A short file name (default: made from the prompt)."),
                    "confirm_token": MCPSchema.confirmToken
                ], required: ["kind"]),
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
