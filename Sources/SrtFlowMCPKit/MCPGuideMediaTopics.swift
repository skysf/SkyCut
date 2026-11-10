import Foundation

// MARK: - 说明书：generate_media、look 的主题（试点，2026-11-10）
//
// 管什么：两个工具名片写短之后的长话。generate_media：做什么、输入、花钱和确认、任务和成品、官方原创短片、坑；look：看时间线和文件、
// 分镜头、扫画面里的字、一次看几个文件、坑。
// 出处：docs/architecture/sky-studio-jobs.md（报价、任务、只能取消排队中的、成品在作品库、不重放）、ai-control-mcp.md 第四节第 6 条
// （草稿越档在请求批准模式下要点头、每日硬上限不发越额码）、第 39、44、56 条，docs/architecture/official-film.md；
// ai-control-mcp.md 第四节第 12、29–31、37、38 条（look、分镜头、看几个文件、扫画面里的字、盖一块的框），
// docs/bugfixes/2026-10-14-ai-thinks-export-is-720p.md、2026-10-14-ai-tool-small-issues-from-blind-test.md（读不了的 hev1）。只写英文。
// 不管什么：参数一行一行的类型和范围（fields 自动生成）。

enum MCPGuideMediaTopics {
    // MARK: generate_media

    static let generateMediaPreviousCard = "Generate with Sky Studio credits; wait with get_job; import via add_clips. get_status models=true lists limits. "
        + "kind=image: camera_angle changes viewpoint with one image and camera_angle controls; upscale enlarges one image via upscale_factor. "
        + "Video clips use upscale_clip. Both omit prompt; upscale also omits resolution/aspect_ratio. quote_only never uploads/reserves. "
        + "Both modes obey the hard daily credit limit. ask_for_approval upgrades need needs_confirmation: ask, then repeat with confirm_token. "
        + "full_access proceeds/notifies. image_to_video uses image/last_image; multimodal uses reference arrays. Official film: get_status "
        + "film_contract=true for assets, stable idempotency_key and fresh seam review. Video default: MiniMax H3. Lipsync/cutouts omit prompt. "
        + "Unknown/delivery errors: recover original, never replay. Refunds need billing proof; success stays charged in the library. "
        + "cancel_job: queued cancellation. Narration: add_voiceover; subtitles: generate_subtitles."

    static let generateMedia = MCPGuideWrittenTopics.Written(
        previousCard: generateMediaPreviousCard,
        sections: [
            MCPGuideWrittenTopics.overview(generateMediaPreviousCard, """
            generate_media spends the user's Sky Studio credits to make new media files; it never changes the timeline. Read topic=paid for \
            the shared spending rules.
            """),
            MCPGuideSection(name: "kinds", text: """
            What it makes. kind is image, image_to_video, text_to_video, music, sound_effect or lipsync. With kind=image, operation picks \
            the job: generate (default), remove_background (a cutout with transparency), camera_angle (a new viewpoint of one image with \
            the qwen-angles model: camera_angle {rotate, tilt, zoom}, omitted axes are 0 and all zero is refused; a rotation of 135 or \
            -135 degrees runs as two steps on Sky Studio and its price comes only from the quote) or upscale (one image enlarged by \
            upscale_factor x2, x3 or x4 with the image-upscale model; the model may reduce the factor, so read the result's size). Both \
            take one image or one reference_images entry, no prompt, and never film. Video clips already on the timeline are upscaled with \
            upscale_clip instead. The default video model is MiniMax H3. get_status models=true lists the current models with prices, \
            defaults and reference limits for free; model picks one by its public id, otherwise SkyCut picks a compatible low-cost \
            default. Narration is add_voiceover and subtitles are generate_subtitles, not this tool.
            """),
            MCPGuideSection(name: "inputs", text: """
            Inputs. prompt drives the generators; camera_angle, upscale, remove_background and lipsync take no prompt. image_to_video uses \
            image as the first frame and optional last_image (frames mode); input_mode=multimodal uses the reference_images, \
            reference_videos and reference_audio lists within the model's limits. lipsync takes a local video and audio (MP3 or WAV). \
            character_id uses a Sky Studio character (list_characters; an id, never a file path) for images and videos. character_roles \
            picks views: without it the server chooses within the combined reference limits, and roles you name are never dropped. A quote \
            returns character_revision, which goes back unchanged; if the character's views change, read it again with get_character and \
            quote again (an old confirm_token no longer works). aspect_ratio defaults to the canvas; resolution defaults to the lowest \
            image or 720p-class video tier; duration follows the model's catalog. Music is instrumental by default; lyrics need \
            instrumental=false. Some fields belong to one model family (HeyGen: title, enable_caption, start_time, end_time and others; \
            Wan: document, web_url, enable_thinking, enable_prompt_expansion). HeyGen's end_time must be after start_time and within the \
            source; a shorter window does not lower the price.
            """),
            MCPGuideSection(name: "spending", text: """
            Spending. quote_only=true returns the exact price and the approval reasons without uploading, reserving or charging. The \
            low-cost draft (default model and settings) goes ahead in both permission modes. In ask_for_approval mode, going beyond the \
            draft (a higher resolution, a longer duration, quality=highest, a pricier model) returns needs_confirmation with the price and \
            the reason: ask the user, and only if they agree repeat the same call with confirm_token (approval_scope=project approves that \
            model and specification for the project up to that price). Set user_requested_overrides=true only when the user explicitly \
            asked for that specification themselves, never for your own choice. The daily hard credit limit applies in every mode: over \
            it nothing starts (daily_budget_exceeded); tell the user. Keep the same idempotency_key when retrying after a lost answer.
            """),
            MCPGuideSection(name: "jobs_results", text: """
            Jobs and results. The call returns job_id; wait with get_job, which reports the phase, queue position and credits_charged. \
            Finished files land in the project's SkyCut folder and never change the timeline: add them with \
            add_clips. Only queued jobs can be cancelled with cancel_job; started jobs finish, are charged and stay in the user's Sky \
            Studio library. Refunds need billing proof. After an unknown or delivery error, recover the original job with get_job; never \
            send the same paid request again. name sets the file name; by default it comes from the prompt, or for an image operation \
            from the source name plus angle, x2, x3 or x4. A clashing name gets a number.
            """),
            MCPGuideSection(name: "official_film", text: """
            Official original film. film, prepare_references, prepared_references, quote_token and seam_review belong to the official \
            original-film flow: read get_status film_contract=true first for the shot, context and sound contract and its steps. \
            prepare_references=true only prepares and uploads the references (no quote, no reservation; leave out film, quote_only and \
            the tokens) and returns a job: wait with get_job. Then pass its token as prepared_references and repeat the same paths and \
            roles; the token stops working after an account, project or file change. Keep a stable idempotency_key per shot and do a \
            fresh seam_review before each submission.
            """)
        ],
        examples: [
            ["kind": "image", "prompt": "A product photo on a white table", "quote_only": true],
            ["kind": "image", "operation": "camera_angle", "image": "photo.png", "camera_angle": ["rotate": 45]]
        ],
        related: ["paid", "upscale_clip", "add_clips", "get_job"]
    )

