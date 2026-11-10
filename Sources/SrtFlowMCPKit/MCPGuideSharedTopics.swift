import Foundation

// MARK: - 说明书的五个通用主题：rules、conventions、paid、workflows、errors
//
// 管什么：跨工具的规矩、约定、花钱的流程、常见做法、报错怎么读 —— 放一处，不在每个工具里抄（方案 2.3）。只写英文（方案第八节第 7 条）；
// 中文的规矩以 docs/architecture/ 为准，每一段的出处写在它上面的注释里。
// 不管什么：某一个工具怎么用（那个工具的主题）；剪辑风格（recipes）；正片合同（get_status film_contract=true）。
// 守卫：checks/MCP/GuideChecks.swift（每个主题 ≤ 6,000、提到的名字都存在、只用英文）。

enum MCPGuideSharedTopics {
    static let all: [MCPGuideTopic] = [rules, conventions, paid, workflows, errors]

    // 出处：ai-control-mcp.md 第一节第 3 条（只用 SkyCut 的工具）、第四节第 1、4、5、6、10、46、53 条，第五节（停止、撤销这一轮）。
    static let rules = MCPGuideTopic(name: "rules", sections: [
        MCPGuideSection(name: MCPGuideSection.overview, text: """
        Rules for every SkyCut tool. SkyCut enforces most of them itself; these are the ones you must follow on your own.

        Use only SkyCut. Edit, cut, convert and inspect media only with SkyCut tools and only the files the user gave you or SkyCut \
        returned. Never run ffmpeg, scripts or the terminal on media, and never download media from the web: music and sound effects \
        come from find_audio, generated pictures and clips from generate_media. When SkyCut cannot do something, say so instead of \
        working around it.

        Results say what to do next. Follow next_step. needs_confirmation: ask the user the question in their language; only if they \
        agree, call the same tool again with the same arguments plus confirm_token. A token works once, for 30 minutes; asking again \
        before the user answers returns the same token. Never guess, reuse or invent one, and never treat your own plan as approval. \
        waiting_for_user: tell the user right away what they must do in SkyCut.

        Permission mode (get_settings section=ai, ai_access_mode). ask_for_approval: moving files to the Trash, reading files outside \
        the opened folder (asked once, then that folder is remembered) and paid work beyond the low-cost draft return \
        needs_confirmation. full_access: those go ahead and you tell the user what happened. The daily credit budget applies in both \
        modes, and changing the permission mode always needs the user's own confirmation.

        Watching or background. In ask_for_approval mode, ask once per conversation whether the user wants to watch the edits \
        (set_view mode=visible) or have them done in the background (mode=background); in full_access, visible is the default unless \
        the user says otherwise. Background edits still land in the project and can be undone.

        Undo and files. Every tool that changes a project is one undo step; undo round=true reverts everything this round of AI work \
        did to the project. A project that was never saved is saved after your first change (project_saved_to): tell the user where. \
        SkyCut never overwrites files: exports, new projects and copies get numbered names; to replace a file, move the old one to the \
        Trash with manage_files first.

        Projects. When more than one project is open, pass project=<id> (p1, p2…, from open_project or new_project) on every call; \
        calls without it go to the project you opened last. Projects another AI session is editing are refused. After the user \
        presses Stop, calls on that project are refused until you pause: tell the user and wait.

        Plan. Without SkyCut Pro or a trial, every tool except get_status and skycut_guide answers "Not done" with what the user \
        should do; get_status shows the plan (skycut_plan).
        """)
    ])

