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
            generate_media spends the user's Sky Studio credits to make new media files; it never changes the timeline. Quotes, approval and \
            the daily credit limit are in the spending section.
            """),
            MCPGuideSection(name: "kinds", about: "what each kind and image operation makes, the default video model, tools for other jobs", text: """
            What it makes. kind is image, image_to_video, text_to_video, music, sound_effect or lipsync. With kind=image, operation picks \
            the job: generate (default), remove_background (a cutout with transparency), camera_angle (a new viewpoint of one image with \
            the qwen-angles model: camera_angle {rotate, tilt, zoom}, rotate and tilt in degrees and zoom in steps, omitted axes are 0 and \
            all zero is refused; a rotation of 135 or -135 degrees runs as two steps on Sky Studio and its price comes only from the \
            quote) or upscale (one image enlarged by upscale_factor x2 (default), x3 or x4 with the image-upscale model; the model may \
            reduce the factor, so read the result's size). Both take one image or one reference_images entry, no prompt, and never film. \
            Video clips already on the timeline are upscaled with upscale_clip instead. The default video model is MiniMax H3. get_status \
            models=true lists the current models with prices, defaults and reference limits for free; model picks one by its public id, \
            otherwise SkyCut picks a compatible low-cost default. Narration is add_voiceover and subtitles are generate_subtitles, not \
            this tool.
            """),
            MCPGuideSection(name: "inputs", about: "prompt, frames, references, characters, aspect ratio, resolution, model-specific fields", text: """
            Inputs. prompt drives the generators; camera_angle, upscale, remove_background and lipsync take no prompt. image_to_video uses \
            image as the first frame and optional last_image (frames mode); input_mode=multimodal uses the reference_images, \
            reference_videos and reference_audio lists within the model's limits. Where a model's record says fit_images (get_status \
            models=true lists count, formats, bytes and pixels), SkyCut fits each reference image to the strictest limits of the chosen \
            model and, with no model named, the defaults after it (so a fallback can tighten them): converted, re-encoded or downscaled, \
            never upscaled; an image-upscale source is never shrunk. Too many images, an image too small or too narrow, or an animation \
            it cannot convert is refused, and the error states each model's limit. lipsync takes a local video and audio (MP3 or WAV; its \
            length is measured for the quote). character_id uses a Sky Studio character (list_characters; an id, never a file path) for \
            images and videos. character_roles picks views: without it the server chooses within the combined reference limits, and roles \
            you name are never dropped. A quote returns character_revision, which goes back unchanged; if the character's views change, \
            read it again with get_character and quote again (an old confirm_token no longer works). aspect_ratio defaults to the canvas \
            (a frames-mode video follows its image); resolution defaults to the lowest image or 720p-class video tier; duration follows \
            the model's catalog. Music is instrumental by default; lyrics need instrumental=false. Some fields belong to one model family \
            (HeyGen: title, enable_caption, start_time, end_time and others; Wan: document, web_url, enable_thinking, \
            enable_prompt_expansion). HeyGen's end_time must be after start_time and within the source; a shorter window does not lower \
            the price. HeyGen's switches default to false; enable_caption does not guarantee captions or burn-in, and \
            enable_dynamic_duration keeps HeyGen's own length limits. auto_fallback is deprecated: only false is accepted, and nothing is \
            ever replaced automatically.
            """),
            MCPGuideSection(name: "spending", about: "quote_only, when the user must approve, confirm_token, the daily credit limit", text: """
            Spending. quote_only=true returns the exact price and the approval reasons without uploading, reserving or charging. The \
            low-cost draft (default model and settings) goes ahead in both permission modes. In ask_for_approval mode, going beyond the \
            draft (a higher resolution, a longer duration, quality=highest, a pricier model) returns needs_confirmation with the price and \
            the reason: ask the user, and only if they agree repeat the same call with confirm_token (approval_scope is once by default; \
            project, only on the user's explicit approval, approves that model and specification for the project up to that price). Set \
            user_requested_overrides=true only when the user's own words name that setting ("4K", "use GPT Image 2", "10 seconds"), and \
            put those words in user_request. Wishes such as "best quality" or "as good as possible" name no setting: choose a \
            specification, quote it and ask. If user_request does not name every setting beyond the draft, SkyCut asks anyway \
            (needs_confirmation with overrides_not_applied). The daily hard credit limit applies in every mode: over it nothing starts \
            (daily_budget_exceeded); tell the user. Keep the same idempotency_key (stable, 1-128 characters) when retrying after a lost \
            answer.
            """),
            MCPGuideSection(name: "jobs_results", about: "job_id and get_job, where files land, cancelling, refunds, file names", text: """
            Jobs and results. The call returns job_id; wait with get_job, which reports the phase, queue position and credits_charged. \
            For timed media, requested_duration is what Sky Studio was asked (null for an automatic length), duration is the length \
            Sky Studio measured in the delivered file or got from the provider (null when unknown) and duration_source says which. \
            A difference greater than 1 second adds duration_warning; \
            tell the user before placing the file. This notice never trims, pads or regenerates it. The reported duration is not a \
            local measurement of the file or of its audible sound. \
            Finished files land in the project's SkyCut folder and never change the timeline: add them with \
            add_clips. Only queued jobs can be cancelled with cancel_job; started jobs finish, are charged and stay in the user's Sky \
            Studio library. Refunds need billing proof. After an unknown or delivery error, recover the original job with get_job; never \
            send the same paid request again. name sets the file name; by default it comes from the prompt, or for an image operation \
            from the source name plus angle, x2, x3 or x4. A clashing name gets a number. A music result also carries music: what \
            listen beats=true says about the file (accents, strongest_accents, stops, ends_at, tempo), to place it with add_clips hit_at.
            """),
            // docs/architecture/sky-studio-jobs.md "Music length and video sound" (2026-11-19, MCP-18); Sky Studio's "Music length".
            MCPGuideSection(name: "music_length", about: "how long music comes back: duration, auto, exact_length, which model SkyCut picks", text: """
            Music length. get_status models=true gives each music model's length: whether it makes the file exactly the length \
            asked or only aims at it, whether it can choose its own length, its range and steps. Give duration in seconds for a set \
            length, or leave it out (or auto) to let the model choose. Leave model out and SkyCut takes the first music model, in Sky \
            Studio's order, that can make the request: a song with vocals or an automatic length stays on the song model (Lyria 3 \
            Pro, which aims at the length written in its prompt and lands within a few seconds, from about a minute up); a length \
            outside its range, or exact_length=true, goes to an exact-length model (Stable Audio 3 Medium: the file is exactly that \
            long, in its steps; instrumental only, and with no length given it makes its default). exact_length=true needs \
            duration. A cue cut to picture wants exact_length=true; a whole song does not. A request no music model can make (an \
            exact length with vocals, a length outside every range) is refused before any quote with each model's reason, and \
            nothing is charged. In an exact-length file the music itself can fade or ring out before the file ends: the job's music \
            gives ends_at.
            """),
            // docs/architecture/sky-studio-jobs.md "Music length and video sound" (2026-11-19, MCP-42); Sky Studio's "Video sound".
            MCPGuideSection(name: "video_sound", about: "audio_mode full, ambient or none; the result's audio; listen before narration over a bed", text: """
            Video sound. A generated video carries the model's own sound, which can include a music, drone or low-rumble bed under \
            the action that buries narration laid over it. audio_mode (text_to_video and image_to_video) chooses: full (the default) \
            keeps it; ambient asks for the sound of what is on screen only, a direction Sky Studio adds to the prompt, so a bed can \
            still come back; none makes no sound, only on models whose get_status models=true lists none in params.audio_mode \
            (Seedance and Wan; MiniMax H3, Gemini Omni and Veo always make sound). The mode never switches the model: none on the \
            default MiniMax H3 is refused before the quote, because a model that can turn sound off costs several times more while \
            muting the clip after it arrives (edit_clip muted=true) gives the same silence for nothing. To use one anyway, name it \
            (its quote shows the price). The mode never changes a model's price. A finished \
            video's get_job carries audio (mode, has_track, can_turn_off, may_carry_bed, note). When may_carry_bed is true, listen \
            before laying narration over it: listen describe=true with the file (or its clip_id once placed) names a low_drone, \
            broadband_noise or music; lower the clip with edit_clip volume_db or mute it, then check the line with listen voice. \
            generate_audio is the older switch: false turns sound off only on a model that has it and is ignored (with a note) on \
            the rest, so prefer audio_mode, which is refused instead.
            """),
            MCPGuideSection(name: "official_film", about: "the official original-film flow: film, prepared references, seam review", text: """
            Official original film. film, prepare_references, prepared_references, quote_token and seam_review belong to the official \
            original-film flow: read get_status film_contract=true first for the shot, context and sound contract and its steps. \
            prepare_references=true only prepares and uploads the references (no quote, no reservation; leave out film, quote_only and the \
            tokens) and returns a job: wait with get_job. Then pass its token as prepared_references and repeat the same paths and roles; \
            the token stops working after an account, project or file change. Keep a stable idempotency_key per shot and do a fresh \
            seam_review before each submission. The film flow only generates (operation generate): no remove_background, camera_angle, \
            upscale or lipsync.
            """)
        ],
        examples: [
            ["kind": "image", "prompt": "A product photo on a white table", "quote_only": true],
            ["kind": "image", "operation": "camera_angle", "image": "photo.png", "camera_angle": ["rotate": 45]]
        ],
        related: ["paid", "upscale_clip", "add_clips", "get_job"],
        readingTip: "To quote and ask the user before spending, read only section=spending; for music length, section=music_length; "
            + "for a video's own sound, section=video_sound."
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
            MCPGuideSection(name: "timeline_and_files", about: "timeline or file frames, times and count, labels and boxes, sizes, bare edges", text: """
            Timeline and files. Without file, look composes the timeline exactly as the preview shows it, at time, times (up to 12) or \
            count moments (1 to 12) across clip_id, and lists the visible items per frame. With file, times are seconds in that file; \
            without times it spreads count frames (default 6) across source_in to source_out or the whole file. Each frame comes with \
            Vision's labels (rough guesses: trust the picture), face, person, subject and text boxes, brightness and black bars. For a \
            file, video and image report the file's own size; the pictures you receive are scaled down, and the export size comes from \
            export_video and get_job. image=false returns only the text (for models that cannot see images); size picks small, medium \
            or large pictures. A timeline frame where no picture covers part of the canvas also has uncovered: a bare edge (left, \
            right, top, bottom) with how far in the gap reaches, or a bare corner such as top_right with [along the top or bottom \
            edge, down the side], in canvas pixels. It comes from the clips' geometry at that moment (placement, crop, rotation, \
            keyframes, entrance and exit motion; pictures with transparency do not count), not from pixels: dark footage is never \
            uncovered.
            """),
            // MCP-66 (2026-11-18): docs/architecture/ai-control-mcp.md section 4 item 12; the rows parse like listen's layers.
            MCPGuideSection(name: "sound", about: "sound=[...]: the mix or tracks drawn under timeline frames, sound starts, #n marks", text: """
            Sound under the frames. With sound, a timeline look draws the timeline's sound under the sheet, so a hit, a cut or a \
            silence can be matched to the frames. sound lists the rows, top to bottom, at most 4: mix (the whole mix), a track (A1), \
            tracks joined by + (V1+V2) or rest (every audible track not named), as listen mix=true names its layers; sound=true \
            means ["mix"]. SkyCut renders it with the engine that makes the exported sound (clip volume, curves, fades, scenes, \
            track and master faders), frame by frame at the project frame rate, before the limiter: the levels listen mix=true \
            reports. The strip spans the frames' times with a little room either side (with clip_id and count: that clip's \
            seconds). The tiles are labelled #1, #2, ... and a white dashed line marks where each lies on the strip; blue lines \
            are where a sound starts, labelled with the clip's id; the ruler is in timeline seconds, with short ticks for frames \
            when they fit. Height is the square root of the level: half height is about -12 dBFS, a quarter about -24. The light \
            part is each frame's true peak, the solid part its level, red is above the -1 dBTP limiter ceiling. The result's \
            sound gives the seconds drawn, each row's loudest_at (the start of its loudest frame) and peak_db, and the starts \
            (time, clip, track, name). It shows how loud and when, never what a sound is: listen describe=true says that. \
            Timeline looks only (not with file, files, shots or text_scan); image=false returns the numbers without the picture.
            """),
            MCPGuideSection(name: "shots", about: "shot changes with shots=true and paging with from / next_from", text: """
            Shots. shots=true with a video file or clip_id lists the shot changes with a description and thumbnail of each shot's middle \
            frame, 24 per call; continue with from set to the previous next_from. Long scans return job_id: wait with get_job, then call \
            look again with the same arguments.
            """),
            MCPGuideSection(name: "text_scan", about: "burned-in subtitles, watermarks and slides with text_scan=true, cover boxes", text: """
            Text on screen. text_scan=true with a video file or clip_id samples every 2 seconds and finds burned-in subtitle bands, fixed \
            text such as watermarks and logos, and slides or screens full of text, each with boxes. The result gives cover boxes that \
            set_shape kind=blur or kind=mosaic can use directly, and a crop hint for a subtitle band (it crops the whole band: look again \
            afterwards). With clip_id it also reports subtitle_overlaps, where the project's subtitles collide with on-screen text.
            """),
            MCPGuideSection(name: "pitfalls", about: "files, outside files, videos SkyCut cannot open, Vision guesses", text: """
            Pitfalls. files samples up to 24 files at their middle in one sheet, which is cheaper than looking at them one by one. Files \
            outside the opened folder ask once (needs_confirmation). A video SkyCut cannot open (for example HEVC stored as hev1) is \
            reported with the reason: convert it with compress_videos first. Vision guesses are often wrong on generated or unusual \
            pictures.
            """),
            // docs/architecture/ai-control-mcp.md section 4 item 12; docs/bugfixes/2026-11-17-look-hangs-and-dropped-calls.md.
            MCPGuideSection(name: "slow_looks", about: "a look still working after about 25 s: job_id, queue_position, waiting_for, cancel_job", text: """
            Slow looks. A look still working after about 25 seconds (waiting behind earlier edits on its project, or rendering on a busy \
            Mac) answers with job_id instead of the picture: status running, or queued with queue_position (1 = next) and waiting_for \
            (the call it waits behind). Call get_job with that job_id and wait_seconds 30 until the status is done: the look's own answer \
            is under result and the picture comes with it. Do not send the same look again; cancel_job stops it, and a queued look then \
            never starts. Looks do not wait for each other: several looks on one project, or from several AI sessions, run side by side. \
            A look waits only for the edits sent before it, and edits sent after it do not wait for its frames; shots=true is the \
            exception and keeps its project's calls waiting until it is done.
            """)
        ],
        examples: [
            ["time": 3],
            ["times": [28, 28.5, 29, 29.5, 30], "sound": ["mix", "A1"]],
            ["file": "a.mp4", "shots": true],
            ["clip_id": "c1", "text_scan": true]
        ],
        related: ["listen", "get_timeline", "set_shape"]
    )
}