    // MARK: look

    static let lookPreviousCard = "Inspect frames instead of guessing. Without file: composed timeline (tracks, crop, placement, filters, shapes, "
        + "text, subtitles), at time/times or count moments across clip_id; default playhead. With file: source seconds; no times uses count "
        + "(default 6) across source_in/source_out or the whole file. Returns labelled contact sheet and Vision guesses (trust the images), "
        + "face/person/subject/text boxes, brightness and black bars; timeline also lists visible items. image=false omits pictures. "
        + "External-file approval follows the AI permission mode. files samples up to 24 files at their middle. shots=true with video "
        + "file/clip_id gives shot bounds, middle-frame descriptions/thumbnails, 24 per call; paginate from=next_from. Long scans return "
        + "job_id: wait with get_job, then repeat look. text_scan=true with video file/clip_id samples every 2 seconds for burned-in subtitle "
        + "bands, watermarks and slides/screens with boxes; clip_id also reports project subtitle_overlaps."

    static let look = MCPGuideWrittenTopics.Written(
        previousCard: lookPreviousCard,
        sections: [
            MCPGuideWrittenTopics.overview(lookPreviousCard, """
            look is read-only: it never changes the project, the playhead or the windows. Use it before and after edits instead of guessing \
            what the picture shows.
            """),
            MCPGuideSection(name: "timeline_and_files", text: """
            Timeline and files. Without file, look composes the timeline exactly as the preview shows it, at time, times (up to 12) or \
            count moments (1 to 12) across clip_id, and lists the visible items per frame. With file, times are seconds in that file; \
            without times it spreads count frames (default 6) across source_in to source_out or the whole file. Each frame comes with \
            Vision's labels (rough guesses: trust the picture), face, person, subject and text boxes, brightness and black bars. For a \
            file, video and image report the file's own size; the pictures you receive are scaled down, and the export size comes from \
            export_video and get_job. image=false returns only the text (for models that cannot see images); size picks small, medium \
            or large pictures.
            """),
            MCPGuideSection(name: "shots", text: """
            Shots. shots=true with a video file or clip_id lists the shot changes with a description and thumbnail of each shot's middle \
            frame, 24 per call; continue with from set to the previous next_from. Long scans return job_id: wait with get_job, then call \
            look again with the same arguments.
            """),
            MCPGuideSection(name: "text_scan", text: """
            Text on screen. text_scan=true with a video file or clip_id samples every 2 seconds and finds burned-in subtitle bands, fixed \
            text such as watermarks and logos, and slides or screens full of text, each with boxes. The result gives cover boxes that \
            set_shape kind=blur or kind=mosaic can use directly, and a crop hint for a subtitle band (it crops the whole band: look again \
            afterwards). With clip_id it also reports subtitle_overlaps, where the project's subtitles collide with on-screen text.
            """),
            MCPGuideSection(name: "pitfalls", text: """
            Pitfalls. files samples up to 24 files at their middle in one sheet, which is cheaper than looking at them one by one. Files \
            outside the opened folder ask once (needs_confirmation). A video SkyCut cannot open (for example HEVC stored as hev1) is \
            reported with the reason: convert it with compress_videos first. Vision guesses are often wrong on generated or unusual \
            pictures.
            """)
        ],
        examples: [
            ["time": 3],
            ["file": "a.mp4", "shots": true],
            ["clip_id": "c1", "text_scan": true]
        ],
        related: ["listen", "get_timeline", "set_shape"]
    )
}