    // 出处：ai-control-mcp.md 第四节第 2、9、10、11 条，mcp-edit-parameters.md，timeline-linkage.md，editor-remembered-toggles.md（磁吸跟着工程走）。
    static let conventions = MCPGuideTopic(name: "conventions", sections: [
        MCPGuideSection(name: MCPGuideSection.overview, text: """
        Conventions shared by SkyCut tools.

        Time. All times are seconds. start, time, duration and seek use timeline seconds. source_in and source_out are seconds inside \
        the media file; look, listen and transcribe with file= also use file seconds. Changing source_in or source_out with edit_clip \
        keeps the clip's timeline start and moves its end, unless you also pass start.

        Tracks. V1 is the main video track: its clips play one after another. V2, V3… are video tracks above it (pictures over V1). \
        A1, A2… are audio tracks. track=new_video or new_audio creates a track. Texts, shapes, filters and subtitles have their own \
        rows; get_timeline lists everything.

        Ids. get_timeline returns short ids; any unique prefix works. Splitting, cutting and syncing create new items, so read \
        get_timeline again after such edits instead of reusing old ids. Projects are p1, p2… for the current SkyCut run.

        Positions and sizes. x and y are fractions of the frame from the top-left (0.5, 0.5 is the centre). Widths and heights are \
        fractions of the frame. Font sizes and line widths are pixels on a 1080-pixel-high frame: on a 9:16 frame (1920 high) the same \
        number looks smaller. Colours are #RRGGBB or #RRGGBBAA.

        Files. Paths are absolute or relative to the folder opened with open_folder. New files go into a SkyCut subfolder of that \
        folder (exports and projects), and never replace an existing file.

        Limits. get_timeline reports edit_limits, the current ranges. A value outside its range either fails the whole call with \
        allowed or suggested values, or is clamped; results show requested, applied and adjustments. A failed call changes nothing.

        Linkage and magnet. With linkage on (the default), texts, shapes, audio and subtitles over a V1 clip move and delete with \
        it; results report linkage. When a project's magnet is on, edits to V1 close its gaps; results report magnet.
        """)
    ])

    // 出处：sky-studio-jobs.md（报价、任务、取消、作品库），ai-control-mcp.md 第四节第 6、39、44、56 条，SkyStudioJobGate、AIDraftPolicy。
    static let paid = MCPGuideTopic(name: "paid", sections: [
        MCPGuideSection(name: MCPGuideSection.overview, text: """
        Paid work uses the user's Sky Studio credits.

        Which tools. generate_media (images, camera angles, image upscale, videos, lipsync, background cutout, music, sound \
        effects), upscale_clip, manage_characters (create and headshot) and add_voiceover with Sky Studio voices. \
        list_characters and get_character are free. \
        get_status models=true lists the current models with their defaults and limits, free and without generating anything.

        Prices. quote_only=true returns the exact credit price without spending, uploading or reserving anything. By default SkyCut \
        uses the low-cost draft model and settings for the request.

        When SkyCut asks. In ask_for_approval mode, a request beyond the low-cost draft (a higher resolution, a longer duration, the \
        highest quality, a pricier model) returns needs_confirmation with the price and the reason. Ask the user; only if they agree, \
        repeat the call with confirm_token (approval_scope=project approves that model and specification for the project up to that \
        price). Set user_requested_overrides=true only when the user's own words name that setting ("4K", a model, a duration) and \
        quote them in user_request; "best quality" names nothing, so quote and ask. Without such words SkyCut asks anyway \
        (overrides_not_applied). full_access skips these questions.

        The daily budget. A hard daily credit limit applies in every mode: over it, the result is status blocked with \
        daily_budget_exceeded and nothing starts. Tell the user; they can raise it in SkyCut Settings or ask you to change it with \
        set_settings. Never split or reshape a request to get under it.

        Jobs. Paid calls return job_id; wait with get_job, which reports the phase, queue position, credits_charged and refunds. Only \
        queued jobs can be cancelled with cancel_job; started jobs finish, are charged and land in the Sky Studio library. If a paid \
        call's outcome is unknown (an error or timeout after it was sent), check get_job before anything else; never send the same \
        paid request again blindly.

        Results. generate_media never edits the timeline: add the result with add_clips. upscale_clip replaces the clip's source \
        when it finishes, as one undo step.
        """)
    ])

    // 出处：mcp-discovery.md（需求 → 工具）、ai-control-mcp.md 第四节第 22、29–33、45、54、55 条、voiceover-timeline-sync.md。
    static let workflows = MCPGuideTopic(name: "workflows", sections: [
        MCPGuideSection(name: MCPGuideSection.overview, text: """
        Common SkyCut workflows. Each tool's own topic has the details.

        Start. get_status, then get_settings section=ai (permission mode and language); ask about watching if topic=rules says so. \
        open_folder for the user's files, then open_project or new_project, and get_timeline for fresh ids. Use look, listen and \
        transcribe to see and hear before you edit.

        Change many items at once. get_timeline, then edit_clips, set_texts or set_shapes with every item in one call (one undo \
        step), and look to check.

        Replace narration and keep the pictures in sync. add_clips the new recording, then sync_voiceover with the old narration's \
        range, the new audio id and the pictures, titles and shapes that should follow it; wait with get_job. Use add_voiceover only \
        when the user wants new narration spoken.

        Cut a whole video in a style. recipes lists the editing styles: pick the one that fits, tell the user in one sentence which \
        one you follow, read it with recipes id=<id>, then build it. The user's own words win over the style.

        Clean up speech. transcribe for words with times, cut_speech for filler words, pauses or retakes, then listen cuts=true to \
        check that every cut lands in a pause.

        Music. find_audio searches SkyCut's music and sound effects; add_clips library_id puts one on a track; cut_to_beat cuts V1 to \
        its beats. Pass on the music_credits from export_video to the user.

        Vertical video. set_canvas ratio=9:16, then edit_clips with fit=fill on the clips (SkyCut aims at faces, people and text), and \
        look to check the framing.

        Subtitles. generate_subtitles (wait with get_job), get_subtitles to read them, edit_subtitles to fix text, timing or style, \
        export_subtitles for subtitle files. export_video burns visible subtitles into the video.

        Check and export. inspect_video reports suspected seams, black frames and subtitle problems with evidence and changes \
        nothing. export_video preset=quick_review makes a fast, small review copy without changing the user's export settings; a \
        final export uses their saved settings. Wait with get_job, then look at the file.

        Record the screen. get_status screen=true lists screens, windows and microphones; record_screen action=start, later \
        action=stop. The recording lands on the timeline unless add_to_timeline=false.
        """)
    ])

    // 出处：ai-control-mcp.md 第三节（App 卡住）、第四节第 46、52、53 条，mcp-edit-parameters.md。
    static let errors = MCPGuideTopic(name: "errors", sections: [
        MCPGuideSection(name: MCPGuideSection.overview, text: """
        What SkyCut errors mean and what to do.

        A failed call comes back as a tool result with isError, and nothing was changed unless the message says otherwise. The \
        message says what was wrong and usually how to fix it. Before retrying a tool that failed, read skycut_guide topic=<that tool>.

        Unknown parameter. "<tool> has no parameter X, so nothing was done" lists the parameters the tool takes and guesses the one \
        you meant. Use only names from the tool's schema; nothing is ignored silently.

        Out-of-range values. The whole call fails with allowed or suggested values, or the value is clamped and the result shows \
        requested, applied and adjustments. get_timeline's edit_limits lists the current ranges.

        Unknown ids. Ids change after split, cut and sync: read get_timeline again.

        "Not done: …" before any work. The plan does not allow AI tools (get_status shows skycut_plan), the user pressed Stop, or the \
        project belongs to another AI session. Tell the user what the message says; do not retry in a loop.

        needs_confirmation is not an error: ask the user (topic=rules).

        Jobs. A job that fails says why in get_job, for example pass language when speech language detection failed. Follow that \
        advice before starting over.

        SkyCut busy or restarted. The helper says when SkyCut stopped answering or was restarted. After a restart, open your folders \
        and projects again, and check get_timeline before repeating an edit.
        """)
    ])
}
